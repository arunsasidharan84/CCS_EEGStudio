//! Eye-blink detection of the CCS pipeline: `accs_eyeblinkdetection.m` (+ the EEGLAB `eegfilt` / `firls` /
//! `filtfilt` it relies on).  Used by ICA step 1 to cut blink-locked epochs.
//!
//! Event indices are returned **1-based** (MATLAB sample numbers) so they can be compared with MATLAB output
//! directly; callers convert with `- 1`.

use crate::linalg::*;

/// MATLAB `firls(order, f, m)` for a type-I (even order, no Hilbert/differentiator) linear-phase FIR with
/// piecewise-linear band amplitudes and unit weights.  `f` are the normalised band edges (0..1, pairs),
/// `m` the amplitude at each edge.
pub fn firls(order: usize, f: &[f64], m: &[f64]) -> Result<Vec<f64>, String> {
    if order % 2 != 0 {
        return Err("firls: only even orders are supported".into());
    }
    if f.len() != m.len() || f.len() % 2 != 0 {
        return Err("firls: f and m must have the same even length".into());
    }
    let l = order / 2;
    let n = l + 1;
    let pi = std::f64::consts::PI;
    let mut q = Mat::zeros(n, n);
    let mut b = vec![0.0; n];
    let mut i = 0;
    while i + 1 < f.len() {
        let (w1, w2) = (f[i] * pi, f[i + 1] * pi);
        let (m1, m2) = (m[i], m[i + 1]);
        let slope = if w2 != w1 { (m2 - m1) / (w2 - w1) } else { 0.0 };
        let inter = m1 - slope * w1;
        let int_cos = |c: f64| if c == 0.0 { w2 - w1 } else { ((c * w2).sin() - (c * w1).sin()) / c };
        // integral of w*cos(c w)
        let int_wcos = |c: f64| {
            if c == 0.0 {
                0.5 * (w2 * w2 - w1 * w1)
            } else {
                (w2 * (c * w2).sin() - w1 * (c * w1).sin()) / c + ((c * w2).cos() - (c * w1).cos()) / (c * c)
            }
        };
        for j in 0..n {
            for k in 0..n {
                q[(j, k)] += 0.5 * (int_cos(j as f64 - k as f64) + int_cos(j as f64 + k as f64));
            }
            b[j] += slope * int_wcos(j as f64) + inter * int_cos(j as f64);
        }
        i += 2;
    }
    let rhs = Mat::from_column_slice(n, 1, &b);
    let a = q.lu().solve(&rhs).ok_or("firls: singular system")?;
    let mut h = vec![0.0; order + 1];
    h[l] = a[(0, 0)];
    for k in 1..=l {
        h[l - k] = a[(k, 0)] / 2.0;
        h[l + k] = a[(k, 0)] / 2.0;
    }
    Ok(h)
}

/// Direct-form FIR filter `filter(b, 1, x, z)` with initial state `z` (length `nb-1`, MATLAB convention).
fn fir_filter(b: &[f64], x: &[f64], z0: &[f64]) -> Vec<f64> {
    let nb = b.len();
    let mut z = z0.to_vec();
    z.resize(nb.saturating_sub(1), 0.0);
    let mut y = Vec::with_capacity(x.len());
    for &xi in x {
        let yi = b[0] * xi + if nb > 1 { z[0] } else { 0.0 };
        for k in 0..nb.saturating_sub(2) {
            z[k] = z[k + 1] + b[k + 1] * xi;
        }
        if nb > 1 {
            z[nb - 2] = b[nb - 1] * xi;
        }
        y.push(yi);
    }
    y
}

