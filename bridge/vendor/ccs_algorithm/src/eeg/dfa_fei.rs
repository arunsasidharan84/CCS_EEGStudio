//! Detrended Fluctuation Analysis (DFA) and fE/I (functional
//! Excitation/Inhibition ratio) for band-limited neuronal amplitude
//! envelopes.
//!
//! A faithful Rust port of `ccstools/dfa_fei.py` (itself a from-scratch
//! re-implementation of the methodology in Hardstone et al. 2012 and
//! Bruining/Hardstone et al. 2020, following the `crosci` package).
//! Verified to match the Python implementation to ~1e-14 absolute
//! difference on real/synthetic signals across all seven standard bands
//! (see `ccs_eegstudio_rust_python_feature_parity.md`, DFA/fE:I round).
//!
//! Operates on a single channel at a time (`&[f64]`), matching the
//! per-channel idiom already used by `nonlinear::all` /
//! `features::bandpowers` / `features::acw50` elsewhere in this crate;
//! multi-channel iteration is the caller's responsibility.
//!
//! Designed to work on windows/epochs of ANY length from ~2s up to the
//! crosci literature default (fit intervals up to 30s): the DFA fit
//! interval, the edge trim, and the fE/I window are all clamped down to
//! what the input can actually support, instead of asserting/crashing on
//! short input. A band whose literature-minimum fit window genuinely
//! cannot fit (e.g. Delta needs >=5s per side) comes back as NaN -- a
//! correct, expected result for that window length, not a bug.
//!
//! References: Hardstone, R. et al. (2012), Frontiers in Physiology, 3,
//! 450. Bruining, H.*, Hardstone, R.*, Juarez-Martinez, E.L.* et al.
//! (2020), Scientific Reports, 10, 9195. Note that commercial use of the
//! fE/I metric is stated by the original authors to be covered by patent
//! claim PCT/NL2019/050167 ("method of determining brain activity"),
//! priority date 16 March 2018; this module is for academic/research use.

use rustfft::num_complex::Complex64;
use rustfft::FftPlanner;
use statrs::distribution::{ContinuousCDF, StudentsT};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------
// FIR band-pass filter design, matching `mne.filter.filter_data` with
// filter_length='auto', l/h_trans_bandwidth='auto', fir_window='hamming',
// fir_design='firwin', phase='zero', pad='reflect_limited'.
// ---------------------------------------------------------------------

fn sinc(x: f64) -> f64 {
    if x == 0.0 {
        1.0
    } else {
        (std::f64::consts::PI * x).sin() / (std::f64::consts::PI * x)
    }
}

/// `scipy.signal.firwin(numtaps, cutoff, window='hamming', pass_zero=True,
/// scale=True, fs=2.0)` -- a single-cutoff lowpass, `cutoff` already
/// normalized so that 1.0 == Nyquist.
fn firwin_lowpass(numtaps: usize, cutoff: f64) -> Vec<f64> {
    let n = numtaps;
    let alpha = 0.5 * (n as f64 - 1.0);
    let mut h = vec![0.0; n];
    for i in 0..n {
        let m = i as f64 - alpha;
        let hamming =
            0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / (n as f64 - 1.0)).cos();
        h[i] = cutoff * sinc(cutoff * m) * hamming;
    }
    let sum: f64 = h.iter().sum();
    for value in h.iter_mut() {
        *value /= sum;
    }
    h
}

/// Port of `mne.filter._firwin_design`: builds a band-pass FIR filter of
/// length `n` from a piecewise-constant 0/1 desired-gain curve specified
/// by `(freq, gain)` control points (freq normalized to `[0, 1]`, `1.0`
/// == Nyquist; `freq[0]` must be 0).
fn firwin_design(n: usize, freq: &[f64], gain: &[f64]) -> Vec<f64> {
    let mut h = vec![0.0; n];
    let mut prev_freq = *freq.last().unwrap();
    let mut prev_gain = *gain.last().unwrap();
    if prev_gain == 1.0 {
        h[n / 2] = 1.0;
    }
    for i in (0..freq.len() - 1).rev() {
        let this_freq = freq[i];
        let this_gain = gain[i];
        if this_gain != prev_gain {
            let transition = (prev_freq - this_freq) / 2.0;
            let mut this_n = (3.3 / transition).round() as i64;
            this_n += 1 - this_n.rem_euclid(2);
            let this_n = this_n as usize;
            let this_h = firwin_lowpass(this_n, (prev_freq + this_freq) / 2.0);
            let offset = (n - this_n) / 2;
            if this_gain == 0.0 {
                for (k, value) in this_h.iter().enumerate() {
                    h[offset + k] -= value;
                }
            } else {
                for (k, value) in this_h.iter().enumerate() {
                    h[offset + k] += value;
                }
            }
        }
        prev_gain = this_gain;
        prev_freq = this_freq;
    }
    h
}

