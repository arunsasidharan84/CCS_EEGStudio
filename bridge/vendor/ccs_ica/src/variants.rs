//! ASR variants and alternative artefact-removal methods (Tier 1/2 of the CCS_EEGStudio roadmap).
//!
//! Verification status is documented per function:
//!  * `bss_cca` / `cca`  — reference: MATLAB `canoncorr`.
//!  * `icanclean_pseudo` — algorithm follows the mne-denoise iCanClean implementation (sliding windows, R² threshold,
//!    least-squares removal); the *pseudo-reference* construction (band-stop of the EEG) is an interpretation.
//!  * `adaptive_asr`     — own design; `alpha = 0` reduces exactly to blockwise `clean_asr`.
//!  * `easr` / `vmd_asr` / `emd_asr` — interpretations (pseudo-channels from delay embedding / modes, then ASR).
//!  * `wica`             — interpretation of wavelet-enhanced ICA (undecimated db4, universal threshold).
//!  * `juggler_*`        — follows the mne-denoise `select_juggler_reference_samples` description.

use crate::asr::*;
use crate::decomp::*;
use crate::linalg::*;
use nalgebra::DMatrix;

pub type Chans = Vec<Vec<f64>>;

fn to_mat(x: &Chans) -> Mat {
    let (c, n) = (x.len(), x[0].len());
    DMatrix::from_fn(c, n, |i, j| x[i][j])
}
fn to_chans(m: &Mat) -> Chans {
    (0..m.nrows()).map(|i| m.row(i).iter().cloned().collect()).collect()
}

// ------------------------------------------------------------------------------------------------------------
// CCA (MATLAB canoncorr)
// ------------------------------------------------------------------------------------------------------------

pub struct Cca {
    /// c x k canonical weights for X (unit-variance variates, `(n-1)` normalisation as in `canoncorr`)
    pub a: Mat,
    pub b: Mat,
    /// canonical correlations, descending
    pub r: Vec<f64>,
}

/// whitening basis W (n x k) with W' C W = I, dropping directions with eigenvalue < rel * max.
fn whitener(c: &Mat, rel: f64) -> Mat {
    let (vals, vecs) = sym_eig_sorted_asc(c);
    let n = vals.len();
    let mx = vals[n - 1].max(0.0);
    let keep: Vec<usize> = (0..n).filter(|&i| vals[i] > rel * mx && vals[i] > 0.0).rev().collect();
    DMatrix::from_fn(n, keep.len(), |r, k| vecs[(r, keep[k])] / vals[keep[k]].sqrt())
}

/// Canonical correlation analysis of X (c x n) and Y (d x n), columns are samples. Inputs are centred internally.
pub fn cca(x: &Mat, y: &Mat) -> Result<Cca, String> {
    if x.ncols() != y.ncols() || x.ncols() < 3 {
        return Err("cca: need the same number (>2) of samples".into());
    }
    let n = x.ncols() as f64;
    let xc = x - row_means(x) * DMatrix::from_element(1, x.ncols(), 1.0);
    let yc = y - row_means(y) * DMatrix::from_element(1, y.ncols(), 1.0);
    let cxx = &xc * xc.transpose() / (n - 1.0);
    let cyy = &yc * yc.transpose() / (n - 1.0);
    let cxy = &xc * yc.transpose() / (n - 1.0);
    let wx = whitener(&cxx, 1e-12);
    let wy = whitener(&cyy, 1e-12);
    if wx.ncols() == 0 || wy.ncols() == 0 {
        return Err("cca: degenerate (zero-variance) input".into());
    }
    let m = wx.transpose() * cxy * &wy;
    let svd = m.svd(true, true);
    let u = svd.u.unwrap();
    let vt = svd.v_t.unwrap();
    let k = wx.ncols().min(wy.ncols());
    let a = &wx * u.columns(0, k);
    let b = &wy * vt.transpose().columns(0, k);
    let r: Vec<f64> = (0..k).map(|i| svd.singular_values[i].min(1.0)).collect();
    Ok(Cca { a, b, r })
}

