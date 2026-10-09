//! Heart Rate Variability (HRV) feature extraction engine.
//!
//! Computes time-domain, resampled frequency-domain (Welch PSD), and non-linear (Poincaré & Entropy) metrics.

use super::peaks::stddev;
use crate::eeg::features::welch_median;

#[derive(Clone, Debug, Default)]
pub struct HrvMetrics {
    pub mean_rr: f64,
    pub sdnn: f64,
    pub rmssd: f64,
    pub pnn50: f64,
    pub pnn20: f64,
    pub cvnn: f64,
    pub cvsd: f64,
    pub hti: f64,
    pub tinn: f64,
    pub vlf_power: f64,
    pub lf_power: f64,
    pub hf_power: f64,
    pub total_power: f64,
    pub lf_n: f64,
    pub hf_n: f64,
    pub lf_hf_ratio: f64,
    pub sd1: f64,
    pub sd2: f64,
    pub sd1_sd2_ratio: f64,
    pub csi: f64,
    pub cvi: f64,
    pub samp_en: f64,
    pub avg_hr_bpm: f64,
}

pub fn filter_rr_outliers(
    rr_intervals: &[f64],
    min_ms: f64,
    max_ms: f64,
    relative_threshold: f64,
) -> Vec<f64> {
    if rr_intervals.len() < 2 {
        return rr_intervals.to_vec();
    }
    let mut filtered: Vec<f64> = rr_intervals
        .iter()
        .copied()
        .filter(|&v| v > min_ms && v < max_ms)
        .collect();
    if filtered.len() > 1 {
        let mut valid = vec![true; filtered.len()];
        for i in 0..filtered.len() - 1 {
            let diff = (filtered[i + 1] - filtered[i]).abs();
            if diff > filtered[i] * relative_threshold {
                valid[i + 1] = false;
            }
        }
        filtered = filtered
            .iter()
            .enumerate()
            .filter_map(|(i, &val)| valid[i].then_some(val))
            .collect();
    }
    filtered
}

pub fn compute_hrv_features(peaks: &[usize], srate: f64) -> HrvMetrics {
    if peaks.len() < 3 || srate <= 0.0 {
        return HrvMetrics::default();
    }
    let mut rr = Vec::with_capacity(peaks.len() - 1);
    for i in 0..peaks.len() - 1 {
        let dt = (peaks[i + 1] - peaks[i]) as f64 * (1000.0 / srate);
        rr.push(dt);
    }
    let filtered_rr = filter_rr_outliers(&rr, 300.0, 2000.0, 0.25);
    if filtered_rr.len() < 2 {
        return HrvMetrics::default();
    }

    let n = filtered_rr.len() as f64;
    let mean_rr = filtered_rr.iter().sum::<f64>() / n;
    let sdnn = stddev(&filtered_rr);

    let mut sum_sq_diff = 0.0;
    let mut nn50 = 0.0;
    let mut nn20 = 0.0;
    let mut diffs = Vec::with_capacity(filtered_rr.len() - 1);
    let mut sums = Vec::with_capacity(filtered_rr.len() - 1);

    for i in 0..filtered_rr.len() - 1 {
        let d = filtered_rr[i + 1] - filtered_rr[i];
        diffs.push(d);
        sums.push(filtered_rr[i + 1] + filtered_rr[i]);
        let abs_d = d.abs();
        sum_sq_diff += abs_d * abs_d;
        if abs_d > 50.0 {
            nn50 += 1.0;
        }
        if abs_d > 20.0 {
            nn20 += 1.0;
        }
    }

    let rmssd = (sum_sq_diff / (n - 1.0)).sqrt();
    let pnn50 = (nn50 / (n - 1.0)) * 100.0;
    let pnn20 = (nn20 / (n - 1.0)) * 100.0;
    let cvnn = if mean_rr > 0.0 { sdnn / mean_rr } else { 0.0 };
    let cvsd = if mean_rr > 0.0 { rmssd / mean_rr } else { 0.0 };
    let avg_hr_bpm = if mean_rr > 0.0 {
        60000.0 / mean_rr
    } else {
        0.0
    };

    // Poincaré plot features
    let sd1 = stddev(&diffs) / std::f64::consts::SQRT_2;
    let sd2 = stddev(&sums) / std::f64::consts::SQRT_2;
    let sd1_sd2_ratio = if sd2 > 0.0 { sd1 / sd2 } else { 0.0 };
    let csi = if sd1 > 0.0 { sd2 / sd1 } else { 0.0 };
    let cvi = if sd1 > 0.0 && sd2 > 0.0 {
        (16.0 * sd1 * sd2).log10()
    } else {
        0.0
    };

    // HTI and TINN
    let (hti, tinn) = compute_triangular_metrics(&filtered_rr);

    // Frequency domain via 4 Hz resampling + Welch PSD
    let (vlf, lf, hf, total) = compute_frequency_hrv(&filtered_rr, mean_rr);
    let lf_n = if (lf + hf) > 0.0 {
        (lf / (lf + hf)) * 100.0
    } else {
        0.0
    };
    let hf_n = if (lf + hf) > 0.0 {
        (hf / (lf + hf)) * 100.0
    } else {
        0.0
    };
    let lf_hf_ratio = if hf > 0.0 { lf / hf } else { 0.0 };

    // Sample Entropy
    let samp_en = compute_sample_entropy(&filtered_rr, 2, 0.2 * sdnn);

    HrvMetrics {
        mean_rr,
        sdnn,
        rmssd,
        pnn50,
        pnn20,
        cvnn,
        cvsd,
        hti,
        tinn,
        vlf_power: vlf,
        lf_power: lf,
        hf_power: hf,
        total_power: total,
        lf_n,
        hf_n,
        lf_hf_ratio,
        sd1,
        sd2,
        sd1_sd2_ratio,
        csi,
        cvi,
        samp_en,
        avg_hr_bpm,
    }
}

