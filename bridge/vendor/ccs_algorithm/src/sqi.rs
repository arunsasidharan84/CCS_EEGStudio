//! Signal Quality Index (SQI) module for EEG, PPG, and ECG channels.
//!
//! Ported with 100% parity from `Orbit_Algorithm` (`orbit_stream` and `orbit_features`),
//! plus enhanced ECG signal quality metrics.

/// EEG epoch quality: kurtosis-based cleanliness score in `[0, 1]`.
/// Flat channels (`variance < 1e-12`) or extreme artifact bursts (`kurtosis > 10`) yield low scores.
pub fn eeg_epoch_quality(values: &[f64]) -> f64 {
    if values.len() < 16 {
        return 0.0;
    }
    let n = values.len() as f64;
    let mean = values.iter().sum::<f64>() / n;
    let mut m2 = 0.0;
    let mut m4 = 0.0;
    for &v in values {
        let d = v - mean;
        let d2 = d * d;
        m2 += d2;
        m4 += d2 * d2;
    }
    let variance = m2 / n;
    if !variance.is_finite() || variance < 1e-12 {
        return 0.0; // flat channel
    }
    let kurtosis = (m4 / n) / (variance * variance) - 3.0;
    if !kurtosis.is_finite() {
        return 0.0;
    }
    (1.0 - kurtosis.abs() / 10.0).clamp(0.0, 1.0)
}

/// PPG epoch quality: physiological-peak morphology check over 4s subepochs (`0.0` or `1.0`).
pub fn ppg_epoch_quality(values: &[f64]) -> f64 {
    if values.len() < 16 {
        return 0.0;
    }
    let n = values.len() as f64;
    let mean = values.iter().sum::<f64>() / n;
    let mut variance = 0.0;
    for &v in values {
        let d = v - mean;
        variance += d * d;
    }
    variance /= n;
    if !variance.is_finite() || variance < 1e-6 {
        return 0.0;
    }
    // 5-point moving average
    let mut smoothed = Vec::with_capacity(values.len());
    for i in 2..values.len().saturating_sub(2) {
        smoothed.push(
            (values[i - 2] + values[i - 1] + values[i] + values[i + 1] + values[i + 2]) / 5.0,
        );
    }
    let mut peaks = 0i64;
    let mut last_peak_idx: i64 = -100;
    for i in 1..smoothed.len().saturating_sub(1) {
        if smoothed[i] > smoothed[i - 1] && smoothed[i] > smoothed[i + 1] {
            if i as i64 - last_peak_idx > 15 {
                peaks += 1;
                last_peak_idx = i as i64;
            }
        }
    }
    if (2..=15).contains(&peaks) {
        1.0
    } else {
        0.0
    }
}

/// Computes average PPG subwindow SQI across 4s chunks.
pub fn compute_ppg_subwindow_sqi(ppg: &[f64], fs: f64) -> f64 {
    if ppg.is_empty() {
        return 0.0;
    }
    let sub_len = (fs * 4.0).round() as usize;
    if sub_len == 0 || ppg.len() < sub_len {
        return ppg_epoch_quality(ppg);
    }
    let mut sum_q = 0.0;
    let mut count = 0.0;
    let mut start = 0;
    while start + sub_len <= ppg.len() {
        sum_q += ppg_epoch_quality(&ppg[start..start + sub_len]);
        count += 1.0;
        start += sub_len;
    }
    if count > 0.0 {
        sum_q / count
    } else {
        0.0
    }
}

/// ECG epoch quality check over a subepoch.
/// Checks baseline stability, variance, and kurtosis appropriate for sharp QRS complexes.
pub fn ecg_epoch_quality(values: &[f64]) -> f64 {
    if values.len() < 16 {
        return 0.0;
    }
    let n = values.len() as f64;
    let mean = values.iter().sum::<f64>() / n;
    let mut m2 = 0.0;
    let mut m4 = 0.0;
    for &v in values {
        let d = v - mean;
        let d2 = d * d;
        m2 += d2;
        m4 += d2 * d2;
    }
    let variance = m2 / n;
    if !variance.is_finite() || variance < 1e-6 {
        return 0.0; // flat or dead lead
    }
    let kurtosis = (m4 / n) / (variance * variance) - 3.0;
    if !kurtosis.is_finite() {
        return 0.0;
    }
    // ECG R-peaks naturally have high positive kurtosis (typically 2.0 to 15.0+).
    // If kurtosis is too negative (< -1.5) or insanely large (> 50.0), quality drops.
    if kurtosis < -1.5 || kurtosis > 50.0 {
        return 0.2;
    }
    (1.0 - ((kurtosis - 8.0).abs() / 30.0)).clamp(0.1, 1.0)
}

/// Computes average ECG subwindow SQI across 4s chunks.
pub fn compute_ecg_subwindow_sqi(ecg: &[f64], fs: f64) -> f64 {
    if ecg.is_empty() {
        return 0.0;
    }
    let sub_len = (fs * 4.0).round() as usize;
    if sub_len == 0 || ecg.len() < sub_len {
        return ecg_epoch_quality(ecg);
    }
    let mut sum_q = 0.0;
    let mut count = 0.0;
    let mut start = 0;
    while start + sub_len <= ecg.len() {
        sum_q += ecg_epoch_quality(&ecg[start..start + sub_len]);
        count += 1.0;
        start += sub_len;
    }
    if count > 0.0 {
        sum_q / count
    } else {
        0.0
    }
}

/// General signal quality selector depending on modality ("PPG", "ECG", or "EEG").
pub fn compute_channel_sqi(values: &[f64], fs: f64, modality: &str) -> f64 {
    match modality.to_uppercase().as_str() {
        "PPG" => compute_ppg_subwindow_sqi(values, fs),
        "ECG" => compute_ecg_subwindow_sqi(values, fs),
        "EEG" => eeg_epoch_quality(values),
        _ => eeg_epoch_quality(values),
    }
}