// ------------------------------------------------------------------------------------------------------------
// BSS-CCA (De Clercq et al. 2006)
// ------------------------------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct BssCcaOpts {
    pub lag: usize,
    pub n_remove: Option<usize>,
    pub rho_threshold: Option<f64>,
}
impl Default for BssCcaOpts {
    fn default() -> Self {
        BssCcaOpts { lag: 1, n_remove: None, rho_threshold: Some(0.9) }
    }
}
pub struct BssCcaReport {
    pub rho: Vec<f64>,
    pub removed: usize,
    pub sources: Mat,
}

/// Muscle suppression by canonical correlation between x(t) and x(t-lag); low-autocorrelation sources are removed.
pub fn bss_cca(x: &Chans, o: &BssCcaOpts) -> Result<(Chans, BssCcaReport), String> {
    let m = to_mat(x);
    let (c, t) = (m.nrows(), m.ncols());
    if o.lag == 0 || t <= o.lag + c {
        return Err("bss_cca: lag must be >=1 and the recording longer than lag + channels".into());
    }
    if o.n_remove.is_none() == o.rho_threshold.is_none() {
        return Err("bss_cca: set exactly one of n_remove / rho_threshold".into());
    }
    let mean = row_means(&m);
    let xc = &m - &mean * DMatrix::from_element(1, t, 1.0);
    let x1 = xc.columns(o.lag, t - o.lag).into_owned();
    let x0 = xc.columns(0, t - o.lag).into_owned();
    let cc = cca(&x1, &x0)?;
    let k = cc.r.len();
    let s = cc.a.transpose() * &xc; // k x t
    let keep: Vec<usize> = if let Some(nr) = o.n_remove {
        (0..k.saturating_sub(nr)).collect()
    } else {
        let th = o.rho_threshold.unwrap();
        (0..k).filter(|&i| cc.r[i] >= th).collect()
    };
    let mixing = pinv(&cc.a.transpose()); // c x k
    let mut out: Mat = DMatrix::zeros(c, t);
    for &i in &keep {
        out += mixing.column(i) * s.row(i);
    }
    out += &mean * DMatrix::from_element(1, t, 1.0);
    Ok((to_chans(&out), BssCcaReport { rho: cc.r, removed: k - keep.len(), sources: s }))
}

// ------------------------------------------------------------------------------------------------------------
// iCanClean (pseudo-reference mode)
// ------------------------------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct ICanCleanOpts {
    pub segment_len: f64,
    pub overlap: f64,
    /// R² threshold above which a canonical component is removed
    pub threshold: f64,
    pub max_reject_fraction: f64,
    /// band (Hz) removed from the EEG to build the pseudo-reference (the reference keeps what is *outside* it)
    pub ref_stop_band: (f64, f64),
}
impl Default for ICanCleanOpts {
    fn default() -> Self {
        ICanCleanOpts { segment_len: 2.0, overlap: 0.0, threshold: 0.7, max_reject_fraction: 0.5, ref_stop_band: (1.0, 8.0) }
    }
}
pub struct ICanCleanReport {
    pub n_windows: usize,
    pub removed_per_window: Vec<usize>,
}

/// Sliding-window iCanClean in pseudo-reference mode (mne-denoise `ICanClean(pseudo_ref=True, filter_ref=("bandstop", band))`):
/// the reference block is the primary data passed through a zero-phase 4th-order Butterworth band-stop.
pub fn icanclean_pseudo(x: &Chans, srate: f64, o: &ICanCleanOpts) -> Result<(Chans, ICanCleanReport), String> {
    use crate::butter::*;
    let sos = butter_sos(4, BType::Bandstop(o.ref_stop_band.0, o.ref_stop_band.1), srate);
    let reference: Chans = x.iter().map(|ch| sosfiltfilt(&sos, ch)).collect::<Result<_, _>>()?;
    icanclean(x, &reference, srate, o)
}

