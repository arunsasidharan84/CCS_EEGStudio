//! Signal decompositions used by the ASR variants and wICA: VMD (Dragomiretskiy & Zosso), EMD (sifting with natural
//! cubic-spline envelopes) and an undecimated (a-trous) orthogonal wavelet transform.

use rustfft::{num_complex::Complex, FftPlanner};

// ------------------------------------------------------------------------------------------------------------
// VMD
// ------------------------------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct VmdOpts {
    pub k: usize,
    pub alpha: f64,
    pub tau: f64,
    pub dc: bool,
    /// 0 = all omegas start at 0, 1 = uniform start (MATLAB reference `init=1`)
    pub init: u8,
    pub tol: f64,
    pub max_iter: usize,
}
impl Default for VmdOpts {
    fn default() -> Self {
        VmdOpts { k: 5, alpha: 2000.0, tau: 0.0, dc: false, init: 1, tol: 1e-7, max_iter: 500 }
    }
}

/// Port of the reference `VMD.m` (Dragomiretskiy & Zosso 2014). `fs` normalises the returned centre frequencies to Hz.
/// Returns (modes sorted by centre frequency, centre frequencies in Hz, iterations).
pub fn vmd(f_in: &[f64], fs: f64, o: &VmdOpts) -> (Vec<Vec<f64>>, Vec<f64>, usize) {
    let mut f: Vec<f64> = f_in.to_vec();
    let odd = f.len() % 2 == 1;
    if odd {
        f.pop();
    }
    let t0 = f.len();
    let h = t0 / 2;
    let mut fm = Vec::with_capacity(2 * t0);
    for i in (0..h).rev() {
        fm.push(f[i]);
    }
    fm.extend_from_slice(&f);
    for i in (t0 - h..t0).rev() {
        fm.push(f[i]);
    }
    let t = fm.len();
    let mut planner = FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(t);
    let ifft = planner.plan_fft_inverse(t);
    let mut buf: Vec<Complex<f64>> = fm.iter().map(|&v| Complex::new(v, 0.0)).collect();
    fft.process(&mut buf);
    // fftshift
    let mut fhat: Vec<Complex<f64>> = (0..t).map(|i| buf[(i + t / 2) % t]).collect();
    for v in fhat.iter_mut().take(t / 2) {
        *v = Complex::new(0.0, 0.0);
    }
    let freqs: Vec<f64> = (1..=t).map(|i| i as f64 / t as f64 - 0.5 - 1.0 / t as f64).collect();
    let k = o.k;
    let mut omega = vec![0.0; k];
    if o.init == 1 {
        for (i, w) in omega.iter_mut().enumerate() {
            *w = 0.5 / k as f64 * i as f64;
        }
    }
    if o.dc {
        omega[0] = 0.0;
    }
    let mut uhat = vec![vec![Complex::new(0.0, 0.0); t]; k];
    let mut lambda = vec![Complex::new(0.0, 0.0); t];
    let mut n = 0usize;
    let mut udiff = f64::INFINITY;
    while udiff > o.tol && n + 1 < o.max_iter {
            // total of current (partially updated) modes
        let mut total = vec![Complex::new(0.0, 0.0); t];
        for kk in 0..k {
            for i in 0..t {
                total[i] += uhat[kk][i];
            }
        }
        let mut diff = 0.0;
        for kk in 0..k {
            let old = uhat[kk].clone();
            for i in 0..t {
                let others = total[i] - old[i];
                let num = fhat[i] - others + lambda[i] * 0.5;
                let den = 1.0 + o.alpha * (freqs[i] - omega[kk]).powi(2);
                uhat[kk][i] = num / den;
            }
            for i in 0..t {
                total[i] += uhat[kk][i] - old[i];
            }
            if !(o.dc && kk == 0) {
                let (mut num, mut den) = (0.0, 0.0);
                for i in t / 2..t {
                    let p = uhat[kk][i].norm_sqr();
                    num += freqs[i] * p;
                    den += p;
                }
                omega[kk] = if den > 0.0 { num / den } else { omega[kk] };
            }
            for i in 0..t {
                diff += (uhat[kk][i] - old[i]).norm_sqr();
            }
        }
        for i in 0..t {
            lambda[i] += (fhat[i] - total[i]) * o.tau;
        }
        udiff = diff / t as f64 + f64::EPSILON;
        n += 1;
    }
    // reconstruct
    let mut order: Vec<usize> = (0..k).collect();
    order.sort_by(|&a, &b| omega[a].partial_cmp(&omega[b]).unwrap());
    let mut modes = vec![];
    let mut cf = vec![];
    for &kk in &order {
        let mut full = vec![Complex::new(0.0, 0.0); t];
        for j in t / 2..t {
            full[j] = uhat[kk][j];
        }
        for m in 0..t / 2 - 1 {
            full[t / 2 - m] = uhat[kk][t / 2 + m].conj();
        }
        full[0] = full[t - 1].conj();
        let mut un: Vec<Complex<f64>> = (0..t).map(|i| full[(i + t / 2) % t]).collect();
        ifft.process(&mut un);
        let u: Vec<f64> = un.iter().map(|c| c.re / t as f64).collect();
        let mut mode: Vec<f64> = u[t / 4..3 * t / 4].to_vec();
        if odd {
            let l = *mode.last().unwrap();
            mode.push(l);
        }
        modes.push(mode);
        cf.push(omega[kk] * fs);
    }
    (modes, cf, n)
}

