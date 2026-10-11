//! Port of EEGLAB `clean_rawdata` Artifact Subspace Reconstruction (`asr_calibrate`, `asr_process`, `clean_asr`,
//! `clean_windows`, burst rejection of `clean_artifacts`), Euclidean (non-Riemannian, non-GPU) variant.
//! The arithmetic (incl. the memory-driven block splitting of `asr_process`) follows the MATLAB code so that results
//! are reproducible against it.

use crate::linalg::*;
use crate::special::{gamma, gammaincinv};
use crate::yulewalk::{filter, yulewalk};
use nalgebra::DMatrix;

type Chans = Vec<Vec<f64>>;

#[derive(Clone, Debug)]
pub struct AsrParams {
    /// `BurstCriterion` / `cutoff` (std-devs above clean-data RMS that a component may reach).
    pub cutoff: f64,
    /// seconds; `None` -> `max(0.5, 1.5*nbchan/srate)`
    pub window_len: Option<f64>,
    /// samples; `None` -> `floor(srate*windowlen/2)`
    pub step_size: Option<usize>,
    /// fraction of channels (<1) or count of dimensions that may be rejected per window
    pub max_dims: f64,
    pub ref_max_bad_channels: f64,
    pub ref_tolerances: [f64; 2],
    pub ref_wnd_len: f64,
    /// MB budget used for the block splitting in calibrate/process (MATLAB passes 64 from clean_artifacts)
    pub max_mem: f64,
    /// use the whole recording for calibration (`'off'` reference parameters)
    pub calibrate_on_all: bool,
    /// Riemannian ASR (`UseRiemannian`).
    pub riemannian: bool,
    /// Riemannian ASR: fixed block length in seconds (`None` = MATLAB memory-based blocks).
    pub rasr_block_seconds: Option<f64>,
}

impl AsrParams {
    /// Defaults of `clean_asr` (reference tolerances `[-3.5 5.5]`).
    pub fn clean_asr(cutoff: f64) -> Self {
        AsrParams { cutoff, window_len: None, step_size: None, max_dims: 0.66, ref_max_bad_channels: 0.075,
            ref_tolerances: [-3.5, 5.5], ref_wnd_len: 1.0, max_mem: 64.0, calibrate_on_all: false,
            riemannian: false, rasr_block_seconds: None }
    }
    /// As called from `clean_artifacts` / `pop_clean_rawdata` (`BurstCriterionRefTolerances` = `[-inf 5.5]`).
    pub fn clean_artifacts(cutoff: f64) -> Self {
        AsrParams { ref_tolerances: [f64::NEG_INFINITY, 5.5], ..Self::clean_asr(cutoff) }
    }
}

#[derive(Clone, Debug)]
pub struct AsrState {
    pub m: Mat,
    pub t: Mat,
    pub b: Vec<f64>,
    pub a: Vec<f64>,
    /// moving-average state: `C*C` rows of `N` values
    pub cov: Option<Vec<Vec<f64>>>,
    pub carry: Option<Chans>,
    pub iir: Vec<Vec<f64>>,
    pub last_r: Option<Mat>,
    pub last_trivial: bool,
}

// ------------------------------------------------------------------------------------------------------------
// helpers
// ------------------------------------------------------------------------------------------------------------

/// MATLAB `a:step:b` element count rule (tolerant to round-off) and values.
pub fn colon(start: f64, step: f64, limit: f64) -> Vec<f64> {
    if step == 0.0 || (step > 0.0 && start > limit) || (step < 0.0 && start < limit) {
        return vec![];
    }
    let r = (limit - start) / step;
    let n = (r + 1e-10 * r.abs().max(1.0)).floor() as i64 + 1;
    // MATLAB evaluates the first half of the range forward from `start` and the second half backward from the
    // (limit-clipped) final element; this changes round-off and therefore `round()` of x.5 cases.
    let nn = (n - 1).max(0);
    let mut last = start + nn as f64 * step;
    if (step > 0.0 && last > limit) || (step < 0.0 && last < limit) {
        last = limit;
    }
    let half = nn / 2;
    (0..=nn).map(|k| if k <= half { start + k as f64 * step } else { last - (nn - k) as f64 * step }).collect()
}

fn matlab_round(x: f64) -> f64 {
    x.round() // half away from zero, like MATLAB
}

fn median_of(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = s.len();
    if n == 0 {
        return f64::NAN;
    }
    if n % 2 == 1 { s[n / 2] } else { 0.5 * (s[n / 2 - 1] + s[n / 2]) }
}