fn compute_triangular_metrics(rr: &[f64]) -> (f64, f64) {
    if rr.is_empty() {
        return (0.0, 0.0);
    }
    // Histogram with 7.8125 ms bin width (1/128 s)
    let bin_w = 7.8125;
    let min_r = rr.iter().copied().fold(f64::INFINITY, f64::min);
    let max_r = rr.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    if max_r <= min_r {
        return (rr.len() as f64, 0.0);
    }
    let num_bins = ((max_r - min_r) / bin_w).ceil() as usize + 1;
    let mut hist = vec![0usize; num_bins];
    for &r in rr {
        let idx = ((r - min_r) / bin_w) as usize;
        if idx < hist.len() {
            hist[idx] += 1;
        }
    }
    let max_count = hist.iter().copied().max().unwrap_or(1);
    let hti = if max_count > 0 {
        rr.len() as f64 / max_count as f64
    } else {
        0.0
    };
    let tinn = (max_r - min_r).max(0.0);
    (hti, tinn)
}

fn compute_frequency_hrv(rr: &[f64], mean_rr_ms: f64) -> (f64, f64, f64, f64) {
    if rr.len() < 5 || mean_rr_ms <= 0.0 {
        return (0.0, 0.0, 0.0, 0.0);
    }
    // Convert RR sequence to cumulative time in seconds
    let mut time_sec = Vec::with_capacity(rr.len());
    let mut cur_t = 0.0;
    for &r in rr {
        time_sec.push(cur_t);
        cur_t += r / 1000.0;
    }
    let total_duration = cur_t;
    if total_duration < 4.0 {
        return (0.0, 0.0, 0.0, 0.0);
    }
    // Resample at 4 Hz
    let fs_resample = 4.0;
    let dt = 1.0 / fs_resample;
    let num_samples = (total_duration * fs_resample).floor() as usize;
    if num_samples < 8 {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let mut resampled = Vec::with_capacity(num_samples);
    let mut rr_idx = 0;
    for i in 0..num_samples {
        let t = i as f64 * dt;
        while rr_idx + 1 < time_sec.len() && time_sec[rr_idx + 1] <= t {
            rr_idx += 1;
        }
        if rr_idx + 1 < time_sec.len() {
            let t0 = time_sec[rr_idx];
            let t1 = time_sec[rr_idx + 1];
            let alpha = if t1 > t0 { (t - t0) / (t1 - t0) } else { 0.0 };
            resampled.push(rr[rr_idx] + alpha * (rr[rr_idx + 1] - rr[rr_idx]));
        } else {
            resampled.push(*rr.last().unwrap());
        }
    }

    // Demean and run Welch PSD
    let mean_res = resampled.iter().sum::<f64>() / resampled.len() as f64;
    let centered: Vec<f64> = resampled.iter().map(|&v| v - mean_res).collect();
    let (freqs, psd) = welch_median(&centered, fs_resample);
    if freqs.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let df = if freqs.len() > 1 {
        freqs[1] - freqs[0]
    } else {
        1.0
    };
    let mut vlf = 0.0;
    let mut lf = 0.0;
    let mut hf = 0.0;
    for (&f, &p) in freqs.iter().zip(&psd) {
        if f >= 0.0033 && f < 0.04 {
            vlf += p * df;
        } else if f >= 0.04 && f < 0.15 {
            lf += p * df;
        } else if f >= 0.15 && f < 0.4 {
            hf += p * df;
        }
    }
    let total = vlf + lf + hf;
    (vlf, lf, hf, total)
}

fn compute_sample_entropy(x: &[f64], m: usize, r: f64) -> f64 {
    let n = x.len();
    if n <= m + 1 || r <= 0.0 {
        return 0.0;
    }
    let mut a_count = 0.0;
    let mut b_count = 0.0;
    for i in 0..n - m {
        for j in i + 1..n - m {
            let mut match_m = true;
            for k in 0..m {
                if (x[i + k] - x[j + k]).abs() >= r {
                    match_m = false;
                    break;
                }
            }
            if match_m {
                b_count += 1.0;
                if (x[i + m] - x[j + m]).abs() < r {
                    a_count += 1.0;
                }
            }
        }
    }
    if a_count > 0.0 && b_count > 0.0 {
        let ratio: f64 = a_count / b_count;
        -ratio.ln()
    } else {
        0.0
    }
}