// ------------------------------------------------------------------------------------------------------------
// EMD
// ------------------------------------------------------------------------------------------------------------

/// Natural cubic spline through (x_i, y_i) evaluated at integer positions `0..n`.
fn spline_eval(xs: &[f64], ys: &[f64], n: usize) -> Vec<f64> {
    let m = xs.len();
    let mut y2 = vec![0.0; m];
    if m > 2 {
        let mut u = vec![0.0; m];
        for i in 1..m - 1 {
            let sig = (xs[i] - xs[i - 1]) / (xs[i + 1] - xs[i - 1]);
            let p = sig * y2[i - 1] + 2.0;
            y2[i] = (sig - 1.0) / p;
            let d = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) - (ys[i] - ys[i - 1]) / (xs[i] - xs[i - 1]);
            u[i] = (6.0 * d / (xs[i + 1] - xs[i - 1]) - sig * u[i - 1]) / p;
        }
        for i in (0..m - 1).rev() {
            y2[i] = y2[i] * y2[i + 1] + u[i];
        }
    }
    let mut out = vec![0.0; n];
    let mut j = 0usize;
    for (t, o) in out.iter_mut().enumerate() {
        let tf = t as f64;
        while j + 2 < m && xs[j + 1] < tf {
            j += 1;
        }
        let h = xs[j + 1] - xs[j];
        let a = (xs[j + 1] - tf) / h;
        let b = (tf - xs[j]) / h;
        *o = a * ys[j] + b * ys[j + 1] + ((a * a * a - a) * y2[j] + (b * b * b - b) * y2[j + 1]) * h * h / 6.0;
    }
    out
}

fn extrema(x: &[f64]) -> (Vec<usize>, Vec<usize>) {
    let n = x.len();
    let (mut mx, mut mn) = (vec![], vec![]);
    let mut i = 1;
    while i + 1 < n {
        // handle plateaus: take the middle
        let mut j = i;
        while j + 1 < n && x[j + 1] == x[i] {
            j += 1;
        }
        if j + 1 >= n {
            break;
        }
        if x[i] > x[i - 1] && x[i] > x[j + 1] {
            mx.push((i + j) / 2);
        } else if x[i] < x[i - 1] && x[i] < x[j + 1] {
            mn.push((i + j) / 2);
        }
        i = j + 1;
    }
    (mx, mn)
}

fn envelope(x: &[f64], idx: &[usize]) -> Vec<f64> {
    let n = x.len();
    // mirror-extend by one extremum on each side so the spline is defined over [0, n-1]
    let mut xs: Vec<f64> = vec![];
    let mut ys: Vec<f64> = vec![];
    let l = idx.len();
    // symmetric extension about the end points of the signal
    xs.clear();
    ys.clear();
    for k in (0..l.min(2)).rev() {
        xs.push(-(idx[k] as f64));
        ys.push(x[idx[k]]);
    }
    for &i in idx {
        xs.push(i as f64);
        ys.push(x[i]);
    }
    for k in (l.saturating_sub(2)..l).rev() {
        xs.push(2.0 * (n as f64 - 1.0) - idx[k] as f64);
        ys.push(x[idx[k]]);
    }
    spline_eval(&xs, &ys, n).into_iter().collect()
}