/// Designs the zero-phase band-pass FIR filter MNE would build for
/// `filter_data(..., l_freq, h_freq, filter_length='auto', ...)`. Returns
/// the (odd-length) filter taps.
fn design_bandpass_filter(sfreq: f64, l_freq: f64, h_freq: f64) -> Vec<f64> {
    let l_trans = (0.25 * l_freq).max(2.0).min(l_freq);
    let h_trans = (0.25 * h_freq).max(2.0).min(sfreq / 2.0 - h_freq);
    let min_trans = l_trans.min(h_trans);
    let length_sec = 3.3 / min_trans;
    let mut n = (length_sec * sfreq).ceil() as i64;
    if n % 2 == 0 {
        n += 1;
    }
    let n = n as usize;

    let f_s1 = l_freq - l_trans;
    let f_p1 = l_freq;
    let f_p2 = h_freq;
    let f_s2 = h_freq + h_trans;

    let mut freq = vec![f_s1, f_p1, f_p2, f_s2];
    let mut gain = vec![0.0, 1.0, 1.0, 0.0];
    if f_s2 != sfreq / 2.0 {
        freq.push(sfreq / 2.0);
        gain.push(0.0);
    }
    if f_s1 != 0.0 {
        freq.insert(0, 0.0);
        gain.insert(0, 0.0);
    }
    let nyq = sfreq / 2.0;
    for value in freq.iter_mut() {
        *value /= nyq;
    }

    firwin_design(n, &freq, &gain)
}

/// Zero-phase FIR filtering with MNE's `pad='reflect_limited'` edge
/// handling: reflect each edge about the edge VALUE (not a plain mirror),
/// so there's no DC jump at the seam, then a convolution with the group
/// delay (`(len(h)-1)/2` samples, exact since `h` has odd, symmetric
/// length) removed.
fn filter_data(signal: &[f64], sfreq: f64, l_freq: f64, h_freq: f64) -> Vec<f64> {
    let h = design_bandpass_filter(sfreq, l_freq, h_freq);
    let n_h = h.len();
    let n_times = signal.len();
    let n_edge = (n_h.min(n_times)).saturating_sub(1);

    let mut x_ext = Vec::with_capacity(n_times + 2 * n_edge);
    if n_edge > 0 {
        for i in 0..n_edge {
            x_ext.push(2.0 * signal[0] - signal[n_edge - i]);
        }
    }
    x_ext.extend_from_slice(signal);
    if n_edge > 0 {
        let last = n_times - 1;
        for i in 0..n_edge {
            x_ext.push(2.0 * signal[last] - signal[n_times - 2 - i]);
        }
    }

    let full_conv = convolve_full(&x_ext, &h);
    let shift = (n_h - 1) / 2 + n_edge;
    full_conv[shift..shift + n_times].to_vec()
}

fn convolve_full(x: &[f64], h: &[f64]) -> Vec<f64> {
    let n = x.len();
    let m = h.len();
    let out_len = n + m - 1;
    // FFT-based convolution (exact up to floating-point rounding, same
    // result as direct convolution) -- matters for speed since Delta-band
    // filters can be >1000 taps.
    let fft_len = out_len.next_power_of_two();
    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(fft_len);
    let ifft = planner.plan_fft_inverse(fft_len);

    let mut xb: Vec<Complex64> = x.iter().map(|&v| Complex64::new(v, 0.0)).collect();
    xb.resize(fft_len, Complex64::new(0.0, 0.0));
    let mut hb: Vec<Complex64> = h.iter().map(|&v| Complex64::new(v, 0.0)).collect();
    hb.resize(fft_len, Complex64::new(0.0, 0.0));

    fft.process(&mut xb);
    fft.process(&mut hb);
    for i in 0..fft_len {
        xb[i] *= hb[i];
    }
    ifft.process(&mut xb);
    let scale = 1.0 / fft_len as f64;
    xb[..out_len].iter().map(|c| c.re * scale).collect()
}