/// MATLAB `filtfilt(b, 1, x)` for a FIR `b` (reflect-extend by `3*(nb-1)`, steady-state initial conditions).
pub fn filtfilt_fir(b: &[f64], x: &[f64]) -> Result<Vec<f64>, String> {
    let nb = b.len();
    let nfact = 3 * (nb - 1);
    if x.len() <= nfact {
        return Err("filtfilt: data length must be more than 3 times the filter order".into());
    }
    let n = x.len();
    let mut y = Vec::with_capacity(n + 2 * nfact);
    for i in (1..=nfact).rev() {
        y.push(2.0 * x[0] - x[i]);
    }
    y.extend_from_slice(x);
    for i in 1..=nfact {
        y.push(2.0 * x[n - 1] - x[n - 1 - i]);
    }
    // zi = (I - C) \ b(2:end), C = companion of a=1 -> zi[k] = sum_{m>k} b[m]
    let mut zi = vec![0.0; nb - 1];
    let mut acc = 0.0;
    for k in (0..nb - 1).rev() {
        acc += b[k + 1];
        zi[k] = acc;
    }
    let z1: Vec<f64> = zi.iter().map(|v| v * y[0]).collect();
    let mut f = fir_filter(b, &y, &z1);
    f.reverse();
    let z2: Vec<f64> = zi.iter().map(|v| v * f[0]).collect();
    let mut g = fir_filter(b, &f, &z2);
    g.reverse();
    Ok(g[nfact..nfact + n].to_vec())
}

/// EEGLAB `eegfilt(data, srate, locutoff, hicutoff)` (default `firls` design, zero phase) on one channel.
pub fn eegfilt(x: &[f64], srate: f64, locutoff: f64, hicutoff: f64) -> Result<Vec<f64>, String> {
    let nyq = srate * 0.5;
    let trans = 0.15;
    let mut order = if locutoff > 0.0 { 3 * (srate / locutoff).trunc() as usize } else { 3 * (srate / hicutoff).trunc() as usize };
    if order < 15 {
        order = 15;
    }
    if order % 2 == 1 {
        order += 1;
    }
    let (f, m): (Vec<f64>, Vec<f64>) = if locutoff > 0.0 && hicutoff > 0.0 {
        (
            vec![0.0, (1.0 - trans) * locutoff / nyq, locutoff / nyq, hicutoff / nyq, (1.0 + trans) * hicutoff / nyq, 1.0],
            vec![0.0, 0.0, 1.0, 1.0, 0.0, 0.0],
        )
    } else if locutoff > 0.0 {
        (vec![0.0, locutoff * (1.0 - trans) / nyq, locutoff / nyq, 1.0], vec![0.0, 0.0, 1.0, 1.0])
    } else {
        (vec![0.0, hicutoff / nyq, hicutoff * (1.0 + trans) / nyq, 1.0], vec![1.0, 1.0, 0.0, 0.0])
    };
    let w = firls(order, &f, &m)?;
    filtfilt_fir(&w, x)
}

fn std_dev(x: &[f64]) -> f64 {
    let n = x.len();
    if n < 2 {
        return 0.0;
    }
    let mean = x.iter().sum::<f64>() / n as f64;
    (x.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / (n as f64 - 1.0)).sqrt()
}

fn corr(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len() as f64;
    let ma = a.iter().sum::<f64>() / n;
    let mb = b.iter().sum::<f64>() / n;
    let (mut sab, mut saa, mut sbb) = (0.0, 0.0, 0.0);
    for i in 0..a.len() {
        let (da, db) = (a[i] - ma, b[i] - mb);
        sab += da * db;
        saa += da * da;
        sbb += db * db;
    }
    sab / (saa * sbb).sqrt()
}