/// iCanClean with explicit reference noise channels (any number of rows, same length as `x`).
pub fn icanclean(x: &Chans, reference: &Chans, srate: f64, o: &ICanCleanOpts) -> Result<(Chans, ICanCleanReport), String> {
    let xm = to_mat(x);
    let ym = to_mat(reference);
    let (c, t) = (xm.nrows(), xm.ncols());
    let win = (o.segment_len * srate) as usize;
    if win < 2 * c.max(ym.nrows()) || win > t {
        return Err("icanclean: segment_len too short for the channel count or longer than the recording".into());
    }
    let step = ((win as f64 * (1.0 - o.overlap)).round() as usize).max(1);
    let mut starts: Vec<usize> = (0..).map(|i| i * step).take_while(|s| s + win <= t).collect();
    if starts.last().map(|s| s + win < t).unwrap_or(true) {
        starts.push(t - win);
    }
    let mut acc: Mat = DMatrix::zeros(c, t);
    let mut w = vec![0.0f64; t];
    let mut removed = vec![];
    for &s in &starts {
        let xw = xm.columns(s, win).into_owned();
        let yw = ym.columns(s, win).into_owned();
        let xc = &xw - row_means(&xw) * DMatrix::from_element(1, win, 1.0);
        let res = cca(&xw, &yw);
        let cleaned = match res {
            Ok(cc) => {
                let r2: Vec<f64> = cc.r.iter().map(|r| r * r).collect();
                let max_bad = if o.max_reject_fraction == 0.0 { 0 } else { 1usize.max((o.max_reject_fraction * r2.len() as f64) as usize) };
                let bad: Vec<usize> = (0..r2.len()).filter(|&i| r2[i] >= o.threshold).take(max_bad).collect(); // r descending
                removed.push(bad.len());
                if bad.is_empty() {
                    xw.clone()
                } else {
                    let ab = DMatrix::from_fn(c, bad.len(), |r, k| cc.a[(r, bad[k])]);
                    let z = xc.transpose() * ab; // win x nb
                    let beta = pinv(&(z.transpose() * &z)) * z.transpose() * xc.transpose(); // nb x c
                    &xw - (&z * beta).transpose()
                }
            }
            Err(_) => {
                removed.push(0);
                xw.clone()
            }
        };
        for j in 0..win {
            for i in 0..c {
                acc[(i, s + j)] += cleaned[(i, j)];
            }
            w[s + j] += 1.0;
        }
    }
    let out = DMatrix::from_fn(c, t, |i, j| if w[j] > 0.0 { acc[(i, j)] / w[j] } else { xm[(i, j)] });
    Ok((to_chans(&out), ICanCleanReport { n_windows: starts.len(), removed_per_window: removed }))
}

// ------------------------------------------------------------------------------------------------------------
// Adaptive (EMA-recalibrated) ASR
// ------------------------------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct AdaptiveAsrOpts {
    /// EMA weight of a new clean block (0 = static ASR)
    pub alpha: f64,
    pub block_seconds: f64,
}
impl Default for AdaptiveAsrOpts {
    fn default() -> Self {
        AdaptiveAsrOpts { alpha: 0.05, block_seconds: 2.0 }
    }
}

fn pad_end(signal: &Chans, ext: usize) -> Chans {
    let s = signal[0].len();
    signal
        .iter()
        .map(|ch| {
            let mut v = ch.clone();
            let last = ch[s - 1];
            for k in 1..=ext {
                v.push(2.0 * last - ch[s - 1 - k]);
            }
            v
        })
        .collect()
}