// ---------------------------------------------------------------------
// Hilbert amplitude envelope.
// ---------------------------------------------------------------------

/// `np.abs(scipy.signal.hilbert(x, N=n_fft))[:len(x)]` for a real 1-D
/// signal. `n_fft` is always a power of two (hence even) here.
fn hilbert_envelope(signal: &[f64], n_fft: usize) -> Vec<f64> {
    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(n_fft);
    let ifft = planner.plan_fft_inverse(n_fft);

    let mut buf: Vec<Complex64> = signal.iter().map(|&v| Complex64::new(v, 0.0)).collect();
    buf.resize(n_fft, Complex64::new(0.0, 0.0));
    fft.process(&mut buf);

    // Analytic-signal multiplier: h[0]=1, h[n_fft/2]=1, h[1..n_fft/2]=2, rest 0.
    for value in buf.iter_mut().take(n_fft / 2).skip(1) {
        *value *= 2.0;
    }
    for value in buf.iter_mut().skip(n_fft / 2 + 1) {
        *value *= 0.0;
    }

    ifft.process(&mut buf);
    let scale = 1.0 / n_fft as f64;
    buf[..signal.len()]
        .iter()
        .map(|c| (c * scale).norm())
        .collect()
}

/// Zero-phase FIR band-pass filter (matching MNE's defaults) + Hilbert
/// amplitude envelope, with `edge_trim_sec` trimmed from each end after
/// filtering to remove FIR edge artifacts.
fn band_amplitude_envelope(
    signal: &[f64],
    srate: f64,
    band: (f64, f64),
    edge_trim_sec: f64,
) -> Vec<f64> {
    let filtered = filter_data(signal, srate, band.0, band.1);
    let trim = (edge_trim_sec * srate) as usize;
    let trimmed: &[f64] = if trim > 0 && filtered.len() > 2 * trim {
        &filtered[trim..filtered.len() - trim]
    } else {
        &filtered[..]
    };
    let n_fft = (trimmed.len().max(1)).next_power_of_two();
    hilbert_envelope(trimmed, n_fft)
}

// ---------------------------------------------------------------------
// Windowing helper (`_create_window_indices`).
// ---------------------------------------------------------------------

/// Start offsets of fixed-length (possibly overlapping) windows of
/// `length_window` samples, spaced `window_offset` samples apart, inside
/// `length_signal` samples -- matching
/// `np.arange(0, length_signal - length_window, window_offset)` (note:
/// EXCLUSIVE stop, so a window that fits exactly once with no room for a
/// second start -- `length_signal == length_window` -- yields zero
/// windows here, matching Python/NumPy's behaviour exactly, including the
/// resulting "mean of empty slice" NaN that propagates from it).
fn window_starts(length_signal: usize, length_window: usize, window_offset: usize) -> Vec<usize> {
    if length_window >= length_signal {
        return Vec::new();
    }
    let span = (length_signal - length_window) as f64;
    let count = (span / window_offset as f64).ceil() as usize;
    (0..count).map(|i| i * window_offset).collect()
}

// ---------------------------------------------------------------------
// DFA
// ---------------------------------------------------------------------

/// Simple OLS linear fit `y = slope*x + intercept`, returning
/// `(slope, intercept, residual_sum_of_squares)`. Matches
/// `numpy.polyfit(x, y, deg=1, full=True)` to floating-point precision
/// for well-conditioned (non-degenerate) inputs -- which is always the
/// case here (window sizes are always well above the degree-1 minimum of
/// 2 points).
fn ols_fit(x: &[f64], y: &[f64]) -> (f64, f64, f64) {
    let n = x.len() as f64;
    let mean_x = x.iter().sum::<f64>() / n;
    let mean_y = y.iter().sum::<f64>() / n;
    let mut sxx = 0.0;
    let mut sxy = 0.0;
    for (&xi, &yi) in x.iter().zip(y) {
        sxx += (xi - mean_x) * (xi - mean_x);
        sxy += (xi - mean_x) * (yi - mean_y);
    }
    let slope = sxy / sxx;
    let intercept = mean_y - slope * mean_x;
    let rss = x
        .iter()
        .zip(y)
        .map(|(&xi, &yi)| {
            let resid = yi - (slope * xi + intercept);
            resid * resid
        })
        .sum::<f64>();
    (slope, intercept, rss)
}