/// Empirical mode decomposition by sifting. Returns (IMFs, residual). `sd_thresh` is the Huang SD criterion.
pub fn emd(x: &[f64], max_imfs: usize, sd_thresh: f64, max_sift: usize) -> (Vec<Vec<f64>>, Vec<f64>) {
    let mut res = x.to_vec();
    let mut imfs = vec![];
    for _ in 0..max_imfs {
        let (mx, mn) = extrema(&res);
        if mx.len() < 2 || mn.len() < 2 {
            break;
        }
        let mut h = res.clone();
        for _ in 0..max_sift {
            let (mx, mn) = extrema(&h);
            if mx.len() < 2 || mn.len() < 2 {
                break;
            }
            let up = envelope(&h, &mx);
            let lo = envelope(&h, &mn);
            let hn: Vec<f64> = (0..h.len()).map(|i| h[i] - 0.5 * (up[i] + lo[i])).collect();
            let num: f64 = (0..h.len()).map(|i| (h[i] - hn[i]).powi(2)).sum();
            let den: f64 = h.iter().map(|v| v * v).sum::<f64>() + 1e-300;
            h = hn;
            if num / den < sd_thresh {
                break;
            }
        }
        for i in 0..res.len() {
            res[i] -= h[i];
        }
        imfs.push(h);
    }
    (imfs, res)
}

// ------------------------------------------------------------------------------------------------------------
// Undecimated orthogonal wavelet transform (a trous, periodic boundaries)
// ------------------------------------------------------------------------------------------------------------

/// Daubechies-4 (8 taps) analysis low-pass filter (`dec_lo` of MATLAB `wfilters('db4')`).
pub const DB4_LO: [f64; 8] = [
    -0.010597401784997278,
    0.032883011666982945,
    0.030841381835986965,
    -0.18703481171888114,
    -0.027983769416983849,
    0.6308807679295904,
    0.7148465705525415,
    0.23037781330885523,
];

fn qmf_hi(lo: &[f64]) -> Vec<f64> {
    let n = lo.len();
    (0..n).map(|i| if i % 2 == 0 { lo[n - 1 - i] } else { -lo[n - 1 - i] }).collect()
}

pub struct Swt {
    pub approx: Vec<f64>,
    pub details: Vec<Vec<f64>>,
}

fn conv_circ(x: &[f64], f: &[f64], s: usize) -> Vec<f64> {
    let n = x.len();
    (0..n)
        .map(|i| {
            let mut a = 0.0;
            for (k, &fk) in f.iter().enumerate() {
                let idx = ((i as i64 - (k * s) as i64) % n as i64 + n as i64) as usize % n;
                a += fk * x[idx];
            }
            a
        })
        .collect()
}
fn corr_circ(y: &[f64], f: &[f64], s: usize) -> Vec<f64> {
    let n = y.len();
    (0..n)
        .map(|i| {
            let mut a = 0.0;
            for (k, &fk) in f.iter().enumerate() {
                a += fk * y[(i + k * s) % n];
            }
            a
        })
        .collect()
}

pub fn swt(x: &[f64], level: usize, lo_dec: &[f64]) -> Swt {
    let r2 = std::f64::consts::SQRT_2;
    let lo: Vec<f64> = lo_dec.iter().map(|v| v / r2).collect();
    let hi: Vec<f64> = qmf_hi(lo_dec).iter().map(|v| v / r2).collect();
    let mut a = x.to_vec();
    let mut details = vec![];
    for j in 0..level {
        let s = 1usize << j;
        details.push(conv_circ(&a, &hi, s));
        a = conv_circ(&a, &lo, s);
    }
    Swt { approx: a, details }
}

pub fn iswt(w: &Swt, lo_dec: &[f64]) -> Vec<f64> {
    let r2 = std::f64::consts::SQRT_2;
    let lo: Vec<f64> = lo_dec.iter().map(|v| v / r2).collect();
    let hi: Vec<f64> = qmf_hi(lo_dec).iter().map(|v| v / r2).collect();
    let mut a = w.approx.clone();
    for j in (0..w.details.len()).rev() {
        let s = 1usize << j;
        let p = corr_circ(&a, &lo, s);
        let q = corr_circ(&w.details[j], &hi, s);
        a = p.iter().zip(q.iter()).map(|(u, v)| u + v).collect();
    }
    a
}

fn median_abs(x: &[f64]) -> f64 {
    let mut v: Vec<f64> = x.iter().map(|a| a.abs()).collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    if n == 0 {
        0.0
    } else if n % 2 == 1 {
        v[n / 2]
    } else {
        0.5 * (v[n / 2 - 1] + v[n / 2])
    }
}