/// `[mu, sig, alpha, beta] = fit_eeg_distribution(X, min_clean_fraction, max_dropout_fraction, quants, step_sizes, beta)`
pub fn fit_eeg_distribution(
    x_in: &[f64],
    min_clean_fraction: f64,
    max_dropout_fraction: f64,
    quants: [f64; 2],
    step_sizes: [f64; 2],
    betas: &[f64],
) -> (f64, f64, f64, f64) {
    let mut x: Vec<f64> = x_in.to_vec();
    x.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = x.len();
    let mut zbounds: Vec<[f64; 2]> = vec![];
    let mut rescale: Vec<f64> = vec![];
    for &b in betas {
        let mut zb = [0.0; 2];
        for k in 0..2 {
            let s = if quants[k] - 0.5 > 0.0 { 1.0 } else if quants[k] - 0.5 < 0.0 { -1.0 } else { 0.0 };
            zb[k] = s * gammaincinv(s * (2.0 * quants[k] - 1.0), 1.0 / b).powf(1.0 / b);
        }
        zbounds.push(zb);
        rescale.push(b / (2.0 * gamma(1.0 / b)));
    }
    let lower_min = quants[0].min(quants[1]);
    let max_width = quants[1] - quants[0];
    let min_width = min_clean_fraction * max_width;
    let nrows = matlab_round(n as f64 * max_width) as usize;
    let col_offsets: Vec<usize> = colon(lower_min, step_sizes[0], lower_min + max_dropout_fraction)
        .iter()
        .map(|&v| matlab_round(n as f64 * v) as usize)
        .collect();
    // X(i, j) = sorted[(i+1) + offset_j] (1-based) -> sorted[i + offset_j] (0-based)
    let ncol = col_offsets.len();
    let mut xm: Vec<Vec<f64>> = vec![vec![0.0; nrows]; ncol];
    let mut x1 = vec![0.0; ncol];
    for j in 0..ncol {
        for i in 0..nrows {
            xm[j][i] = x[i + col_offsets[j]];
        }
        x1[j] = xm[j][0];
        for i in 0..nrows {
            xm[j][i] -= x1[j];
        }
    }
    let mut opt_val = f64::INFINITY;
    let mut opt_beta = betas[0];
    let mut opt_bounds = zbounds[0];
    let mut opt_lu = [0.0, 0.0];
    for mf in colon(max_width, -step_sizes[1], min_width) {
        let m = matlab_round(n as f64 * mf) as usize;
        let nbins = matlab_round(3.0 * (1.0 + m as f64 / 2.0).log2()) as usize;
        // log histogram counts per column
        let mut logq: Vec<Vec<f64>> = vec![vec![0.0; nbins]; ncol];
        for j in 0..ncol {
            let scale = nbins as f64 / xm[j][m - 1];
            let mut counts = vec![0.0f64; nbins];
            for i in 0..m {
                let h = xm[j][i] * scale;
                let bin = if h.is_nan() { 0 } else { (h.floor().max(0.0) as usize).min(nbins - 1) };
                counts[bin] += 1.0;
            }
            for k in 0..nbins {
                logq[j][k] = (counts[k] + 0.01).ln();
            }
        }
        for (bi, &beta) in betas.iter().enumerate() {
            let bounds = zbounds[bi];
            let xs: Vec<f64> = (0..nbins)
                .map(|k| bounds[0] + (0.5 + k as f64) / nbins as f64 * (bounds[1] - bounds[0]))
                .collect();
            let mut p: Vec<f64> = xs.iter().map(|v| (-v.abs().powf(beta)).exp() * rescale[bi]).collect();
            let sp: f64 = p.iter().sum();
            for v in p.iter_mut() {
                *v /= sp;
            }
            let mut min_val = f64::INFINITY;
            let mut idx = 0usize;
            for j in 0..ncol {
                let mut kl = 0.0;
                for k in 0..nbins {
                    kl += p[k] * (p[k].ln() - logq[j][k]);
                }
                kl += (m as f64).ln();
                if kl < min_val {
                    min_val = kl;
                    idx = j;
                }
            }
            if min_val < opt_val {
                opt_val = min_val;
                opt_beta = beta;
                opt_bounds = bounds;
                opt_lu = [x1[idx], x1[idx] + xm[idx][m - 1]];
            }
        }
    }
    let alpha = (opt_lu[1] - opt_lu[0]) / (opt_bounds[1] - opt_bounds[0]);
    let mu = opt_lu[0] - opt_bounds[0] * alpha;
    let sig = (alpha * alpha * gamma(3.0 / opt_beta) / gamma(1.0 / opt_beta)).sqrt();
    (mu, sig, alpha, opt_beta)
}

fn shape_range() -> Vec<f64> {
    colon(1.7, 0.15, 3.5)
}

/// Window RMS series used by `asr_calibrate` / `clean_windows`: windows of `n` samples at `offsets` (1-based starts).
fn window_rms(x: &[f64], offsets: &[usize], n: usize) -> Vec<f64> {
    offsets
        .iter()
        .map(|&o| {
            let mut s = 0.0;
            for k in 0..n {
                let v = x[o - 1 + k];
                s += v * v;
            }
            (s / n as f64).sqrt()
        })
        .collect()
}

fn offsets_for(s: usize, n: usize, overlap: f64) -> Vec<usize> {
    // round(1:N*(1-overlap):S-N)
    colon(1.0, n as f64 * (1.0 - overlap), s as f64 - n as f64).iter().map(|&v| matlab_round(v) as usize).collect()
}