/// Blockwise ASR whose calibration (`M`, thresholds) tracks slow drifts: after every block whose last window was left
/// untouched (and whose power is below the threshold power) `M² ← (1-α)M² + α·C_block` and the threshold matrix
/// `Θ = TᵀT ← (1-α)Θ + α·g·C_block` (g = tr Θ / tr M²).  Returns (cleaned data, number of updates).
pub fn adaptive_asr(signal: &Chans, srate: f64, p: &AsrParams, o: &AdaptiveAsrOpts) -> Result<(Chans, usize), String> {
    let c = signal.len();
    let s = signal[0].len();
    let windowlen = p.window_len.unwrap_or_else(|| 0.5f64.max(1.5 * c as f64 / srate));
    let ref_section: Chans = if p.calibrate_on_all {
        signal.clone()
    } else {
        let (r, _) = clean_windows(signal, srate, p.ref_max_bad_channels, p.ref_tolerances, p.ref_wnd_len);
        if r[0].is_empty() { signal.clone() } else { r }
    };
    let mut state = asr_calibrate(&ref_section, srate, p.cutoff, None, 0.5, 0.66, 0.1, 0.25, p.max_mem)?;
    let stepsize = p.step_size.unwrap_or_else(|| (srate * windowlen / 2.0).floor() as usize);
    let ext = (windowlen / 2.0 * srate).round() as usize;
    let sig = pad_end(signal, ext);
    let total = sig[0].len();
    // block length is a multiple of the step size so that the window grid is identical to one-shot processing
    let st = stepsize.max(1);
    let blk = st * (((o.block_seconds * srate) / st as f64).round() as usize).max(2);
    let mut out: Chans = vec![vec![]; c];
    let mut updates = 0usize;
    let mut pos = 0usize;
    while pos < total {
        let end = (pos + blk).min(total);
        let block: Chans = sig.iter().map(|ch| ch[pos..end].to_vec()).collect();
        let res = asr_process(&block, srate, &mut state, Some(windowlen), Some(windowlen / 2.0), Some(stepsize), p.max_dims, p.max_mem)?;
        for ch in 0..c {
            out[ch].extend_from_slice(&res[ch]);
        }
        if o.alpha > 0.0 && state.last_trivial {
            // block covariance in the spectrally weighted domain used for calibration
            let bm = to_mat(&block);
            let filt: Vec<Vec<f64>> = (0..c).map(|ch| crate::yulewalk::filter(&state.b, &state.a, &block[ch], None).0).collect();
            let fm = to_mat(&filt);
            let _ = bm;
            let n = fm.ncols() as f64;
            let cb = &fm * fm.transpose() / n;
            let theta = state.t.transpose() * &state.t;
            let m2 = &state.m * &state.m;
            if cb.trace() <= theta.trace() {
                let g = theta.trace() / m2.trace();
                let m2n = &m2 * (1.0 - o.alpha) + &cb * o.alpha;
                let thn = &theta * (1.0 - o.alpha) + &cb * (o.alpha * g);
                state.m = sqrtm_spd(&m2n);
                state.t = sqrtm_spd(&thn);
                updates += 1;
            }
        }
        pos = end;
    }
    let carry_len = ext; // first P output samples are the start-up carry (see clean_asr)
    let cleaned: Chans = out.into_iter().map(|ch| ch[carry_len..carry_len + s].to_vec()).collect();
    Ok((cleaned, updates))
}

// ------------------------------------------------------------------------------------------------------------
// Pseudo-channel ASR: E-ASR (delay embedding), VMD-ASR, EMD-ASR
// ------------------------------------------------------------------------------------------------------------

/// E-ASR: a single channel is delay-embedded into `dim` pseudo-channels (lag `tau` samples), ASR is run on them and
/// the result is mapped back by averaging along anti-diagonals.
pub fn easr_channel(x: &[f64], srate: f64, dim: usize, tau: usize, p: &AsrParams) -> Result<Vec<f64>, String> {
    let n = x.len();
    let span = (dim - 1) * tau;
    if n <= span + 10 {
        return Err("easr: recording too short for this embedding".into());
    }
    let m = n - span;
    let emb: Chans = (0..dim).map(|j| x[j * tau..j * tau + m].to_vec()).collect();
    let (clean, _) = clean_asr(&emb, srate, p)?;
    let mut sum = vec![0.0; n];
    let mut cnt = vec![0.0; n];
    for j in 0..dim {
        for t in 0..m {
            sum[t + j * tau] += clean[j][t];
            cnt[t + j * tau] += 1.0;
        }
    }
    Ok((0..n).map(|i| sum[i] / cnt[i]).collect())
}

/// E-ASR applied independently to every channel.
pub fn easr(x: &Chans, srate: f64, dim: usize, tau: usize, p: &AsrParams) -> Result<Chans, String> {
    x.iter().map(|ch| easr_channel(ch, srate, dim, tau, p)).collect()
}