/// Coiflet-5 (`coif5`) decomposition low-pass filter exactly as MATLAB `wfilters('coif5')` (30 taps).
pub const COIF5_LO: [f64; 30] = [-9.517657273819165e-08, -1.6744288576823017e-07, 2.0637618513646814e-06, 3.7346551751414047e-06, -2.1315026809955787e-05, -4.134043227251251e-05, 0.00014054114970203437, 0.00030225958181306315, -0.0006381313430451114, -0.0016628637020130838, 0.0024333732126576722, 0.006764185448053083, -0.009164231162481846, -0.01976177894257264, 0.03268357426711183, 0.0412892087501817, -0.10557420870333893, -0.06203596396290357, 0.4379916261718371, 0.7742896036529562, 0.4215662066908515, -0.05204316317624377, -0.09192001055969624, 0.02816802897093635, 0.023408156785839195, -0.010131117519849788, -0.004159358781386048, 0.0021782363581090178, 0.00035858968789573785, -0.00021208083980379827];

fn coif5_filters() -> ([f64; 30], Vec<f64>, Vec<f64>, Vec<f64>) {
    let n = COIF5_LO.len();
    let lo_d = COIF5_LO;
    let hi_d: Vec<f64> = (0..n).map(|k| if k % 2 == 0 { -lo_d[n - 1 - k] } else { lo_d[n - 1 - k] }).collect();
    let lo_r: Vec<f64> = lo_d.iter().rev().cloned().collect();
    let hi_r: Vec<f64> = hi_d.iter().rev().cloned().collect();
    (lo_d, hi_d, lo_r, hi_r)
}

/// MATLAB `swt(x, L, 'coif5')`: returns `(details[0..L], approx_L)`.  Circular, non-decimated; at level k the filters
/// are `dyadup`-ed `k` times and the output is aligned exactly as MATLAB does (shift `(lf/2)·2^k`).
pub fn swt_matlab(x: &[f64], levels: usize) -> (Vec<Vec<f64>>, Vec<f64>) {
    let (lo, hi, _, _) = coif5_filters();
    let s = x.len() as i64;
    let lf = lo.len() as i64;
    let mut a = x.to_vec();
    let mut dets = Vec::with_capacity(levels);
    for k in 0..levels {
        let st = 1i64 << k;
        let sh = (lf / 2) * st;
        let mut d = vec![0.0; x.len()];
        let mut na = vec![0.0; x.len()];
        for n in 0..s {
            let (mut sd, mut sa) = (0.0, 0.0);
            for j in 0..lf {
                let idx = (n + sh - j * st).rem_euclid(s) as usize;
                sd += hi[j as usize] * a[idx];
                sa += lo[j as usize] * a[idx];
            }
            d[n as usize] = sd;
            na[n as usize] = sa;
        }
        dets.push(d);
        a = na;
    }
    (dets, a)
}

fn upconv_matlab(x: &[f64], f: &[f64], lon: usize, out: &mut [f64]) {
    // MATLAB upconvLOC: dyadup(x,0,1) (x at even positions, even length), periodic extension, full convolution, keep.
    let lf = f.len();
    let len = lon as i64; // == 2*x.len()
    for t in 0..lon {
        let mut acc = 0.0;
        for (i, &fi) in f.iter().enumerate() {
            let p = (t as i64 + (lf as i64) / 2 - 1 - i as i64).rem_euclid(len);
            if p % 2 == 0 {
                acc += fi * x[(p / 2) as usize];
            }
        }
        out[t] += acc;
    }
}

/// MATLAB `iswt(swc, 'coif5')` for `swc = [details; approx]`.
pub fn iswt_matlab(dets: &[Vec<f64>], approx: &[f64]) -> Vec<f64> {
    let (_, _, lo_r, hi_r) = coif5_filters();
    let lx = approx.len();
    let mut a = approx.to_vec();
    for k in (1..=dets.len()).rev() {
        let step = 1usize << (k - 1);
        for first in 0..step {
            let ind: Vec<usize> = (first..lx).step_by(step).collect();
            let lon = ind.len();
            let ev: Vec<usize> = ind.iter().step_by(2).cloned().collect();
            let od: Vec<usize> = ind.iter().skip(1).step_by(2).cloned().collect();
            let mut x1 = vec![0.0; lon];
            let mut x2 = vec![0.0; lon];
            upconv_matlab(&ev.iter().map(|&i| a[i]).collect::<Vec<_>>(), &lo_r, lon, &mut x1);
            upconv_matlab(&ev.iter().map(|&i| dets[k - 1][i]).collect::<Vec<_>>(), &hi_r, lon, &mut x1);
            upconv_matlab(&od.iter().map(|&i| a[i]).collect::<Vec<_>>(), &lo_r, lon, &mut x2);
            upconv_matlab(&od.iter().map(|&i| dets[k - 1][i]).collect::<Vec<_>>(), &hi_r, lon, &mut x2);
            for (t, &i) in ind.iter().enumerate() {
                a[i] = 0.5 * (x1[t] + x2[(t + lon - 1) % lon]);
            }
        }
    }
    a
}