fn geometric_median(x: &[Vec<f64>], tol: f64, max_iter: usize) -> Vec<f64> {
    let nrow = x.len();
    let nv = x[0].len();
    let mut y: Vec<f64> = (0..nv).map(|j| median_of(&x.iter().map(|r| r[j]).collect::<Vec<_>>())).collect();
    for _ in 0..max_iter {
        let mut num = vec![0.0; nv];
        let mut den = 0.0;
        for r in 0..nrow {
            let mut d2 = 0.0;
            for j in 0..nv {
                let d = x[r][j] - y[j];
                d2 += d * d;
            }
            let inv = 1.0 / d2.sqrt();
            den += inv;
            for j in 0..nv {
                num[j] += x[r][j] * inv;
            }
        }
        let ynew: Vec<f64> = num.iter().map(|v| v / den).collect();
        let diff: f64 = ynew.iter().zip(y.iter()).map(|(a, b)| (a - b) * (a - b)).sum::<f64>().sqrt();
        let nrm: f64 = ynew.iter().map(|a| a * a).sum::<f64>().sqrt();
        y = ynew;
        if diff / nrm < tol {
            break;
        }
    }
    y
}

fn sqrtm_sym(m: &Mat) -> Mat {
    let (vals, vecs) = sym_eig_sorted_asc(m);
    let n = vals.len();
    let mut d = Mat::zeros(n, n);
    for i in 0..n {
        d[(i, i)] = vals[i].max(0.0).sqrt();
    }
    &vecs * d * vecs.transpose()
}

pub fn default_spectral_filter(srate: f64) -> Result<(Vec<f64>, Vec<f64>), String> {
    let mut fv: Vec<f64> = [0.0, 2.0, 3.0, 13.0, 16.0, 40.0, 80f64.min(srate / 2.0 - 1.0)].iter().map(|v| v * 2.0 / srate).collect();
    fv.push(1.0);
    let mut amps = vec![3.0, 0.75, 0.33, 0.33, 1.0, 1.0, 3.0, 3.0];
    if srate < 80.0 {
        let l = fv.len();
        fv.remove(l - 3);
        amps.pop();
    }
    yulewalk(8, &fv, &amps)
}

// ------------------------------------------------------------------------------------------------------------
// asr_calibrate
// ------------------------------------------------------------------------------------------------------------

fn calibrate_impl(
    riemann: bool,
    x_in: &Chans,
    srate: f64,
    cutoff: f64,
    ba: Option<(Vec<f64>, Vec<f64>)>,
    window_len: f64,
    window_overlap: f64,
    max_dropout_fraction: f64,
    min_clean_fraction: f64,
    maxmem: f64,
) -> Result<AsrState, String> {
    let c = x_in.len();
    let s = x_in[0].len();
    let blocksize = 10usize.max(((c * c * s) as f64 * 8.0 * 3.0 * 2.0 / (maxmem * 2f64.powi(21))).ceil() as usize);
    let (b, a) = match ba {
        Some(v) => v,
        None => default_spectral_filter(srate)?,
    };
    let mut x: Chans = x_in.iter().map(|ch| ch.iter().map(|&v| if v.is_finite() { v } else { 0.0 }).collect()).collect();
    let mut iir = vec![];
    for ch in x.iter_mut() {
        let (y, zf) = filter(&b, &a, ch, None);
        *ch = y;
        iir.push(zf);
    }
    if x.iter().any(|ch| ch.iter().any(|v| !v.is_finite())) {
        return Err("The IIR filter diverged on your data. Please try using either a more conservative filter or removing some bad sections/channels from the calibration data.".into());
    }
    // U: block covariance accumulation
    let nrows = (s + blocksize - 1) / blocksize;
    let mut u: Vec<Vec<f64>> = vec![vec![0.0; c * c]; nrows];
    for k in 1..=blocksize {
        for r in 0..nrows {
            let idx = (k + r * blocksize).min(s) - 1;
            for c2 in 0..c {
                let v2 = x[c2][idx];
                for c1 in 0..c {
                    u[r][c1 + c * c2] += x[c1][idx] * v2;
                }
            }
        }
    }
    for row in u.iter_mut() {
        for v in row.iter_mut() {
            *v /= blocksize as f64;
        }
    }
    let med = geometric_median(&u, 1e-5, 500);
    let med_m = Mat::from_fn(c, c, |i, j| med[i + c * j]);
    let m = sqrtm_sym(&med_m);
    let n = matlab_round(window_len * srate) as usize;
    if s < n {
        return Err("No enough reference data, call the function from the command line and try changing the 'BurstCriterionRefTolerances' parameters".into());
    }
    let (_vals, v) = if riemann { rasr_eigenspace(&m) } else { sym_eig_sorted_asc(&m) };
    // X = abs(X*V): projections (S x C)
    let mut mu = vec![0.0; c];
    let mut sig = vec![0.0; c];
    let offsets = offsets_for(s, n, window_overlap);
    if offsets.len() <= 1 {
        return Err("No enough reference data, call the function from the command line and try changing the 'BurstCriterionRefTolerances' parameters".into());
    }
    let betas = shape_range();
    for comp in (0..c).rev() {
        let mut proj = vec![0.0; s];
        for t in 0..s {
            let mut acc = 0.0;
            for ch in 0..c {
                acc += x[ch][t] * v[(ch, comp)];
            }
            proj[t] = acc.abs();
        }
        let rms = window_rms(&proj, &offsets, n);
        let (mu_c, sig_c, _, _) = fit_eeg_distribution(&rms, min_clean_fraction, max_dropout_fraction, [0.022, 0.6], [0.01, 0.01], &betas);
        if let Ok(d) = std::env::var("ASR_DUMP_RMS") {
            let txt: Vec<String> = rms.iter().map(|v| format!("{:.17e}", v)).collect();
            let _ = std::fs::write(format!("{}/rms_{}.txt", d, comp), format!("{:.17e} {:.17e}\n{}", mu_c, sig_c, txt.join("\n")));
        }
        mu[comp] = mu_c;
        sig[comp] = sig_c;
    }
    let t = Mat::from_fn(c, c, |i, j| (mu[i] + cutoff * sig[i]) * v[(j, i)]);
    Ok(AsrState { m, t, b, a, cov: None, carry: None, iir, last_r: None, last_trivial: true })
}