/// Detrended Fluctuation Analysis of a (typically amplitude-envelope)
/// single-channel signal.
///
/// `fit_interval` / `compute_interval` are in seconds, with `fit_interval
/// subseteq compute_interval`. Returns the DFA (Hurst-like) exponent, or
/// NaN if the fit wasn't possible (too few window sizes in range, or the
/// requested `compute_interval`'s top window doesn't fit the signal at
/// all) -- both normal, expected outcomes for a short/clamped window, not
/// bugs; see module docs and `compute_band_biomarkers`, which is what
/// actually clamps these intervals to what a given signal length can
/// support.
fn dfa(
    signal: &[f64],
    srate: f64,
    fit_interval: (f64, f64),
    compute_interval: (f64, f64),
    overlap: bool,
    min_fit_points: usize,
) -> f64 {
    let length_signal = signal.len();

    // Log-spaced window sizes from 0.1s to 1000s (crosci convention),
    // restricted to compute_interval -- matches
    // `np.logspace(-1, 3, 81)` -> floor(*srate) -> sorted unique.
    let mut window_sizes: Vec<i64> = (0..81)
        .map(|i| {
            let exponent = -1.0 + i as f64 * 4.0 / 80.0;
            (10f64.powf(exponent) * srate).floor() as i64
        })
        .collect();
    window_sizes.sort_unstable();
    window_sizes.dedup();
    window_sizes.retain(|&w| {
        w as f64 >= compute_interval.0 * srate && w as f64 <= compute_interval.1 * srate
    });

    if window_sizes.is_empty() || *window_sizes.iter().max().unwrap() as usize > length_signal {
        return f64::NAN;
    }

    let first0 = match window_sizes
        .iter()
        .position(|&w| w as f64 >= fit_interval.0 * srate)
    {
        Some(idx) => idx,
        None => return f64::NAN,
    };
    let last = match window_sizes
        .iter()
        .rposition(|&w| w as f64 <= fit_interval.1 * srate)
    {
        Some(idx) => idx,
        None => return f64::NAN,
    };

    let mut first = first0;
    if first > 0 {
        let lower_candidate = window_sizes[first - 1] as f64 / srate;
        if (lower_candidate - fit_interval.0).abs() <= fit_interval.0 / 100.0 {
            let current = window_sizes[first] as f64 / srate;
            if (lower_candidate - fit_interval.0).abs() < (current - fit_interval.0).abs() {
                first -= 1;
            }
        }
    }

    if (last as i64 - first as i64 + 1) < min_fit_points as i64 {
        return f64::NAN;
    }

    let center = signal.iter().sum::<f64>() / length_signal as f64;
    let profile: Vec<f64> = signal
        .iter()
        .scan(0.0, |state, &value| {
            *state += value - center;
            Some(*state)
        })
        .collect();

    let overlap_frac = if overlap { 0.5 } else { 0.0 };
    let mut fluctuations = vec![f64::NAN; window_sizes.len()];
    for (wi, &window_size) in window_sizes.iter().enumerate() {
        let window_size = window_size as usize;
        let window_offset = (((window_size as f64) * (1.0 - overlap_frac)).floor() as usize).max(1);
        let starts = window_starts(length_signal, window_size, window_offset);
        if starts.is_empty() {
            continue; // matches NumPy's "mean of empty slice" -> NaN
        }
        let x_axis: Vec<f64> = (0..window_size).map(|i| i as f64).collect();
        let mut det_fluc_sum = 0.0;
        for &start in &starts {
            let window = &profile[start..start + window_size];
            let (_, _, rss) = ols_fit(&x_axis, window);
            det_fluc_sum += (rss / window_size as f64).sqrt();
        }
        fluctuations[wi] = det_fluc_sum / starts.len() as f64;
    }

    let log_x: Vec<f64> = window_sizes[first..=last]
        .iter()
        .map(|&w| (w as f64).log10())
        .collect();
    let log_y: Vec<f64> = fluctuations[first..=last]
        .iter()
        .map(|&f| f.log10())
        .collect();
    let (slope, _intercept, _rss) = ols_fit(&log_x, &log_y);
    slope
}

// ---------------------------------------------------------------------
// Generalized ESD outlier test (ported from PyAstronomy's
// `generalizedESD`, MIT licensed, as vendored into `dfa_fei.py`).
// ---------------------------------------------------------------------

fn population_std(values: &[f64]) -> f64 {
    let n = values.len() as f64;
    let mean = values.iter().sum::<f64>() / n;
    (values.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / n).sqrt()
}