fn mode_asr(x: &Chans, srate: f64, p: &AsrParams, modes: Vec<Vec<Vec<f64>>>) -> Result<Chans, String> {
    // modes[ch][k] -> pseudo channel ch*K + k
    let kk = modes[0].len();
    let pseudo: Chans = modes.iter().flat_map(|m| m.iter().cloned()).collect();
    let (clean, _) = clean_asr(&pseudo, srate, p)?;
    let n = x[0].len();
    Ok((0..x.len()).map(|ch| (0..n).map(|t| (0..kk).map(|k| clean[ch * kk + k][t]).sum()).collect()).collect())
}

/// VMD-ASR: every channel is split into `vmd.k` modes; the modes are the ASR channels; the repaired modes are summed.
pub fn vmd_asr(x: &Chans, srate: f64, v: &VmdOpts, p: &AsrParams) -> Result<Chans, String> {
    let modes: Vec<Vec<Vec<f64>>> = x.iter().map(|ch| vmd(ch, srate, v).0).collect();
    mode_asr(x, srate, p, modes)
}

/// EMD-ASR: first `k-1` IMFs of each channel plus the remainder (all later IMFs + residual) as the last pseudo-channel.
pub fn emd_asr(x: &Chans, srate: f64, k: usize, p: &AsrParams) -> Result<Chans, String> {
    let dec: Vec<(Vec<Vec<f64>>, Vec<f64>)> = x.iter().map(|ch| emd(ch, 12, 0.2, 50)).collect();
    let kmin = dec.iter().map(|d| d.0.len() + 1).min().unwrap().min(k);
    if kmin < 2 {
        return Err("emd_asr: signal has too few IMFs".into());
    }
    let n = x[0].len();
    let modes = dec
        .iter()
        .map(|(imfs, res)| {
            let mut m: Vec<Vec<f64>> = imfs.iter().take(kmin - 1).cloned().collect();
            let mut rest = res.clone();
            for im in imfs.iter().skip(kmin - 1) {
                for i in 0..n {
                    rest[i] += im[i];
                }
            }
            m.push(rest);
            m
        })
        .collect();
    mode_asr(x, srate, p, modes)
}

// ------------------------------------------------------------------------------------------------------------
// wICA
// ------------------------------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct WicaOpts {
    pub levels: usize,
    pub threshold_mult: f64,
    pub seed: u32,
}
impl Default for WicaOpts {
    fn default() -> Self {
        WicaOpts { levels: 5, threshold_mult: 1.0, seed: 1 }
    }
}

/// HAPPE wICA given an unmixing matrix `w` (components x channels): `IC = W·X`; each IC is wavelet-denoised
/// (`wica_denoise_ic`), artefacts are `A·wIC` with `A = W⁻¹`, and `clean = X − A·wIC`.
pub fn wica_with_unmixing(x: &Chans, w: &Mat, o: &WicaOpts) -> Result<Chans, String> {
    let m = to_mat(x);
    let a = w.clone().try_inverse().ok_or("wICA: unmixing matrix is singular")?;
    let ic = w * &m;
    let mut wic: Mat = DMatrix::zeros(ic.nrows(), ic.ncols());
    for i in 0..ic.nrows() {
        let row: Vec<f64> = ic.row(i).iter().cloned().collect();
        let r = crate::decomp::wica_denoise_ic(&row, o.levels, o.threshold_mult);
        for (j, v) in r.iter().enumerate() {
            wic[(i, j)] = *v;
        }
    }
    Ok(to_chans(&(&m - a * wic)))
}

/// Wavelet-enhanced ICA as in HAPPE's `wICA.m` (Sorokin 2015 / Castellanos & Makarov 2006): extended-Infomax runica,
/// SWT (coif5, 5 levels) soft-thresholding of every component, re-mix, subtract from the data.
pub fn wica(x: &Chans, o: &WicaOpts) -> Result<Chans, String> {
    let m = to_mat(x);
    let mut rng = crate::rng::NativeRng::new(o.seed);
    let mut ro = crate::runica::RunicaOpts::default();
    ro.extended = 1;
    let ic = crate::pop_runica::pop_runica(&m, None, &ro, &mut rng)?;
    let w = &ic.icaweights * &ic.icasphere;
    wica_with_unmixing(x, &w, o)
}