/// `asr_calibrate` (Euclidean ASR).
pub fn asr_calibrate(
    x_in: &Chans,
    srate: f64,
    cutoff: f64,
    ba: Option<(Vec<f64>, Vec<f64>)>,
    window_len: f64,
    window_overlap: f64,
    max_dropout_fraction: f64,
    min_clean_fraction: f64,
    maxmem: f64,
) -> Result<AsrState, String> {
    calibrate_impl(false, x_in, srate, cutoff, ba, window_len, window_overlap, max_dropout_fraction, min_clean_fraction, maxmem)
}

/// `asr_calibrate_r` (Riemannian ASR of Blum et al., EEGLAB clean_rawdata): defaults window 0.1 s, overlap 0.5, min clean 0.3.
pub fn rasr_calibrate(x_in: &Chans, srate: f64, cutoff: f64, maxmem: f64) -> Result<AsrState, String> {
    calibrate_impl(true, x_in, srate, cutoff, None, 0.1, 0.5, 0.1, 0.3, maxmem)
}

/// Eigen-decomposition used by `rasr_nonlinear_eigenspace(L, k=nchan)`: with k equal to the dimension the Grassmann
/// manifold is a point, so Manopt returns the starting point `eigs(L + diag(L\rho))` with `rho = diag(X X')= 1`
/// (X is an orthogonal matrix).  Returns eigenvalues (ascending) and the matching eigenvectors.
pub fn rasr_eigenspace(l: &Mat) -> (Vec<f64>, Mat) {
    let c = l.nrows();
    let ones = Mat::from_element(c, 1, 1.0);
    let sol = l.clone().lu().solve(&ones).unwrap_or_else(|| ones.clone());
    let mut mm = l.clone();
    for i in 0..c {
        mm[(i, i)] += sol[(i, 0)];
    }
    sym_eig_sorted_asc(&mm)
}

/// Karcher (geometric) mean of two SPD matrices: `A^(1/2) (A^(-1/2) B A^(-1/2))^(1/2) A^(1/2)`.
pub fn spd_geometric_mean(a: &Mat, b: &Mat) -> Mat {
    let (da, va) = sym_eig_sorted_asc(a);
    let c = a.nrows();
    let half = &va * Mat::from_diagonal(&nalgebra::DVector::from_iterator(c, da.iter().map(|x| x.max(0.0).sqrt()))) * va.transpose();
    let ihalf = &va * Mat::from_diagonal(&nalgebra::DVector::from_iterator(c, da.iter().map(|x| 1.0 / x.max(1e-300).sqrt()))) * va.transpose();
    let mid = &ihalf * b * &ihalf;
    let mid = (&mid + mid.transpose()) * 0.5;
    let (dm, vm) = sym_eig_sorted_asc(&mid);
    let msq = &vm * Mat::from_diagonal(&nalgebra::DVector::from_iterator(c, dm.iter().map(|x| x.max(0.0).sqrt()))) * vm.transpose();
    let g = &half * msq * &half;
    (&g + g.transpose()) * 0.5
}

// ------------------------------------------------------------------------------------------------------------
// asr_process
// ------------------------------------------------------------------------------------------------------------