/// Returns `(n_outliers, outlier_indexes)`, matching
/// `generalized_esd(x, max_outliers, alpha, unbiased_var=False)`.
fn generalized_esd(x: &[f64], max_outliers: usize, alpha: f64) -> (usize, Vec<usize>) {
    let n = x.len();
    let mut removed = vec![false; n];
    let mut r = Vec::with_capacity(max_outliers + 1);
    let mut l = Vec::with_capacity(max_outliers);
    let mut candidate_idx = Vec::with_capacity(max_outliers + 1);

    for i in 0..=max_outliers {
        let active: Vec<usize> = (0..n).filter(|&k| !removed[k]).collect();
        let active_vals: Vec<f64> = active.iter().map(|&k| x[k]).collect();
        let mean = active_vals.iter().sum::<f64>() / active_vals.len() as f64;
        let std = population_std(&active_vals);
        let mut best_idx = active[0];
        let mut best_r = f64::NEG_INFINITY;
        for &k in &active {
            let rr = ((x[k] - mean) / std).abs();
            if rr > best_r {
                best_r = rr;
                best_idx = k;
            }
        }
        candidate_idx.push(best_idx);
        r.push(best_r);
        if i >= 1 {
            let p = 1.0 - alpha / (2.0 * (n - i + 1) as f64);
            let df = (n as i64 - i as i64 - 1) as f64;
            let t_dist = StudentsT::new(0.0, 1.0, df).unwrap();
            let perc_point = t_dist.inverse_cdf(p);
            let n_i = (n - i) as f64;
            let n_i1 = (n - i + 1) as f64;
            let lambda = n_i * perc_point / ((n_i - 1.0 + perc_point * perc_point) * n_i1).sqrt();
            l.push(lambda);
        }
        removed[best_idx] = true;
    }
    r.pop();

    let mut n_found = 0usize;
    for i in (0..max_outliers).rev() {
        if r[i] > l[i] {
            n_found = i + 1;
            break;
        }
    }
    let outlier_indexes = candidate_idx[..n_found].to_vec();
    (n_found, outlier_indexes)
}

fn pearson_corr(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len() as f64;
    let mean_a = a.iter().sum::<f64>() / n;
    let mean_b = b.iter().sum::<f64>() / n;
    let mut sab = 0.0;
    let mut saa = 0.0;
    let mut sbb = 0.0;
    for (&ai, &bi) in a.iter().zip(b) {
        sab += (ai - mean_a) * (bi - mean_b);
        saa += (ai - mean_a) * (ai - mean_a);
        sbb += (bi - mean_b) * (bi - mean_b);
    }
    sab / (saa.sqrt() * sbb.sqrt())
}

// ---------------------------------------------------------------------
// fE/I
// ---------------------------------------------------------------------

