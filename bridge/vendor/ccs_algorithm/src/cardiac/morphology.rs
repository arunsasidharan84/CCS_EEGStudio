//! Advanced Cardiac Morphology feature extraction engine.
//!
//! Computes APG (2nd derivative of PPG) `a`, `b`, `d`, `e` wave features and ratios (`b/a`, `d/a`, `e/a`),
//! along with `Morph_Pulse_Amp` and `Morph_SD_Time_Ratio` (`sys_t / dia_t`).
//!
//! Designed with full parity to `/Users/arunsasidharan/EEGdata/SenseIO/AnalyseRingData_v015.py`.

#[derive(Clone, Debug, Default)]
pub struct MorphologyMetrics {
    pub apg_b_a_ratio: f64,
    pub apg_d_a_ratio: f64,
    pub apg_e_a_ratio: f64,
    pub morph_pulse_amp: f64,
    pub morph_sd_time_ratio: f64,
}

/// 9-point Savitzky-Golay 2nd derivative (`polyorder=3`, `deriv=2`).
pub fn savgol_2nd_deriv_9(signal: &[f64], srate: f64) -> Vec<f64> {
    if signal.len() < 9 || srate <= 0.0 {
        return vec![0.0; signal.len()];
    }
    let delta = 1.0 / srate;
    let denom = 9240.0 * delta * delta;
    // c_k = (60 * k^2 - 400) / denom for k in -4..=4
    let coeffs: [f64; 9] = [
        (60.0 * 16.0 - 400.0) / denom, // k = -4 -> 560
        (60.0 * 9.0 - 400.0) / denom,  // k = -3 -> 140
        (60.0 * 4.0 - 400.0) / denom,  // k = -2 -> -160
        (60.0 * 1.0 - 400.0) / denom,  // k = -1 -> -340
        (-400.0) / denom,              // k =  0 -> -400
        (60.0 * 1.0 - 400.0) / denom,  // k =  1 -> -340
        (60.0 * 4.0 - 400.0) / denom,  // k =  2 -> -160
        (60.0 * 9.0 - 400.0) / denom,  // k =  3 -> 140
        (60.0 * 16.0 - 400.0) / denom, // k =  4 -> 560
    ];

    let mut apg = vec![0.0; signal.len()];
    let n = signal.len() as isize;
    for i in 0..n {
        let mut sum = 0.0;
        for (idx, &c) in coeffs.iter().enumerate() {
            let k = (idx as isize) - 4;
            let sample_idx = (i + k).clamp(0, n - 1) as usize;
            sum += c * signal[sample_idx];
        }
        apg[i as usize] = sum;
    }
    apg
}

/// Extract advanced morphology features from signal and peaks (`PPG` or `ECG`).
/// When `is_ppg = false` (`ECG`), outputs fallback zeros for PPG-unique APG ratios
/// (`b/a`, `d/a`, `e/a`) while computing valid `Morph_Pulse_Amp` and `Morph_SD_Time_Ratio`.
pub fn extract_advanced_morphology(
    signal: &[f64],
    peaks: &[usize],
    srate: f64,
    is_ppg: bool,
) -> MorphologyMetrics {
    if peaks.len() < 2 || srate <= 0.0 {
        return MorphologyMetrics::default();
    }

    let apg = if is_ppg {
        savgol_2nd_deriv_9(signal, srate)
    } else {
        Vec::new()
    };

    let mut b_a = Vec::new();
    let mut d_a = Vec::new();
    let mut e_a = Vec::new();
    let mut sd_r = Vec::new();
    let mut p_amps = Vec::new();

    let mut onsets = Vec::with_capacity(peaks.len() - 1);
    for i in 0..peaks.len() - 1 {
        let start = peaks[i];
        let end = peaks[i + 1].min(signal.len());
        if start >= end {
            onsets.push(start);
            continue;
        }
        let mut min_idx = start;
        let mut min_val = signal[start];
        for j in start..end {
            if signal[j] < min_val {
                min_val = signal[j];
                min_idx = j;
            }
        }
        onsets.push(min_idx);
    }

    for i in 0..onsets.len().saturating_sub(1) {
        let t1 = onsets[i];
        let t2 = peaks[i + 1];
        let t3 = onsets[i + 1];

        if t1 >= t2 || t2 >= t3 || t3 > signal.len() {
            continue;
        }

        let sys_t = (t2 - t1) as f64 / srate;
        let dia_t = (t3 - t2) as f64 / srate;
        if sys_t > 0.0 && dia_t > 0.0 {
            sd_r.push(sys_t / dia_t);
        }
        p_amps.push(signal[t2] - signal[t1]);

        if is_ppg && !apg.is_empty() && t2 < apg.len() {
            let a_s = &apg[t1..t2];
            if a_s.len() < 3 {
                continue;
            }
            let mut a_idx_local = 0;
            let mut a_val = a_s[0];
            for (j, &val) in a_s.iter().enumerate() {
                if val > a_val {
                    a_val = val;
                    a_idx_local = j;
                }
            }
            let a_idx = t1 + a_idx_local;
            if a_val.abs() < 1e-12 {
                continue;
            }

            // b-wave: local minimum in [a_idx, a_idx + 0.2*srate]
            let b_end = (a_idx + (0.2 * srate) as usize).min(apg.len());
            if b_end > a_idx && (b_end - a_idx) >= 3 {
                let b_s = &apg[a_idx..b_end];
                let b_val = b_s.iter().copied().fold(f64::INFINITY, f64::min);
                b_a.push(b_val / a_val);
            }

            // d-wave: local minimum in [a_idx + 0.15*srate, t2 + 0.3*srate]
            let d_start = (a_idx + (0.15 * srate) as usize).min(apg.len() - 1);
            let d_end = (t2 + (0.3 * srate) as usize).min(apg.len());
            if d_end > d_start && (d_end - d_start) > 3 {
                let d_s = &apg[d_start..d_end];
                let mut d_idx_local = 0;
                let mut d_val = d_s[0];
                for (j, &val) in d_s.iter().enumerate() {
                    if val < d_val {
                        d_val = val;
                        d_idx_local = j;
                    }
                }
                d_a.push(d_val / a_val);

                // e-wave: local maximum in [d_start + d_idx_local, t3]
                let e_start = (d_start + d_idx_local).min(apg.len() - 1);
                let e_end = t3.min(apg.len());
                if e_end > e_start && (e_end - e_start) > 3 {
                    let e_s = &apg[e_start..e_end];
                    let e_val = e_s.iter().copied().fold(f64::NEG_INFINITY, f64::max);
                    e_a.push(e_val / a_val);
                }
            }
        }
    }

    let mean_or_zero = |v: &[f64]| {
        let valid: Vec<f64> = v.iter().copied().filter(|x| x.is_finite()).collect();
        if valid.is_empty() {
            0.0
        } else {
            valid.iter().sum::<f64>() / valid.len() as f64
        }
    };

    MorphologyMetrics {
        apg_b_a_ratio: mean_or_zero(&b_a),
        apg_d_a_ratio: mean_or_zero(&d_a),
        apg_e_a_ratio: mean_or_zero(&e_a),
        morph_pulse_amp: mean_or_zero(&p_amps),
        morph_sd_time_ratio: mean_or_zero(&sd_r),
    }
}