// ------------------------------------------------------------------------------------------------------------
// Juggler-style calibration sample selection (DBSCAN / GEV) + ASR
// ------------------------------------------------------------------------------------------------------------

/// Mode estimate identical to `mne_denoise.asr.juggler._histogram_mode`: numpy `histogram(bins="fd")`, centre of the
/// fullest bin.
fn histogram_mode(x: &[f64]) -> f64 {
    let mut v: Vec<f64> = x.iter().cloned().filter(|a| a.is_finite()).collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    let pct = |p: f64| -> f64 {
        let pos = (n - 1) as f64 * p;
        let lo = pos.floor() as usize;
        let hi = (lo + 1).min(n - 1);
        v[lo] + (v[hi] - v[lo]) * (pos - lo as f64)
    };
    let (mn, mx) = (v[0], v[n - 1]);
    if mx - mn <= f64::EPSILON * mx.abs().max(mn.abs()).max(f64::MIN_POSITIVE) {
        return v[0];
    }
    let iqr = pct(0.75) - pct(0.25);
    let width = 2.0 * iqr / (n as f64).cbrt();
    let nb = if width > 0.0 { (((mx - mn) / width).ceil() as usize).max(1) } else { ((n as f64).log2().ceil() as usize + 1).max(1) };
    let step = (mx - mn) / nb as f64;
    let mut h = vec![0usize; nb];
    for &a in &v {
        h[(((a - mn) / step) as usize).min(nb - 1)] += 1;
    }
    let mut ib = 0;
    for (i, &c) in h.iter().enumerate() {
        if c > h[ib] {
            ib = i;
        }
    }
    mn + (ib as f64 + 0.5) * step
}

/// Exact DBSCAN, Chebyshev metric, grid-accelerated. Returns labels (-1 = noise).
pub fn dbscan_chebyshev(pts: &[Vec<f64>], eps: f64, min_samples: usize) -> Vec<i64> {
    use std::collections::HashMap;
    let n = pts.len();
    let d = pts[0].len();
    let key = |p: &Vec<f64>| -> Vec<i64> { p.iter().map(|v| (v / eps).floor() as i64).collect() };
    let mut grid: HashMap<Vec<i64>, Vec<usize>> = HashMap::new();
    for (i, p) in pts.iter().enumerate() {
        grid.entry(key(p)).or_default().push(i);
    }
    let neighbours = |i: usize| -> Vec<usize> {
        let k0 = key(&pts[i]);
        let mut out = vec![];
        let mut off = vec![-1i64; d];
        loop {
            let kk: Vec<i64> = k0.iter().zip(off.iter()).map(|(a, b)| a + b).collect();
            if let Some(v) = grid.get(&kk) {
                for &j in v {
                    if (0..d).all(|c| (pts[i][c] - pts[j][c]).abs() <= eps) {
                        out.push(j);
                    }
                }
            }
            let mut c = 0;
            while c < d {
                off[c] += 1;
                if off[c] <= 1 {
                    break;
                }
                off[c] = -1;
                c += 1;
            }
            if c == d {
                break;
            }
        }
        out
    };
    let mut labels = vec![-2i64; n]; // -2 unvisited
    let mut cl = 0i64;
    for i in 0..n {
        if labels[i] != -2 {
            continue;
        }
        let nb = neighbours(i);
        if nb.len() < min_samples {
            labels[i] = -1;
            continue;
        }
        labels[i] = cl;
        let mut stack = nb;
        while let Some(j) = stack.pop() {
            if labels[j] == -1 {
                labels[j] = cl;
            }
            if labels[j] != -2 {
                continue;
            }
            labels[j] = cl;
            let nj = neighbours(j);
            if nj.len() >= min_samples {
                stack.extend(nj);
            }
        }
        cl += 1;
    }
    labels
}