/// `evt = accs_eyeblinkdetection(data, srate)`: groups of 1-based blink peak samples, most populated morphology first.
pub fn eyeblink_detection(data_in: &[f64], srate: f64) -> Result<Vec<Vec<usize>>, String> {
    let (bp_lo, bp_hi, threshold, blanking, maxcross, ampmin, noisethresh, corrval) = (1.5, 15.0, 2.0, 0.8, 10usize, 0.0, 2.5, 0.8);
    let blank = (blanking * srate).round() as usize;
    let len = data_in.len();
    if blank >= len {
        return Ok(vec![]);
    }
    let data = eegfilt(data_in, srate, bp_lo, bp_hi)?;
    let fabs: Vec<f64> = data.iter().map(|v| v.abs()).collect();
    // nIgnore = round(min(2*srate, 0.02*len)); Fsig = Fsig(nIgnore:end-nIgnore+1) (1-based, inclusive)
    let n_ignore = ((2.0 * srate).min(len as f64 * 0.02)).round() as usize;
    let lo = n_ignore.max(1);
    let hi = len + 1 - n_ignore;
    let std_f = std_dev(&data[lo - 1..hi]);
    let thresh_val = threshold * std_f;
    // iThresh = find(Fabs(1:end-blank) > thresh)   (1-based)
    let i_thresh: Vec<usize> = (1..=len - blank).filter(|&i| fabs[i - 1] > thresh_val).collect();
    if i_thresh.is_empty() {
        return Ok(vec![]);
    }
    let mut events: Vec<(usize, f64)> = vec![]; // (1-based index, rms)
    let mut i = Some(0usize);
    while let Some(ii) = i {
        let start = i_thresh[ii];
        let win: Vec<f64> = (0..blank).map(|k| fabs[start - 1 + k]).collect();
        let above: Vec<usize> = (0..blank).filter(|&k| win[k] > thresh_val).collect();
        let npeaks = above.windows(2).filter(|w| w[1] - w[0] > 1).count().max(1);
        let (mut imax_win, mut fmax) = (0usize, f64::NEG_INFINITY);
        for (k, &v) in win.iter().enumerate() {
            if v > fmax {
                fmax = v;
                imax_win = k;
            }
        }
        let imax = start + imax_win;
        if npeaks < maxcross && fabs[imax - 1] > ampmin {
            let rms = (win.iter().map(|v| v * v).sum::<f64>() / blank as f64).sqrt();
            events.push((imax, rms));
        }
        i = i_thresh.iter().position(|&v| v > imax + blank);
    }
    if events.is_empty() {
        return Ok(vec![]);
    }
    let rms: Vec<f64> = events.iter().map(|e| e.1).collect();
    let rms_mean = rms.iter().sum::<f64>() / rms.len() as f64;
    let rms_thr = rms_mean + std_dev(&rms) * noisethresh;
    let mut ev: Vec<usize> = events.iter().filter(|e| e.1 < rms_thr).map(|e| e.0).collect();
    if ev.is_empty() {
        return Ok(vec![]);
    }
    let w0 = (-0.2 * srate).round() as i64;
    let w1 = (0.2 * srate).round() as i64;
    ev.retain(|&e| !((e as i64) <= -w0 || (e as i64) >= len as i64 - w1));
    if ev.is_empty() {
        return Ok(vec![]);
    }
    let seg = |e: usize| -> Vec<f64> { (w0..=w1).map(|d| data[(e as i64 + d - 1) as usize]).collect() };
    let mut refs: Vec<Vec<f64>> = vec![seg(ev[0])];
    let mut ev_type = vec![-1i64; ev.len()];
    let mut count = vec![1usize];
    for k in 1..ev.len() {
        let new_evt = seg(ev[k]);
        for j in 0..refs.len() {
            if corr(&new_evt, &refs[j]) > corrval {
                ev_type[k] = j as i64;
                count[j] += 1;
                break;
            }
        }
        if ev_type[k] == -1 {
            refs.push(new_evt);
            ev_type[k] = refs.len() as i64 - 1;
            count.push(1);
        }
    }
    let mut ok: Vec<usize> = if count.iter().any(|&c| c > 5) { (0..count.len()).filter(|&j| count[j] > 5).collect() } else { (0..count.len()).collect() };
    ok.sort_by(|&a, &b| count[b].cmp(&count[a])); // stable, descending
    Ok(ok.iter().map(|&t| (0..ev.len()).filter(|&k| ev_type[k] == t as i64).map(|k| ev[k]).collect()).collect())
}