/// Functional Excitation/Inhibition ratio (Bruining/Hardstone et al.
/// 2020), with generalized-ESD outlier removal. Returns NaN if the DFA
/// value is at or below `dfa_threshold` (lack of long-range temporal
/// correlations, a precondition for fE/I to be meaningful), or if too few
/// window placements are available (`min_windows`) -- both graceful,
/// expected outcomes, not errors.
#[allow(clippy::too_many_arguments)]
fn fei(
    signal: &[f64],
    srate: f64,
    window_size_sec: f64,
    window_overlap: f64,
    dfa_value: f64,
    dfa_threshold: f64,
    min_windows: usize,
) -> f64 {
    if !dfa_value.is_finite() || dfa_value <= dfa_threshold { return f64::NAN; }
    let length_signal = signal.len();
    let window_size = (window_size_sec * srate) as i64;
    if window_size <= 0 {
        return f64::NAN;
    }
    let window_size = window_size as usize;
    let window_offset = ((window_size as f64) * (1.0 - window_overlap)).floor() as i64;
    if window_offset <= 0 || window_size >= length_signal {
        return f64::NAN;
    }
    let window_offset = window_offset as usize;

    let starts = window_starts(length_signal, window_size, window_offset);
    if starts.len() < min_windows {
        return f64::NAN;
    }

    let min_amp = signal.iter().cloned().fold(f64::INFINITY, f64::min);
    let max_amp = signal.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    if min_amp == max_amp {
        return f64::NAN;
    }

    let mean_amp = signal.iter().sum::<f64>() / length_signal as f64;
    let profile: Vec<f64> = signal
        .iter()
        .scan(0.0, |state, &value| {
            *state += value - mean_amp;
            Some(*state)
        })
        .collect();

    let x_axis: Vec<f64> = (0..window_size).map(|i| i as f64).collect();
    let mut w_amp = Vec::with_capacity(starts.len());
    let mut w_dnf = Vec::with_capacity(starts.len());
    for &start in &starts {
        let window_amp = &signal[start..start + window_size];
        let mean_window_amp = window_amp.iter().sum::<f64>() / window_size as f64;
        let window_profile = &profile[start..start + window_size];
        let normalized: Vec<f64> = window_profile
            .iter()
            .map(|&p| p / mean_window_amp)
            .collect();
        let (_, _, rss) = ols_fit(&x_axis, &normalized);
        w_amp.push(mean_window_amp);
        w_dnf.push((rss / window_size as f64).sqrt());
    }

    // NOTE on the comparison below: `ccstools` computes fei_outliers_removed
    // for every channel unconditionally, and only afterwards masks it to NaN
    // A missing DFA cannot establish the required long-range correlations.
    // Unlike the legacy NaN comparison loophole, reject it explicitly.
    let gesd_alpha = 0.05;
    let max_outlier_pct = 0.025;
    let max_n_outliers = ((max_outlier_pct * w_amp.len() as f64).round() as usize).max(2);
    let (_, out_amp) = generalized_esd(&w_amp, max_n_outliers, gesd_alpha);
    let (_, out_dnf) = generalized_esd(&w_dnf, max_n_outliers, gesd_alpha);
    let mut outlier_union: Vec<usize> = out_amp.into_iter().chain(out_dnf).collect();
    outlier_union.sort_unstable();
    outlier_union.dedup();

    let keep: Vec<usize> = (0..w_amp.len())
        .filter(|k| !outlier_union.contains(k))
        .collect();
    let kept_amp: Vec<f64> = keep.iter().map(|&k| w_amp[k]).collect();
    let kept_dnf: Vec<f64> = keep.iter().map(|&k| w_dnf[k]).collect();

    if !dfa_value.is_finite() || dfa_value <= dfa_threshold {
        f64::NAN
    } else {
        1.0 - pearson_corr(&kept_amp, &kept_dnf)
    }
}

// ---------------------------------------------------------------------
// Frequency-bin / fit-interval helpers.
// ---------------------------------------------------------------------

/// Frequency-dependent DFA fit interval, in seconds (Hardstone et al.
/// 2012). `max_fit_sec` is the literature/crosci default upper bound
/// (30s); `compute_band_biomarkers` lowers it at call time to whatever a
/// given window/epoch length can actually support, so a short window
/// still gets the best fit interval available rather than failing
/// outright.
fn dfa_fitting_interval(frequency_low_hz: f64, max_fit_sec: f64) -> (f64, f64) {
    const DEFAULT_LOWER_FITS: [f64; 16] = [
        5.0, 5.0, 5.0, 3.981, 3.162, 2.238, 1.412, 1.122, 0.794, 0.562, 0.398, 0.281, 0.141, 0.1,
        0.1, 0.1,
    ];
    // get_frequency_bins([1, 150]): [1.0] followed by 16 log-spaced edges
    // from 4 to 150 Hz.
    let n_bins_full = 16;
    let lo = 4.0_f64;
    let hi = 150.0_f64;
    let mut edges: Vec<f64> = (0..n_bins_full)
        .map(|i| {
            10f64.powf(
                lo.log10() + i as f64 * (hi.log10() - lo.log10()) / (n_bins_full as f64 - 1.0),
            )
        })
        .collect();
    edges.insert(0, 1.0);
    let idx_freq = edges
        .iter()
        .rposition(|&e| (e * 10000.0).round() / 10000.0 <= frequency_low_hz)
        .unwrap_or(0);
    (DEFAULT_LOWER_FITS[idx_freq], max_fit_sec)
}

/// Largest window (seconds) that still places `>= min_windows` windows of
/// that size (at the given overlap fraction) inside `usable_sec` of
/// signal. Returns 0 if not even once.
fn max_feasible_window_sec(usable_sec: f64, overlap_frac: f64, min_windows: usize) -> f64 {
    if usable_sec <= 0.0 || min_windows < 1 {
        return 0.0;
    }
    if min_windows == 1 {
        return usable_sec;
    }
    let mut step_frac = 1.0 - overlap_frac;
    if step_frac <= 0.0 {
        step_frac = 1e-6;
    }
    let denom = 1.0 + step_frac * (min_windows as f64 - 1.0);
    usable_sec / denom
}