/// Generalised extreme value MLE (MATLAB parameterisation: k shape, sigma scale, mu location) by Nelder-Mead from
/// method-of-moments (Gumbel) start values.
pub fn gev_fit(x: &[f64]) -> (f64, f64, f64) {
    let n = x.len() as f64;
    let mean = x.iter().sum::<f64>() / n;
    let sd = (x.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0)).sqrt();
    let sigma0 = sd * 6f64.sqrt() / std::f64::consts::PI;
    let mu0 = mean - 0.5772156649 * sigma0;
    let nll = |p: &[f64]| -> f64 {
        let (k, ls, mu) = (p[0], p[1], p[2]);
        let sigma = ls.exp();
        let mut l = 0.0;
        for &v in x {
            let z = (v - mu) / sigma;
            if k.abs() < 1e-8 {
                l += ls + z + (-z).exp();
            } else {
                let t = 1.0 + k * z;
                if t <= 0.0 {
                    return 1e300;
                }
                l += ls + (1.0 + 1.0 / k) * t.ln() + t.powf(-1.0 / k);
            }
        }
        l
    };
    let start = [0.0, sigma0.ln(), mu0];
    let mut simplex: Vec<[f64; 3]> = vec![start, [0.1, start[1], start[2]], [0.0, start[1] + 0.2, start[2]], [0.0, start[1], start[2] + 0.2 * sigma0]];
    let mut fv: Vec<f64> = simplex.iter().map(|p| nll(p)).collect();
    for _ in 0..2000 {
        let mut idx: Vec<usize> = (0..4).collect();
        idx.sort_by(|&a, &b| fv[a].partial_cmp(&fv[b]).unwrap());
        simplex = idx.iter().map(|&i| simplex[i]).collect();
        fv = idx.iter().map(|&i| fv[i]).collect();
        if (fv[3] - fv[0]).abs() < 1e-10 * (1.0 + fv[0].abs()) {
            break;
        }
        let cen: Vec<f64> = (0..3).map(|c| (0..3).map(|i| simplex[i][c]).sum::<f64>() / 3.0).collect();
        let pt = |t: f64| -> [f64; 3] { [cen[0] + t * (simplex[3][0] - cen[0]), cen[1] + t * (simplex[3][1] - cen[1]), cen[2] + t * (simplex[3][2] - cen[2])] };
        let xr = pt(-1.0);
        let fr = nll(&xr);
        if fr < fv[0] {
            let xe = pt(-2.0);
            let fe = nll(&xe);
            if fe < fr { simplex[3] = xe; fv[3] = fe; } else { simplex[3] = xr; fv[3] = fr; }
        } else if fr < fv[2] {
            simplex[3] = xr;
            fv[3] = fr;
        } else {
            let xc = if fr < fv[3] { pt(-0.5) } else { pt(0.5) };
            let fc = nll(&xc);
            if fc < fv[3].min(fr) {
                simplex[3] = xc;
                fv[3] = fc;
            } else {
                for i in 1..4 {
                    for c in 0..3 {
                        simplex[i][c] = simplex[0][c] + 0.5 * (simplex[i][c] - simplex[0][c]);
                    }
                    fv[i] = nll(&simplex[i]);
                }
            }
        }
    }
    let b = simplex[0];
    (b[0], b[1].exp(), b[2])
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Juggler {
    Dbscan,
    Gev,
}

pub struct JugglerSelection {
    pub mask: Vec<bool>,
    pub detail: String,
}

