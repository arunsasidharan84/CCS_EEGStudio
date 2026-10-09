//! Peak and Pulse detection engine for PPG and ECG signals.
//!
//! Reuses the exact filters and peak finders from `Orbit_Algorithm` (`orbit_features`),
//! plus adaptive R-wave detection for ECG signals.

use std::cmp::Ordering;

const PPG_B: [f64; 5] = [
    0.1339135322039675,
    0.0,
    -0.267827064407935,
    0.0,
    0.1339135322039675,
];
const PPG_A: [f64; 5] = [
    1.0,
    -2.657892213754038,
    2.625220424817165,
    -1.2338800089551802,
    0.2694988533448083,
];

const SAVGOL15: [f64; 15] = [
    -0.07058823529411765,
    -0.011764705882352941,
    0.038009049773755656,
    0.07873303167420814,
    0.11040723981900453,
    0.1330316742081448,
    0.14660633484162897,
    0.15113122171945702,
    0.14660633484162897,
    0.1330316742081448,
    0.11040723981900453,
    0.07873303167420814,
    0.038009049773755656,
    -0.011764705882352941,
    -0.07058823529411765,
];

pub fn demean(signal: &[f64]) -> Vec<f64> {
    if signal.is_empty() {
        return Vec::new();
    }
    let m = signal.iter().sum::<f64>() / signal.len() as f64;
    signal.iter().map(|&v| v - m).collect()
}

pub fn stddev(signal: &[f64]) -> f64 {
    if signal.len() < 2 {
        return 0.0;
    }
    let m = signal.iter().sum::<f64>() / signal.len() as f64;
    let var = signal.iter().map(|&v| (v - m).powi(2)).sum::<f64>() / (signal.len() - 1) as f64;
    var.sqrt()
}

pub fn median_filter3(signal: &[f64]) -> Vec<f64> {
    if signal.len() < 3 {
        return signal.to_vec();
    }
    let mut out = Vec::with_capacity(signal.len());
    out.push(signal[0]);
    for i in 1..signal.len() - 1 {
        let mut window = [signal[i - 1], signal[i], signal[i + 1]];
        window.sort_by(|a, b| a.partial_cmp(b).unwrap_or(Ordering::Equal));
        out.push(window[1]);
    }
    out.push(*signal.last().unwrap());
    out
}

pub fn filt_filt(x: &[f64], b: &[f64], a: &[f64]) -> Vec<f64> {
    if x.is_empty() {
        return Vec::new();
    }
    let y = lfilter(x, b, a);
    let mut y_rev = y;
    y_rev.reverse();
    let y2 = lfilter(&y_rev, b, a);
    let mut out = y2;
    out.reverse();
    out
}

fn lfilter(x: &[f64], b: &[f64], a: &[f64]) -> Vec<f64> {
    let n = x.len();
    let mut y = vec![0.0; n];
    for i in 0..n {
        let mut sum_b = 0.0;
        for (j, &b_val) in b.iter().enumerate() {
            if i >= j {
                sum_b += b_val * x[i - j];
            }
        }
        let mut sum_a = 0.0;
        for (j, &a_val) in a.iter().enumerate().skip(1) {
            if i >= j {
                sum_a += a_val * y[i - j];
            }
        }
        y[i] = (sum_b - sum_a) / a[0];
    }
    y
}

pub fn savgol15(v: &[f64]) -> Vec<f64> {
    if v.len() < 15 {
        return v.to_vec();
    }
    let radius = 7;
    let mut out = vec![0.0; v.len()];
    for i in 0..v.len() {
        let mut sum = 0.0;
        for (k, &c) in SAVGOL15.iter().enumerate() {
            let offset = (i as isize) + (k as isize) - radius;
            let idx = offset.clamp(0, (v.len() - 1) as isize) as usize;
            sum += c * v[idx];
        }
        out[i] = sum;
    }
    out
}

pub fn find_peaks(x: &[f64], min_distance: usize, prominence: f64) -> Vec<usize> {
    let mut candidates = Vec::new();
    for i in 1..x.len().saturating_sub(1) {
        if x[i] > x[i - 1] && x[i] >= x[i + 1] {
            let prom = peak_prominence(x, i);
            if prom >= prominence {
                candidates.push((i, x[i]));
            }
        }
    }
    candidates.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal));
    keep_peaks(candidates, min_distance)
}