fn moving_average_pairs(
    c: usize,
    n: usize,
    x: &Chans,        // filtered block, C x len
    zi: &Option<Vec<Vec<f64>>>,
    update_at: &[usize], // 1-based columns
) -> (Vec<Vec<f64>>, Vec<Vec<f64>>) {
    // returns (Xcov at update columns as [update][c*c], new state [c*c][n])
    let len = x[0].len();
    let nu = update_at.len();
    let mut out = vec![vec![0.0; c * c]; nu];
    let mut zf = vec![vec![0.0; n]; c * c];
    let s = 1.0 / n as f64; // S = [-ones; ones]/N
    for c2 in 0..c {
        for c1 in 0..=c2 {
            let pr = c1 + c * c2;
            // Y = [Zi, products]; length M = n + len
            let ytot = n + len;
            let yval = |t: usize| -> f64 {
                if t < n {
                    match zi {
                        Some(z) => z[pr][t],
                        None => 0.0,
                    }
                } else {
                    x[c1][t - n] * x[c2][t - n]
                }
            };
            let mut cum = 0.0f64;
            let mut ui = 0;
            let mut last_val = 0.0;
            for j in 0..len {
                cum += yval(j) * (-s);
                cum += yval(j + n) * s;
                last_val = cum;
                while ui < nu && update_at[ui] == j + 1 {
                    out[ui][pr] = cum;
                    ui += 1;
                }
            }
            // Zf = [-(X(:,end)*N - Y(:,end-N+1)) Y(:,end-N+2:end)]
            let first = -(last_val * n as f64 - yval(ytot - n));
            zf[pr][0] = first;
            for k in 1..n {
                zf[pr][k] = yval(ytot - n + k);
            }
            if c1 != c2 {
                let pr2 = c2 + c * c1;
                for ui in 0..nu {
                    let v = out[ui][pr];
                    out[ui][pr2] = v;
                }
                let z = zf[pr].clone();
                zf[pr2] = z;
            }
        }
    }
    (out, zf)
}

pub fn asr_process(
    data_in: &Chans,
    srate: f64,
    state: &mut AsrState,
    windowlen: Option<f64>,
    lookahead: Option<f64>,
    stepsize: Option<usize>,
    maxdims_in: f64,
    maxmem: f64,
) -> Result<Chans, String> {
    let c = data_in.len();
    let windowlen = windowlen.unwrap_or(0.5).max(1.5 * c as f64 / srate);
    let lookahead = lookahead.unwrap_or(windowlen / 2.0);
    let stepsize = stepsize.unwrap_or(32);
    let maxdims = if maxdims_in < 1.0 { matlab_round(c as f64 * maxdims_in) } else { maxdims_in };
    let s = data_in[0].len();
    if s == 0 {
        return Ok(data_in.clone());
    }
    let n = matlab_round(windowlen * srate) as usize;
    let p = matlab_round(lookahead * srate) as usize;
    // carry
    if state.carry.is_none() {
        let mut carry = vec![vec![0.0; p]; c];
        for ch in 0..c {
            for j in 0..p {
                carry[ch][j] = 2.0 * data_in[ch][0] - data_in[ch][(p - j) % s];
            }
        }
        state.carry = Some(carry);
    }
    let carry = state.carry.clone().unwrap();
    let mut data: Chans = (0..c)
        .map(|ch| {
            let mut v = carry[ch].clone();
            v.extend(data_in[ch].iter().cloned());
            for x in v.iter_mut() {
                if !x.is_finite() {
                    *x = 0.0;
                }
            }
            v
        })
        .collect();
    let cf = c as f64;
    if maxmem * 1024.0 * 1024.0 - cf * cf * p as f64 * 8.0 * 3.0 < 0.0 {
        return Err("Not enough memory".into());
    }
    let sf = s as f64;
    let splits = (((cf * cf * sf * 8.0 * 8.0 + cf * cf * 8.0 * sf / stepsize as f64 + cf * sf * 8.0 * 2.0 + sf * 8.0 * 5.0)
        / (maxmem * 1024.0 * 1024.0 - cf * cf * p as f64 * 8.0 * 3.0))
        .ceil() as usize)
        .min(10000)
        .max(1);
    for i in 1..=splits {
        let rs = ((i - 1) as f64 * sf / splits as f64).floor() as usize; // 0-based start
        let re = ((i as f64 * sf / splits as f64).floor() as usize).min(s); // 1-based inclusive end == 0-based exclusive
        if re <= rs {
            continue;
        }
        let len = re - rs;
        // X = filter(B,A,data(:,range+P), state.iir)
        let mut xblk: Chans = Vec::with_capacity(c);
        for ch in 0..c {
            let seg = &data[ch][rs + p..rs + p + len];
            let (y, zf) = filter(&state.b, &state.a, seg, Some(&state.iir[ch]));
            state.iir[ch] = zf;
            xblk.push(y);
        }
        let mut update_at: Vec<usize> = vec![];
        {
            let mut k = 1;
            while stepsize * k <= len + stepsize - 1 {
                update_at.push((stepsize * k).min(len));
                k += 1;
            }
        }
        if state.last_r.is_none() {
            update_at.insert(0, 1);
            state.last_r = Some(eye(c));
        }
        let (xcov, zf) = moving_average_pairs(c, n, &xblk, &state.cov, &update_at);
        state.cov = Some(zf);
        let mut last_n = 0usize;
        for (j, &nn) in update_at.iter().enumerate() {
            let cov = Mat::from_fn(c, c, |r, cc| xcov[j][r + c * cc]);
            let (d, v) = sym_eig_sorted_asc(&cov);
            let tv = &state.t * &v;
            let mut keep = vec![false; c];
            for k in 0..c {
                let thr: f64 = (0..c).map(|r| tv[(r, k)] * tv[(r, k)]).sum();
                keep[k] = d[k] < thr || ((k + 1) as f64) < (cf - maxdims);
            }
            let trivial = keep.iter().all(|&k| k);
            let r_mat = if !trivial {
                let vm = v.transpose() * &state.m;
                let scaled = Mat::from_fn(c, c, |r, cc| if keep[r] { vm[(r, cc)] } else { 0.0 });
                &state.m * pinv(&scaled) * v.transpose()
            } else {
                eye(c)
            };
            if !trivial || !state.last_trivial {
                let cnt = nn - last_n;
                let last_r = state.last_r.clone().unwrap();
                for t in 0..cnt {
                    let col = rs + last_n + t;
                    let blend = (1.0 - (std::f64::consts::PI * (t + 1) as f64 / cnt as f64).cos()) / 2.0;
                    let dcol: Vec<f64> = (0..c).map(|ch| data[ch][col]).collect();
                    for ch in 0..c {
                        let mut a1 = 0.0;
                        let mut a2 = 0.0;
                        for k in 0..c {
                            a1 += r_mat[(ch, k)] * dcol[k];
                            a2 += last_r[(ch, k)] * dcol[k];
                        }
                        data[ch][col] = blend * a1 + (1.0 - blend) * a2;
                    }
                }
            }
            last_n = nn;
            state.last_r = Some(r_mat);
            state.last_trivial = trivial;
        }
    }
    // carry = last P columns of [carry data]
    let total = data[0].len();
    state.carry = Some((0..c).map(|ch| data[ch][total - p..].to_vec()).collect());
    Ok((0..c).map(|ch| data[ch][..total - p].to_vec()).collect())
}