// ---------------------------------------------------------------------
// Band-level orchestration (`compute_band_biomarkers`).
// ---------------------------------------------------------------------

pub struct BandBiomarkers {
    pub dfa: f64,
    pub fei: f64,
}

/// DFA (+ fE/I) for a single frequency band, on a single-channel window
/// of ANY length -- see module docs for the window-flexibility behaviour.
/// `min_fit_points`/`min_fei_windows` default to 4 in `ccstools`;
/// `fei_window_sec`/`fei_overlap` default to 5.0/0.8.
#[allow(clippy::too_many_arguments)]
pub fn compute_band_biomarkers(
    signal: &[f64],
    srate: f64,
    frequency_range: (f64, f64),
    overlap: bool,
    compute_fei: bool,
    fei_window_sec: f64,
    fei_overlap: f64,
    min_fit_points: usize,
    min_fei_windows: usize,
) -> BandBiomarkers {
    compute_band_biomarkers_mode(signal,srate,frequency_range,overlap,compute_fei,fei_window_sec,fei_overlap,min_fit_points,min_fei_windows,false)
}

#[allow(clippy::too_many_arguments)]
fn compute_band_biomarkers_mode(signal:&[f64],srate:f64,frequency_range:(f64,f64),overlap:bool,compute_fei:bool,fei_window_sec:f64,fei_overlap:f64,min_fit_points:usize,min_fei_windows:usize,short:bool)->BandBiomarkers {
    let n_times = signal.len();
    let available_sec = n_times as f64 / srate;
    let nan_out = BandBiomarkers {
        dfa: f64::NAN,
        fei: f64::NAN,
    };

    // Edge trim must leave a positive amount of usable signal; scale it
    // down (never up) for short windows, floored at a small, non-zero
    // value so very short windows still get some edge protection from
    // filter transients.
    let edge_trim_sec = (1.0_f64).min((0.1 * available_sec).max(0.05));
    let usable_sec = available_sec - 2.0 * edge_trim_sec;
    if usable_sec <= 0.0 {
        return nan_out;
    }

    let (standard_lower, upper_fit_default) = dfa_fitting_interval(frequency_range.0, 30.0);
    let lower_fit = if short { (1.0/frequency_range.0).max(0.1) } else { standard_lower };
    let max_upper = max_feasible_window_sec(usable_sec, if overlap { 0.5 } else { 0.0 }, 2);
    let upper_fit = upper_fit_default.min(max_upper);

    if upper_fit < lower_fit {
        // This band's literature-minimum fit window doesn't fit even once
        // in the usable signal at this window length -- not computable.
        return nan_out;
    }

    let compute_interval = (lower_fit, upper_fit);
    let fit_interval = compute_interval;

    let amp_env = band_amplitude_envelope(signal, srate, frequency_range, edge_trim_sec);

    let dfa_value = dfa(
        &amp_env,
        srate,
        fit_interval,
        compute_interval,
        overlap,
        min_fit_points,
    );

    if !compute_fei {
        return BandBiomarkers {
            dfa: dfa_value,
            fei: f64::NAN,
        };
    }

    // fE/I's own window must also fit inside the (already edge-trimmed)
    // amplitude envelope -- shorten it if necessary, same logic as above
    // but for fei()'s min_windows requirement.
    let amp_env_sec = amp_env.len() as f64 / srate;
    let max_fei_window = max_feasible_window_sec(amp_env_sec, fei_overlap, min_fei_windows);
    let eff_fei_window_sec = fei_window_sec.min(max_fei_window);
    let fei_value = if eff_fei_window_sec < 0.1 {
        f64::NAN
    } else {
        fei(
            &amp_env,
            srate,
            eff_fei_window_sec,
            fei_overlap,
            dfa_value,
            0.6,
            min_fei_windows,
        )
    };

    BandBiomarkers {
        dfa: dfa_value,
        fei: fei_value,
    }
}