pub fn find_peaks_height(x: &[f64], min_distance: usize, min_height: f64) -> Vec<usize> {
    let mut candidates = Vec::new();
    for i in 1..x.len().saturating_sub(1) {
        if x[i] > min_height && x[i] > x[i - 1] && x[i] >= x[i + 1] {
            candidates.push((i, x[i]));
        }
    }
    candidates.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal));
    keep_peaks(candidates, min_distance)
}

pub fn find_peaks_dual_polarity(ppg: &[f64], fs: f64) -> Vec<usize> {
    let sd = stddev(ppg);
    if sd <= 0.0 {
        return Vec::new();
    }
    let min_distance = (fs * 0.4).round() as usize;
    let pos = find_peaks(ppg, min_distance, 0.1 * sd);
    let neg_signal = ppg.iter().map(|v| -v).collect::<Vec<_>>();
    let neg = find_peaks(&neg_signal, min_distance, 0.1 * sd);
    if neg.len() > pos.len() && neg.len() >= 4 {
        neg
    } else {
        pos
    }
}

fn keep_peaks(candidates: Vec<(usize, f64)>, min_distance: usize) -> Vec<usize> {
    let mut kept: Vec<usize> = Vec::new();
    for (idx, _) in candidates {
        if kept.iter().all(|k| k.abs_diff(idx) >= min_distance) {
            kept.push(idx);
        }
    }
    kept.sort();
    kept
}

fn peak_prominence(x: &[f64], peak: usize) -> f64 {
    let mut left_min = x[peak];
    for i in (0..=peak).rev() {
        if x[i] > x[peak] {
            break;
        }
        if x[i] < left_min {
            left_min = x[i];
        }
    }
    let mut right_min = x[peak];
    for i in peak..x.len() {
        if x[i] > x[peak] {
            break;
        }
        if x[i] < right_min {
            right_min = x[i];
        }
    }
    x[peak] - left_min.max(right_min)
}

/// Detect PPG peaks using `Orbit_Algorithm` preprocessing and dual polarity check.
pub fn detect_ppg_peaks(ppg: &[f64], fs: f64) -> Vec<usize> {
    if ppg.len() < (fs * 4.0) as usize {
        return Vec::new();
    }
    let mcorr = demean(ppg);
    let med = median_filter3(&mcorr);
    let bpf = filt_filt(&med, &PPG_B, &PPG_A);
    let smooth = savgol15(&bpf);
    let mut peaks = find_peaks_dual_polarity(&smooth, fs);
    if peaks.len() < 4 {
        peaks = find_peaks_height(&smooth, (fs * 0.4).round() as usize, 0.0);
    }
    peaks
}

/// Detect ECG R-peaks using adaptive prominence thresholding and derivative energy.
pub fn detect_ecg_peaks(ecg: &[f64], fs: f64) -> Vec<usize> {
    if ecg.len() < (fs * 4.0) as usize {
        return Vec::new();
    }
    // Derivative energy
    let mut diff = vec![0.0; ecg.len()];
    for i in 1..ecg.len() {
        diff[i] = (ecg[i] - ecg[i - 1]).powi(2);
    }
    let smooth_diff = savgol15(&diff);
    let sd = stddev(&smooth_diff);
    let min_distance = (fs * 0.35).round() as usize; // ~280 bpm max for R-peaks
    let peaks = find_peaks(&smooth_diff, min_distance, 0.2 * sd);
    // Map derivative peaks back to exact R-wave maxima on the original ecg signal
    let search_rad = (fs * 0.05).round() as usize;
    let mut refined = Vec::with_capacity(peaks.len());
    for &p in &peaks {
        let start = p.saturating_sub(search_rad);
        let end = (p + search_rad).min(ecg.len() - 1);
        let mut max_idx = start;
        let mut max_val = ecg[start];
        for i in start..=end {
            if ecg[i] > max_val {
                max_val = ecg[i];
                max_idx = i;
            }
        }
        if refined
            .last()
            .map_or(true, |&last| max_idx.abs_diff(last) >= min_distance)
        {
            refined.push(max_idx);
        }
    }
    refined
}