/// MATLAB `ddencmp('den','wv',x)` threshold: `sqrt(2 ln n) · median|d1| / 0.6745`, `d1` = level-1 Haar detail.
pub fn ddencmp_threshold(x: &[f64]) -> f64 {
    let d1: Vec<f64> = (0..x.len() / 2).map(|i| (x[2 * i + 1] - x[2 * i]) / std::f64::consts::SQRT_2).collect();
    (2.0 * (x.len() as f64).ln()).sqrt() * median_abs(&d1) / 0.6745
}

/// HAPPE `wICA.m` per-component step: zero-pad to a multiple of 2^L, soft-threshold every SWT row (approximation
/// included) at `mult · ddencmp` threshold, inverse SWT.  Returns the wavelet-denoised IC (`wIC`), original length.
pub fn wica_denoise_ic(ic: &[f64], levels: usize, mult: f64) -> Vec<f64> {
    let m = 1usize << levels;
    let pad = (m - ic.len() % m) % m;
    let mut sig = ic.to_vec();
    sig.extend(std::iter::repeat(0.0).take(pad));
    let thr = ddencmp_threshold(&sig) * mult;
    let soft = |v: f64| v.signum() * (v.abs() - thr).max(0.0);
    let (mut dets, mut a) = swt_matlab(&sig, levels);
    for d in dets.iter_mut() {
        for v in d.iter_mut() {
            *v = soft(*v);
        }
    }
    for v in a.iter_mut() {
        *v = soft(*v);
    }
    let mut out = iswt_matlab(&dets, &a);
    out.truncate(ic.len());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn swt_round_trip() {
        let x: Vec<f64> = (0..500).map(|i| ((i as f64) * 0.13).sin() + 0.3 * ((i * i) as f64 % 7.0)).collect();
        let w = swt(&x, 5, &DB4_LO);
        let y = iswt(&w, &DB4_LO);
        let e = x.iter().zip(y.iter()).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        assert!(e < 1e-10, "{e}");
    }
    #[test]
    fn matlab_swt_iswt_round_trip() {
        let x: Vec<f64> = (0..512).map(|i| ((i as f64) * 0.11).sin() * 5.0 + ((i * i) as f64 % 11.0)).collect();
        let (d, a) = swt_matlab(&x, 5);
        let y = iswt_matlab(&d, &a);
        let e = x.iter().zip(y.iter()).map(|(p, q)| (p - q).abs()).fold(0.0, f64::max);
        // MATLAB's coif5 taps are only orthonormal to ~1e-7, so the round trip is exact to that level
        assert!(e < 1e-5, "{e}");
    }
    #[test]
    fn vmd_sums_back() {
        let fs = 250.0;
        let x: Vec<f64> = (0..1000).map(|i| { let t = i as f64 / fs; (2.0*std::f64::consts::PI*5.0*t).sin() + 0.5*(2.0*std::f64::consts::PI*40.0*t).sin() }).collect();
        let (m, cf, _) = vmd(&x, fs, &VmdOpts { k: 2, ..Default::default() });
        let s: Vec<f64> = (0..1000).map(|i| m[0][i] + m[1][i]).collect();
        let e = x.iter().zip(s.iter()).map(|(a, b)| (a - b).powi(2)).sum::<f64>() / x.iter().map(|a| a * a).sum::<f64>();
        assert!(e < 1e-2, "{e}");
        assert!((cf[0] - 5.0).abs() < 1.0 && (cf[1] - 40.0).abs() < 2.0, "{cf:?}");
    }
    #[test]
    fn emd_sums_back() {
        let x: Vec<f64> = (0..800).map(|i| (i as f64 * 0.5).sin() + (i as f64 * 0.03).sin()).collect();
        let (imfs, r) = emd(&x, 6, 0.2, 50);
        assert!(imfs.len() >= 2);
        let e = (0..800).map(|i| (x[i] - r[i] - imfs.iter().map(|m| m[i]).sum::<f64>()).abs()).fold(0.0, f64::max);
        assert!(e < 1e-9);
    }
}