// ------------------------------------------------------------------------------------------------------------
// clean_windows / clean_asr / burst rejection
// ------------------------------------------------------------------------------------------------------------

/// `[signal, sample_mask] = clean_windows(signal, max_bad_channels, zthresholds, window_len, ...)` (defaults of the
/// MATLAB function for the remaining arguments).
pub fn clean_windows(
    signal: &Chans,
    srate: f64,
    max_bad_channels: f64,
    zthresholds: [f64; 2],
    window_len: f64,
) -> (Chans, Vec<bool>) {
    let (window_overlap, max_dropout, min_clean, trunc_q, steps) = (0.66, 0.1, 0.25, [0.022, 0.6], [0.01, 0.01]);
    let c = signal.len();
    let s = signal[0].len();
    let mb = if max_bad_channels > 0.0 && max_bad_channels < 1.0 { matlab_round(c as f64 * max_bad_channels) as usize } else { max_bad_channels as usize };
    let n = (window_len * srate) as usize;
    let offsets = offsets_for(s, n, window_overlap);
    let betas = shape_range();
    let mut wz: Vec<Vec<f64>> = vec![];
    for ch in 0..c {
        let x = window_rms(&signal[ch], &offsets, n);
        let (mu, sig, _, _) = fit_eeg_distribution(&x, min_clean, max_dropout, trunc_q, steps, &betas);
        wz.push(x.iter().map(|v| (v - mu) / sig).collect());
    }
    let nw = offsets.len();
    let mut remove = vec![false; nw];
    for w in 0..nw {
        let mut col: Vec<f64> = (0..c).map(|ch| wz[ch][w]).collect();
        col.sort_by(|a, b| a.partial_cmp(b).unwrap());
        if zthresholds[0].max(zthresholds[1]) > 0.0 && col[c - 1 - mb] > zthresholds[0].max(zthresholds[1]) {
            remove[w] = true;
        }
        if zthresholds[0].min(zthresholds[1]) < 0.0 && col[mb] < zthresholds[0].min(zthresholds[1]) {
            remove[w] = true;
        }
    }
    let mut mask = vec![true; s];
    for (w, &r) in remove.iter().enumerate() {
        if r {
            for k in 0..n {
                mask[offsets[w] - 1 + k] = false;
            }
        }
    }
    // pop_select(...,'point',intervals) drops a retained interval that is a single sample long
    // (observed: a lone trailing sample after a removed window is not kept by EEGLAB).
    let mut i = 0;
    while i < s {
        if mask[i] {
            let mut j = i;
            while j < s && mask[j] { j += 1; }
            if j - i == 1 { mask[i] = false; }
            i = j;
        } else { i += 1; }
    }
    let out: Chans = signal.iter().map(|ch| ch.iter().zip(mask.iter()).filter(|(_, &m)| m).map(|(v, _)| *v).collect()).collect();
    (out, mask)
}