/// DFA/fE:I for every `(low_hz, high_hz, label)` band in `bands`, on a
/// single channel, returning `{label}_DFA` / `{label}_fEI` keyed values
/// matching `ccstools.dfa_fei.compute_dfa_fei`'s column naming. Uses the
/// `ccstools` defaults: 50% overlapping DFA windows, a 5s/80%-overlap
/// fE:I window, `min_fit_points`/`min_fei_windows` = 4.
pub fn all(signal: &[f64], srate: f64, bands: &[(f64, f64, &str)]) -> BTreeMap<String, f64> {
    let mut out = BTreeMap::new();
    for &(lo, hi, name) in bands {
        let result = compute_band_biomarkers(signal, srate, (lo, hi), true, true, 5.0, 0.8, 4, 4);
        out.insert(format!("{name}_DFA"), result.dfa);
        out.insert(format!("{name}_fEI"), result.fei);
    }
    out
}

/// Exploratory short-scale fits for verification; not literature-scale LRTC.
pub fn all_short(signal:&[f64],srate:f64,bands:&[(f64,f64,&str)])->BTreeMap<String,f64> {
    let mut out=BTreeMap::new();
    for &(lo,hi,name) in bands {
        let result=compute_band_biomarkers_mode(signal,srate,(lo,hi),true,true,5.0,0.8,4,4,true);
        out.insert(format!("{name}_DFA"),result.dfa);
        out.insert(format!("{name}_fEI"),result.fei);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_bands() -> [(f64, f64, &'static str); 7] {
        [
            (1.0, 4.0, "Delta"),
            (4.0, 8.0, "Theta"),
            (6.0, 10.0, "ThetaAlpha"),
            (8.0, 12.0, "Alpha"),
            (12.0, 18.0, "Beta1"),
            (18.0, 30.0, "Beta2"),
            (30.0, 40.0, "Gamma1"),
        ]
    }

    fn synthetic_signal(n: usize, srate: f64) -> Vec<f64> {
        // Deterministic pseudo-random-walk + oscillatory mix, no RNG
        // dependency needed for a smoke test.
        let mut state = 0.0_f64;
        (0..n)
            .map(|i| {
                let t = i as f64 / srate;
                state += ((i as f64 * 12.9898).sin() * 43758.5453).fract() * 0.05;
                state + 0.5 * (2.0 * std::f64::consts::PI * 10.0 * t).sin()
            })
            .collect()
    }

    #[test]
    fn short_epoch_yields_graceful_nan_for_low_bands_valid_gamma() {
        let srate = 250.0;
        let signal = synthetic_signal((2.0 * srate) as usize, srate);
        let result = all(&signal, srate, &test_bands());
        // A 2s epoch cannot support Delta's >=5s literature fit window.
        assert!(result["Delta_DFA"].is_nan());
        // Gamma1's fit interval starts at 0.1s, well within a 2s epoch.
        assert!(!result["Gamma1_DFA"].is_nan());
    }

    #[test]
    fn long_epoch_yields_finite_values_for_every_band() {
        let srate = 250.0;
        let signal = synthetic_signal((30.0 * srate) as usize, srate);
        let result = all(&signal, srate, &test_bands());
        for &(_, _, name) in &test_bands() {
            let dfa_value = result[&format!("{name}_DFA")];
            assert!(
                dfa_value.is_finite(),
                "{name} DFA should be computable on a 30s epoch, got {dfa_value}"
            );
        }
    }

    #[test]
    fn no_crash_on_very_short_or_flat_signal() {
        let srate = 250.0;
        let flat = vec![1.0; 100];
        let _ = all(&flat, srate, &test_bands());
        let tiny = vec![0.1, 0.2, 0.3];
        let _ = all(&tiny, srate, &test_bands());
    }
}

#[cfg(test)]
mod validity_tests {
    use super::*;
    #[test]
    fn missing_dfa_cannot_qualify_fei() {
        let envelope: Vec<f64> = (0..1000).map(|i|2.0+(i as f64*0.11).sin()*0.5).collect();
        assert!(fei(&envelope,100.0,1.0,0.8,f64::NAN,0.6,4).is_nan());
    }
}

#[cfg(test)]
mod short_verification_tests {
    use super::*;
    #[test]
    fn short_alpha_fits_are_distinct_from_standard_lrtc() {
        let signal:Vec<f64>=(0..1000).map(|i|{
            let t=i as f64/500.0;
            (1.0+0.3*(2.0*std::f64::consts::PI*0.7*t).sin())*(2.0*std::f64::consts::PI*10.0*t).sin()
        }).collect();
        let bands=[(8.0,12.0,"Alpha")];
        assert!(all(&signal,500.0,&bands)["Alpha_DFA"].is_nan());
        assert!(all_short(&signal,500.0,&bands)["Alpha_DFA"].is_finite());
    }
}