/// Selection of clean calibration samples (mne-denoise `select_juggler_reference_samples`, `selection_filter_kind='asr'`).
pub fn juggler_select(x: &Chans, srate: f64, strategy: Juggler, top_k: usize) -> Result<JugglerSelection, String> {
    let c = x.len();
    let n = x[0].len();
    let (b, a) = default_spectral_filter(srate)?;
    let filt: Chans = x.iter().map(|ch| crate::yulewalk::filter(&b, &a, ch, None).0).collect();
    let k = top_k.min(c);
    let feats: Vec<Vec<f64>> = (0..n)
        .map(|t| {
            let mut v: Vec<f64> = (0..c).map(|ch| filt[ch][t].abs()).collect();
            v.sort_by(|p, q| q.partial_cmp(p).unwrap());
            v.truncate(k);
            v
        })
        .collect();
    let mask: Vec<bool>;
    let detail;
    match strategy {
        Juggler::Dbscan => {
            let scale: Vec<f64> = feats.iter().map(|f| f.iter().map(|v| v * v).sum::<f64>().sqrt()).collect();
            let mode = histogram_mode(&scale);
            let eps = mode / 10.0;
            let est_clean = scale.iter().filter(|&&v| v <= mode).count();
            let min_samples = ((0.10 * est_clean.max(1) as f64).ceil() as usize).clamp(2, n);
            let labels = dbscan_chebyshev(&feats, eps, min_samples);
            let ncl = labels.iter().cloned().max().unwrap_or(-1) + 1;
            if ncl <= 0 {
                return Err("juggler dbscan: no cluster found".into());
            }
            let mut best: Option<(f64, usize, i64)> = None;
            for l in 0..ncl {
                let mut norms: Vec<f64> = (0..n).filter(|&i| labels[i] == l).map(|i| feats[i].iter().cloned().fold(0.0, f64::max)).collect();
                norms.sort_by(|p, q| p.partial_cmp(q).unwrap());
                let med = if norms.len() % 2 == 1 { norms[norms.len() / 2] } else { 0.5 * (norms[norms.len() / 2 - 1] + norms[norms.len() / 2]) };
                let better = match best {
                    None => true,
                    Some((m, sz, _)) => med < m || (med == m && norms.len() > sz),
                };
                if better {
                    best = Some((med, norms.len(), l));
                }
            }
            let sel = best.unwrap().2;
            mask = labels.iter().map(|&l| l == sel).collect();
            detail = format!("dbscan eps={eps:.4} min_samples={min_samples} clusters={ncl}");
        }
        Juggler::Gev => {
            let lead: Vec<f64> = feats.iter().map(|f| f[0]).collect();
            let mut s = lead.clone();
            s.sort_by(|p, q| p.partial_cmp(q).unwrap());
            let scale = if n % 2 == 1 { s[n / 2] } else { 0.5 * (s[n / 2 - 1] + s[n / 2]) };
            if !(scale > 0.0) {
                return Err("juggler gev: degenerate amplitude scale".into());
            }
            let norm: Vec<f64> = lead.iter().map(|v| v / scale).collect();
            let (k, sigma, mu) = gev_fit(&norm);
            let mode = if k.abs() < 1e-10 { mu } else { mu + sigma * ((1.0 + k).powf(-k) - 1.0) / k };
            mask = norm.iter().map(|&v| v <= mode).collect();
            detail = format!("gev k={k:.4} sigma={sigma:.4} mu={mu:.4} mode={mode:.4}");
        }
    }
    let kept = mask.iter().filter(|&&m| m).count();
    if kept < ((0.05 * n as f64).floor() as usize).max(1) {
        return Err(format!("juggler: only {kept} reference samples kept"));
    }
    Ok(JugglerSelection { mask, detail })
}

/// ASR whose calibration data is chosen by DBSCAN/GEV sample selection instead of `clean_windows`.
pub fn juggler_asr(x: &Chans, srate: f64, strategy: Juggler, top_k: usize, p: &AsrParams) -> Result<(Chans, JugglerSelection), String> {
    let sel = juggler_select(x, srate, strategy, top_k)?;
    let reference: Chans = x.iter().map(|ch| ch.iter().zip(sel.mask.iter()).filter(|(_, &m)| m).map(|(v, _)| *v).collect()).collect();
    let c = x.len();
    let s = x[0].len();
    let windowlen = p.window_len.unwrap_or_else(|| 0.5f64.max(1.5 * c as f64 / srate));
    let mut state = asr_calibrate(&reference, srate, p.cutoff, None, 0.5, 0.66, 0.1, 0.25, p.max_mem)?;
    let stepsize = p.step_size.unwrap_or_else(|| (srate * windowlen / 2.0).floor() as usize);
    let ext = (windowlen / 2.0 * srate).round() as usize;
    let sig = pad_end(x, ext);
    let out = asr_process(&sig, srate, &mut state, Some(windowlen), Some(windowlen / 2.0), Some(stepsize), p.max_dims, p.max_mem)?;
    let carry_len = state.carry.as_ref().map(|c| c[0].len()).unwrap_or(0);
    let cleaned: Chans = out.into_iter().map(|ch| ch[carry_len..carry_len + s].to_vec()).collect();
    Ok((cleaned, sel))
}