/// `clean_asr(signal, ...)` — returns the repaired data (same length as the input).
pub fn clean_asr(signal: &Chans, srate: f64, p: &AsrParams) -> Result<(Chans, AsrState), String> {
    let c = signal.len();
    let s = signal[0].len();
    let windowlen = p.window_len.unwrap_or_else(|| 0.5f64.max(1.5 * c as f64 / srate));
    let ref_section: Chans = if p.calibrate_on_all {
        signal.clone()
    } else {
        let (r, _) = clean_windows(signal, srate, p.ref_max_bad_channels, p.ref_tolerances, p.ref_wnd_len);
        if r[0].is_empty() { signal.clone() } else { r }
    };
    let mut state = if p.riemannian {
        rasr_calibrate(&ref_section, srate, p.cutoff, p.max_mem)?
    } else {
        asr_calibrate(&ref_section, srate, p.cutoff, None, 0.5, 0.66, 0.1, 0.25, p.max_mem)?
    };
    let stepsize = p.step_size.unwrap_or_else(|| (srate * windowlen / 2.0).floor() as usize);
    let ext = matlab_round(windowlen / 2.0 * srate) as usize;
    let sig: Chans = signal
        .iter()
        .map(|ch| {
            let mut v = ch.clone();
            let last = ch[s - 1];
            for k in 1..=ext {
                // 2*data(:,end) - data(:, end-1:-1:end-ext)
                v.push(2.0 * last - ch[s - 1 - k]);
            }
            v
        })
        .collect();
    let out = if p.riemannian {
        rasr_process(&sig, srate, &mut state, Some(windowlen), Some(windowlen / 2.0), Some(stepsize), p.max_dims, p.max_mem, p.rasr_block_seconds)?
    } else {
        asr_process(&sig, srate, &mut state, Some(windowlen), Some(windowlen / 2.0), Some(stepsize), p.max_dims, p.max_mem)?
    };
    let carry_len = state.carry.as_ref().map(|c| c[0].len()).unwrap_or(0);
    let cleaned: Chans = out.into_iter().map(|ch| ch[carry_len..].to_vec()).collect();
    Ok((cleaned, state))
}

pub struct BurstRejection {
    pub data: Chans,
    pub sample_mask: Vec<bool>,
}

/// `BurstRejection = 'on'` branch of `clean_artifacts`: remove the samples ASR had to modify.
pub fn burst_rejection(signal: &Chans, repaired: &Chans) -> BurstRejection {
    let s = signal[0].len();
    let mut mask: Vec<bool> = (0..s)
        .map(|t| (0..signal.len()).map(|ch| (signal[ch][t] - repaired[ch][t]).abs()).sum::<f64>() < 1e-8)
        .collect();
    // retain intervals shorter than 6 samples (diff(interval) < 5) are dropped
    let mut t = 0;
    while t < s {
        if mask[t] {
            let st = t;
            while t < s && mask[t] {
                t += 1;
            }
            let en = t - 1; // inclusive
            if (en - st) < 5 {
                for k in st..=en {
                    mask[k] = false;
                }
            }
        } else {
            t += 1;
        }
    }
    let data: Chans = signal.iter().map(|ch| ch.iter().zip(mask.iter()).filter(|(_, &m)| m).map(|(v, _)| *v).collect()).collect();
    BurstRejection { data, sample_mask: mask }
}

/// Convenience wrapper: `DMatrix` input (channels x samples) for ASR correction.
pub fn asr_correct_mat(x: &DMatrix<f64>, srate: f64, p: &AsrParams) -> Result<DMatrix<f64>, String> {
    let chans: Chans = (0..x.nrows()).map(|i| x.row(i).iter().cloned().collect()).collect();
    let (out, _) = clean_asr(&chans, srate, p)?;
    Ok(DMatrix::from_fn(x.nrows(), x.ncols(), |i, j| out[i][j]))
}

// ------------------------------------------------------------------------------------------------------------
// Riemannian ASR processing (asr_process_r.m)
// ------------------------------------------------------------------------------------------------------------

/// `asr_process_r`: Riemannian ASR (Blum et al. 2019) as shipped in EEGLAB clean_rawdata.
///
/// Per block the spectrally weighted sample covariance is combined with the previous block's covariance by the
/// Riemannian (Karcher) mean, the eigenspace comes from `rasr_nonlinear_eigenspace`, and one reconstruction matrix per
/// block is cross-faded in at `stepsize` steps.  `block_seconds = None` follows the MATLAB memory formula (one block
/// for ordinary recordings; the MATLAB code itself breaks when more than one block is needed because it overwrites the
/// filter denominator `A`; here the filter is kept intact); `Some(b)` processes fixed blocks of `b` seconds and uses
/// the block length for the covariance normalisation (MATLAB divides by the full recording length).
pub fn rasr_process(
    data_in: &Chans,
    srate: f64,
    state: &mut AsrState,
    windowlen: Option<f64>,
    lookahead: Option<f64>,
    stepsize: Option<usize>,
    maxdims_in: f64,
    maxmem: f64,
    block_seconds: Option<f64>,
) -> Result<Chans, String> {
    let c = data_in.len();
    let windowlen = windowlen.unwrap_or(0.1).max(1.5 * c as f64 / srate);
    let lookahead = lookahead.unwrap_or(windowlen / 2.0);
    let stepsize = stepsize.unwrap_or(4);
    let maxdims = if maxdims_in < 1.0 { matlab_round(c as f64 * maxdims_in) } else { maxdims_in };
    let s = data_in[0].len();
    if s == 0 {
        return Ok(data_in.clone());
    }
    let p = matlab_round(lookahead * srate) as usize;
    if state.carry.is_none() {
        let mut carry = vec![vec![0.0; p]; c];
        for ch in 0..c {
            for j in 0..p {
                carry[ch][j] = 2.0 * data_in[ch][0] - data_in[ch][(p - j) % s];
            }
        }
        state.carry = Some(carry);
    }
    let carry = state.carry.clone().unwrap();
    let mut data: Chans = (0..c)
        .map(|ch| {
            let mut v = carry[ch].clone();
            v.extend(data_in[ch].iter().cloned().map(|x| if x.is_finite() { x } else { 0.0 }));
            v
        })
        .collect();
    let cf = c as f64;
    if maxmem * 1024.0 * 1024.0 - cf * cf * p as f64 * 8.0 * 3.0 < 0.0 {
        return Err("Not enough memory".into());
    }
    let sf = s as f64;
    let splits = match block_seconds {
        Some(b) => ((sf / (b * srate)).ceil() as usize).max(1),
        None => (((cf * cf * sf * 8.0 * 8.0 + cf * cf * 8.0 * sf / stepsize as f64 + cf * sf * 8.0 * 2.0 + sf * 8.0 * 5.0)
            / (maxmem * 1024.0 * 1024.0 - cf * cf * p as f64 * 8.0 * 3.0))
            .ceil() as usize)
            .min(10000)
            .max(1),
    };
    // the covariance state is a single C x C matrix here (stored as the first/only row of `cov`)
    for i in 1..=splits {
        let rs = ((i - 1) as f64 * sf / splits as f64).floor() as usize;
        let re = ((i as f64 * sf / splits as f64).floor() as usize).min(s);
        if re <= rs {
            continue;
        }
        let len = re - rs;
        let mut xblk: Chans = Vec::with_capacity(c);
        for ch in 0..c {
            let seg = &data[ch][rs + p..rs + p + len];
            let (y, zf) = filter(&state.b, &state.a, seg, Some(&state.iir[ch]));
            state.iir[ch] = zf;
            xblk.push(y);
        }
        let norm = if block_seconds.is_some() { len as f64 } else { sf };
        let scm = Mat::from_fn(c, c, |r, q| (0..len).map(|t| xblk[r][t] * xblk[q][t]).sum::<f64>() / norm);
        let xcov = match &state.cov {
            Some(prev) => {
                let pm = Mat::from_fn(c, c, |r, q| prev[0][r + c * q]);
                spd_geometric_mean(&scm, &pm)
            }
            None => scm,
        };
        let mut update_at: Vec<usize> = vec![];
        {
            let mut k = 1;
            while stepsize * k <= len + stepsize - 1 {
                update_at.push((stepsize * k).min(len));
                k += 1;
            }
        }
        if state.last_r.is_none() {
            update_at.insert(0, 1);
            state.last_r = Some(eye(c));
        }
        let (d, v) = rasr_eigenspace(&xcov);
        let tv = &state.t * &v;
        let mut keep = vec![false; c];
        for k in 0..c {
            let thr: f64 = (0..c).map(|r| tv[(r, k)] * tv[(r, k)]).sum();
            keep[k] = d[k] < thr || ((k + 1) as f64) < (cf - maxdims);
        }
        let trivial = keep.iter().all(|&k| k);
        let r_mat = if !trivial {
            let vm = v.transpose() * &state.m;
            let scaled = Mat::from_fn(c, c, |r, cc| if keep[r] { vm[(r, cc)] } else { 0.0 });
            &state.m * pinv(&scaled) * v.transpose()
        } else {
            eye(c)
        };
        let mut last_n = 0usize;
        for &nn in update_at.iter() {
            if !trivial || !state.last_trivial {
                let cnt = nn - last_n;
                let last_r = state.last_r.clone().unwrap();
                for t in 0..cnt {
                    let col = rs + last_n + t;
                    let blend = (1.0 - (std::f64::consts::PI * (t + 1) as f64 / cnt as f64).cos()) / 2.0;
                    let dcol: Vec<f64> = (0..c).map(|ch| data[ch][col]).collect();
                    for ch in 0..c {
                        let (mut a1, mut a2) = (0.0, 0.0);
                        for k in 0..c {
                            a1 += r_mat[(ch, k)] * dcol[k];
                            a2 += last_r[(ch, k)] * dcol[k];
                        }
                        data[ch][col] = blend * a1 + (1.0 - blend) * a2;
                    }
                }
            }
            last_n = nn;
            state.last_r = Some(r_mat.clone());
            state.last_trivial = trivial;
        }
        state.cov = Some(vec![(0..c * c).map(|k| xcov[(k % c, k / c)]).collect()]);
    }
    let total = data[0].len();
    state.carry = Some((0..c).map(|ch| data[ch][total - p..].to_vec()).collect());
    Ok((0..c).map(|ch| data[ch][..total - p].to_vec()).collect())
}
