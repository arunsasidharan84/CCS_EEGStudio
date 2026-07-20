use nalgebra::{DMatrix, SymmetricEigen};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, f64::consts::PI, fs, io::Write, path::Path};

use crate::{spectral::resample_poly, Recording};
use rayon::prelude::*;

#[derive(Deserialize, Clone)]
pub struct PreprocessOptions {
    #[serde(default = "default_true")]
    pub downsample: bool,
    #[serde(default = "default_target_rate")]
    pub downsample_freq: f64,
    #[serde(default = "default_true")]
    pub filter: bool,
    #[serde(default = "default_low")]
    pub low_hz: f64,
    #[serde(default = "default_high")]
    pub high_hz: f64,
    #[serde(default = "default_notch")]
    pub notch_hz: f64,
    #[serde(default = "default_true")]
    pub badchannel: bool,
    #[serde(default = "default_true")]
    pub gedai: bool,
    #[serde(default = "default_true")]
    pub interpolate: bool,
    #[serde(default = "default_epoch")]
    pub gedai_epoch_seconds: f64,
    #[serde(default = "default_threshold")]
    pub gedai_threshold: String,
    #[serde(default)]
    pub source_localization: bool,
    #[serde(default)]
    pub epoch_before_gedai: bool,
    #[serde(default)]
    pub epoch_length_seconds: Option<f64>,
    /// Explicit non-EEG channel labels resolved by the UI.  Empty means "use
    /// the built-in `is_eeg_label` heuristic".
    #[serde(default)]
    pub non_eeg_channels: Vec<String>,
}

#[derive(Serialize)]
pub struct PreprocessSummary {
    pub input: String,
    pub output: String,
    pub sample_rate: f64,
    pub channels: usize,
    pub samples: usize,
    pub bad_channels: Vec<String>,
    pub sensai_score: Option<f64>,
    pub thresholds: Vec<f64>,
    pub warnings: Vec<String>,
    pub source_localized: bool,
}

#[derive(Serialize, Deserialize)]
pub struct PortableRecording {
    pub format: String,
    pub sample_rate: f64,
    pub labels: Vec<String>,
    pub channels: Vec<Vec<f32>>,
    #[serde(default)]
    pub source_epoch_samples: Option<usize>,
    #[serde(default)]
    pub epoch_labels: Option<Vec<String>>,
}

struct GedaiResult {
    clean: Vec<Vec<f64>>,
    score: f64,
    thresholds: Vec<f64>,
}

pub fn run(
    rec: &mut Recording,
    input: &str,
    output: &str,
    options: &PreprocessOptions,
) -> Result<PreprocessSummary, String> {
    let mut warnings = Vec::new();
    normalize_channel_set(rec, &options.non_eeg_channels);
    
    eprintln!("PROGRESS 10 Converting channels to f64...");
    // Convert to f64 for all processing in parallel
    let mut f64_channels: Vec<Vec<f64>> = rec.channels.par_iter()
        .map(|ch| ch.iter().map(|v| *v as f64).collect())
        .collect();
        
    if (options.downsample_freq - rec.rate).abs() > 0.5 && options.downsample_freq > 0.0 {
        eprintln!("PROGRESS 30 Downsampling from {} Hz to {} Hz...", rec.rate, options.downsample_freq);
        let scale = options.downsample_freq / rec.rate;
        let up = (options.downsample_freq * scale as f64).round().max(1.0) as usize;
        let down = (rec.rate * scale as f64).round().max(1.0) as usize;
        let pts_per_epoch = rec.source_epoch_samples;
        f64_channels.par_iter_mut().for_each(|ch| {
            if let Some(pts) = pts_per_epoch {
                if pts > 0 && ch.len() >= pts {
                    let mut resampled = Vec::with_capacity((ch.len() as f64 * (options.downsample_freq / rec.rate)) as usize + 100);
                    for chunk in ch.chunks(pts) {
                        resampled.extend(resample_poly(chunk, up, down));
                    }
                    *ch = resampled;
                    return;
                }
            }
            *ch = resample_poly(ch, up, down);
        });
        if let Some(pts) = rec.source_epoch_samples {
            rec.source_epoch_samples = Some((pts as f64 * (options.downsample_freq / rec.rate)).round() as usize);
        }
        rec.rate = options.downsample_freq;
    }
    if options.filter {
        eprintln!("PROGRESS 40 Applying FIR bandpass/notch filters...");
        let rate = rec.rate;
        let low = options.low_hz;
        let high = options.high_hz;
        let notch = options.notch_hz;
        let pts_per_epoch = rec.source_epoch_samples;
        f64_channels.par_iter_mut().for_each(|ch| {
            if let Some(pts) = pts_per_epoch {
                if pts > 0 && ch.len() >= pts {
                    for chunk in ch.chunks_mut(pts) {
                        fir_bandpass(chunk, rate, low, high);
                        if notch > 0.0 {
                            fir_notch(chunk, rate, notch);
                        }
                    }
                    return;
                }
            }
            fir_bandpass(ch, rate, low, high);
            if notch > 0.0 {
                fir_notch(ch, rate, notch);
            }
        });
    }
    
    let bad_channels = if options.badchannel {
        detect_bad_channels(rec)
    } else {
        Vec::new()
    };
    if options.epoch_before_gedai || options.epoch_length_seconds.is_some() {
        let sec = options.epoch_length_seconds.unwrap_or(options.gedai_epoch_seconds);
        if sec > 0.0 {
            let pts = (rec.rate * sec).round() as usize;
            if pts > 0 && f64_channels.first().map(|c| c.len()).unwrap_or(0) >= pts {
                let total_pts = f64_channels[0].len();
                let valid_pts = (total_pts / pts) * pts;
                for ch in &mut f64_channels {
                    ch.truncate(valid_pts);
                }
                rec.source_epoch_samples = Some(pts);
                eprintln!("PROGRESS 44 Epoched continuous recording into {} epochs of {} samples before GEDAI", valid_pts / pts, pts);
            }
        }
    }
    let mut sensai_score = None;
    let mut thresholds = Vec::new();
    if options.gedai && rec.channels.len() >= 4 {
        match gedai(
            &mut f64_channels,
            rec.rate,
            &rec.labels,
            options.gedai_epoch_seconds,
            &options.gedai_threshold,
        ) {
            Ok(result) => {
                let len = result.clean.first().map(Vec::len).unwrap_or(0);
                f64_channels = result.clean;
                for ch in &mut f64_channels {
                    ch.truncate(len);
                }
                sensai_score = Some(result.score);
                thresholds = result.thresholds;
            }
            Err(err) => warnings.push(format!("GEDAI skipped: {err}")),
        }
    }
    if options.interpolate && !bad_channels.is_empty() {
        interpolate_bad_channels(&mut f64_channels, &rec.labels, &bad_channels);
    }
    
    let mut source_localized = false;
    if options.source_localization {
        eprintln!("PROGRESS 85 Converting to source space (68 FreeSurfer ROIs via eLORETA)...");
        match crate::source_loc::convert_to_source_space(&f64_channels, &rec.labels, 3.0) {
            Ok((roi_data, roi_labels)) => {
                f64_channels = roi_data;
                rec.labels = roi_labels;
                source_localized = true;
            }
            Err(e) => warnings.push(format!("Source localization failed: {e}")),
        }
    }

    // Copy back to f32 in parallel
    eprintln!("PROGRESS 88 Copying back to f32...");
    rec.channels = f64_channels.par_iter()
        .map(|ch| ch.iter().map(|v| *v as f32).collect())
        .collect();

    eprintln!("PROGRESS 90 Saving portable JSON to {}...", output);
    save_portable(output, rec)?;
    Ok(PreprocessSummary {
        input: input.into(),
        output: output.into(),
        sample_rate: rec.rate,
        channels: rec.channels.len(),
        samples: rec.channels.first().map(Vec::len).unwrap_or(0),
        bad_channels,
        sensai_score,
        thresholds,
        warnings,
        source_localized,
    })
}

pub fn load_portable(path: &Path) -> Result<Recording, String> {
    let parsed: PortableRecording =
        serde_json::from_slice(&fs::read(path).map_err(err)?).map_err(err)?;
    if parsed.format != "ccseeg-v1" {
        return Err("unsupported portable EEG file".into());
    }
    Ok(Recording {
        rate: parsed.sample_rate,
        labels: parsed.labels,
        channels: parsed.channels,
        source_epoch_samples: parsed.source_epoch_samples,
        epoch_labels: parsed.epoch_labels,
    })
}

fn save_portable(path: &str, rec: &Recording) -> Result<(), String> {
    let portable = PortableRecording {
        format: "ccseeg-v1".into(),
        sample_rate: rec.rate,
        labels: rec.labels.clone(),
        channels: rec.channels.clone(),
        source_epoch_samples: rec.source_epoch_samples,
        epoch_labels: rec.epoch_labels.clone(),
    };
    let mut file = fs::File::create(path).map_err(err)?;
    serde_json::to_writer(&mut file, &portable).map_err(err)?;
    file.write_all(b"\n").map_err(err)
}

/// Restricts the recording to EEG channels before cleaning.
///
/// `non_eeg` is the explicit list resolved by the UI (auto-detected, then
/// user-overridable).  When it is non-empty it wins outright; the built-in
/// `is_eeg_label` heuristic is only a fallback for jobs authored outside the
/// GUI.  Dropping aux channels here matters because bad-channel detection
/// compares per-channel variance against the median, and an ECG or GSR trace
/// sitting in that pool skews the median enough to mislabel real EEG channels.
fn normalize_channel_set(rec: &mut Recording, non_eeg: &[String]) {
    let keep: Vec<usize> = if non_eeg.is_empty() {
        rec.labels
            .iter()
            .enumerate()
            .filter(|(_, label)| is_eeg_label(label))
            .map(|(i, _)| i)
            .collect()
    } else {
        let drop: std::collections::HashSet<String> =
            non_eeg.iter().map(|l| l.trim().to_uppercase()).collect();
        rec.labels
            .iter()
            .enumerate()
            .filter(|(_, label)| !drop.contains(&label.trim().to_uppercase()))
            .map(|(i, _)| i)
            .collect()
    };
    if !keep.is_empty() && keep.len() < rec.labels.len() {
        rec.labels = keep.iter().map(|i| rec.labels[*i].clone()).collect();
        rec.channels = keep.iter().map(|i| rec.channels[*i].clone()).collect();
    }
}

fn is_eeg_label(label: &str) -> bool {
    let upper = label.to_uppercase();
    !["GSR", "ECG", "EOG", "EMG", "RESP", "X_DIR", "Y_DIR", "Z_DIR", "STATUS", "MARK"]
        .iter()
        .any(|bad| upper.contains(bad))
}

#[allow(dead_code)]
fn resample_polyphase(rec: &mut Recording, target: f64) -> Result<(), String> {
    if target <= 0.0 {
        return Err("target sample rate must be positive".into());
    }
    let scale = 1000usize;
    let up = (target * scale as f64).round().max(1.0) as usize;
    let down = (rec.rate * scale as f64).round().max(1.0) as usize;
    for ch in &mut rec.channels {
        let old: Vec<f64> = ch.iter().map(|value| *value as f64).collect();
        *ch = resample_poly(&old, up, down)
            .into_iter()
            .map(|value| value as f32)
            .collect();
    }
    rec.rate = target;
    Ok(())
}

fn fir_bandpass(x: &mut [f64], rate: f64, low: f64, high: f64) {
    if x.is_empty() {
        return;
    }
    let high = high.min(rate / 2.0);
    
    // MNE calculates transition bands and sets the -6dB cutoff to the middle
    let l_trans = low.max(0.5).min(low); // For lowpass edge of highpass
    let h_trans = (high * 0.25).max(2.0).min(high); // For highpass edge of lowpass
    
    let low_cutoff = low - l_trans / 2.0;
    let high_cutoff = high + h_trans / 2.0;
    
    // Calculate filter length based on transition band, clamped to min 2.0 Hz for speed & stability
    let mut trans = if low > 0.0 && high > 0.0 {
        l_trans.min(h_trans)
    } else if low > 0.0 {
        l_trans
    } else {
        h_trans
    };
    trans = trans.max(2.0);
    let len = mne_filter_len(rate, trans);

    let kernel = match (low > 0.0, high > 0.0 && high < rate / 2.0) {
        (true, true) => fir_bandpass_kernel(rate, low_cutoff, high_cutoff, len),
        (true, false) => fir_highpass_kernel(rate, low_cutoff, len),
        (false, true) => fir_lowpass_kernel(rate, high_cutoff, len),
        (false, false) => return,
    };
    apply_centered_fir(x, &kernel);
}

fn fir_notch(x: &mut [f64], rate: f64, freq: f64) {
    if x.is_empty() || freq <= 0.0 || freq >= rate / 2.0 {
        return;
    }
    let width = 1.0;
    let trans = 2.0;
    
    // For bandstop, MNE sets transition band 0.5 Hz by default
    let low_cutoff = (freq - width / 2.0) - trans / 2.0;
    let high_cutoff = (freq + width / 2.0) + trans / 2.0;
    
    let mut kernel = fir_bandpass_kernel(rate, low_cutoff, high_cutoff, mne_filter_len(rate, trans));
    for value in &mut kernel {
        *value = -*value;
    }
    let center = kernel.len() / 2;
    kernel[center] += 1.0;
    apply_centered_fir(x, &kernel);
}

fn mne_filter_len(rate: f64, transition: f64) -> usize {
    let transition = transition.abs();
    let mut len = (3.3 * rate / transition).ceil() as usize;
    if len % 2 == 0 {
        len += 1;
    }
    len.max(3)
}

fn fir_bandpass_kernel(rate: f64, low: f64, high: f64, len: usize) -> Vec<f64> {
    let lp_high = fir_lowpass_kernel(rate, high, len);
    let lp_low = fir_lowpass_kernel(rate, low, len);
    lp_high
        .into_iter()
        .zip(lp_low)
        .map(|(high, low)| high - low)
        .collect()
}

fn fir_highpass_kernel(rate: f64, cutoff: f64, len: usize) -> Vec<f64> {
    let mut kernel = fir_lowpass_kernel(rate, cutoff, len);
    for value in &mut kernel {
        *value = -*value;
    }
    let center = len / 2;
    kernel[center] += 1.0;
    kernel
}

fn fir_lowpass_kernel(rate: f64, cutoff: f64, len: usize) -> Vec<f64> {
    let center = len / 2;
    let fc = cutoff / rate;
    let mut kernel = (0..len)
        .map(|i| {
            let n = i as isize - center as isize;
            let sinc = if n == 0 {
                2.0 * fc
            } else {
                (2.0 * PI * fc * n as f64).sin() / (PI * n as f64)
            };
            let window = 0.54 - 0.46 * (2.0 * PI * i as f64 / (len - 1) as f64).cos();
            sinc * window
        })
        .collect::<Vec<_>>();
    let sum = kernel.iter().sum::<f64>();
    if sum.abs() > f64::MIN_POSITIVE {
        for value in &mut kernel {
            *value /= sum;
        }
    }
    kernel
}

fn apply_centered_fir(x: &mut [f64], kernel: &[f64]) {
    let input = x.to_vec();
    let center = kernel.len() / 2;
    let len = input.len();
    for i in 0..len {
        let mut acc = 0.0;
        if i >= center && i + kernel.len() - center <= len {
            let start = i - center;
            for (k, coeff) in kernel.iter().enumerate() {
                acc += coeff * input[start + k];
            }
        } else {
            for (k, coeff) in kernel.iter().enumerate() {
                let pos = reflect_index(i as isize + k as isize - center as isize, len);
                acc += coeff * input[pos];
            }
        }
        x[i] = acc;
    }
}

fn reflect_index(index: isize, len: usize) -> usize {
    if len <= 1 {
        return 0;
    }
    let period = 2 * len as isize - 2;
    let mut idx = index % period;
    if idx < 0 {
        idx += period;
    }
    if idx >= len as isize {
        (period - idx) as usize
    } else {
        idx as usize
    }
}

/// Flags channels whose variance is degenerate relative to the recording.
///
/// A channel is bad when it is effectively flat (variance below 1e-18, i.e. a
/// dead or disconnected electrode) or when its variance exceeds 25× the median
/// across channels (a channel dominated by artefact).
///
/// This function previously seeded its result with a hardcoded list —
/// `AF4, Fz, AF3, F3, T7, PO4, F4` — which marked those seven electrodes bad on
/// *every* recording regardless of their data, so they were unconditionally
/// interpolated away. That was leftover debug scaffolding, not a real rule, and
/// it silently destroyed good frontal and central data. Detection is now purely
/// data-driven.
fn detect_bad_channels(rec: &Recording) -> Vec<String> {
    let mut bad_chs: Vec<String> = Vec::new();

    let vars: Vec<f64> = rec.channels.iter().map(|ch| variance_f32(ch)).collect();
    let med = median(vars.clone());
    for (i, var) in vars.iter().enumerate() {
        if *var < 1e-18 || *var > med * 25.0 {
            let label = rec.labels[i].clone();
            if !bad_chs.contains(&label) {
                bad_chs.push(label);
            }
        }
    }

    bad_chs
}

#[allow(dead_code)]
fn pearson_f32_f64(left: &[f32], right: &[f64]) -> f64 {
    let n = left.len().min(right.len());
    if n == 0 {
        return 0.0;
    }
    let mean_left = left.iter().take(n).map(|value| *value as f64).sum::<f64>() / n as f64;
    let mean_right = right.iter().take(n).sum::<f64>() / n as f64;
    let mut numerator = 0.0;
    let mut left_var = 0.0;
    let mut right_var = 0.0;
    for i in 0..n {
        let a = left[i] as f64 - mean_left;
        let b = right[i] - mean_right;
        numerator += a * b;
        left_var += a * a;
        right_var += b * b;
    }
    numerator / (left_var * right_var).sqrt().max(f64::MIN_POSITIVE)
}

fn interpolate_bad_channels(channels: &mut [Vec<f64>], labels: &[String], bad: &[String]) {
    let bad_idx: Vec<usize> = labels
        .iter()
        .enumerate()
        .filter(|(_, label)| bad.iter().any(|b| b == *label))
        .map(|(i, _)| i)
        .collect();
    if bad_idx.is_empty() || bad_idx.len() >= channels.len() {
        return;
    }
    let good_idx: Vec<usize> = (0..channels.len())
        .filter(|i| !bad_idx.contains(i))
        .collect();
        
    // Build DMatrix for good and bad coords
    use crate::montage::STANDARD_1005_POS;
    use nalgebra::DMatrix;
    
    let mut good_coords = Vec::new();
    let mut actual_good_idx = Vec::new();
    for &i in &good_idx {
        if let Some(pos) = STANDARD_1005_POS.get(labels[i].to_uppercase().as_str()) {
            actual_good_idx.push(i);
            good_coords.push(*pos);
        }
    }
    
    let mut bad_coords = Vec::new();
    let mut actual_bad_idx = Vec::new();
    for &i in &bad_idx {
        if let Some(pos) = STANDARD_1005_POS.get(labels[i].to_uppercase().as_str()) {
            actual_bad_idx.push(i);
            bad_coords.push(*pos);
        }
    }
    
    if actual_good_idx.is_empty() || actual_bad_idx.is_empty() {
        // Fallback to mean if no coordinates
        for &bad_i in &bad_idx {
            for s in 0..channels[0].len() {
                let mut sum = 0.0;
                for &g in &good_idx {
                    sum += channels[g][s];
                }
                channels[bad_i][s] = sum / good_idx.len() as f64;
            }
        }
        return;
    }
    
    let pos_good = DMatrix::from_fn(actual_good_idx.len(), 3, |r, c| good_coords[r][c]);
    let pos_bad = DMatrix::from_fn(actual_bad_idx.len(), 3, |r, c| bad_coords[r][c]);
    
    // Compute spherical spline interpolation matrix
    let w = crate::ransac::make_interpolation_matrix(&pos_good, &pos_bad);
    
    let len = channels[0].len();
    for (b_local, &b_global) in actual_bad_idx.iter().enumerate() {
        for s in 0..len {
            let mut interp_val = 0.0;
            for (g_local, &g_global) in actual_good_idx.iter().enumerate() {
                interp_val += channels[g_global][s] * w[(g_local, b_local)];
            }
            channels[b_global][s] = interp_val;
        }
    }
}

#[allow(dead_code)]
fn standard_position(label: &str) -> Option<[f64; 3]> {
    match label {
        "Fz" => Some([0.0003122, 0.058512, 0.066462]),
        "F3" => Some([-0.0502438, 0.0531112, 0.042192]),
        "F4" => Some([0.0518362, 0.0543048, 0.040814]),
        "C3" => Some([-0.0653581, -0.0116317, 0.064358]),
        "C4" => Some([0.0671179, -0.0109003, 0.06358]),
        "P3" => Some([-0.0530073, -0.0787878, 0.05594]),
        "P4" => Some([0.0556667, -0.0785602, 0.056561]),
        "Pz" => Some([0.0003247, -0.081115, 0.082615]),
        "O1" => Some([-0.0294134, -0.112449, 0.008839]),
        "O2" => Some([0.0298426, -0.112156, 0.0088]),
        _ => None,
    }
}

fn gedai(
    data: &mut [Vec<f64>],
    rate: f64,
    labels: &[String],
    epoch_seconds: f64,
    threshold_type: &str,
) -> Result<GedaiResult, String> {
    let n = data.len();
    let samples = data[0].len();
    for s in 0..samples {
        let avg = data.iter().map(|ch| ch[s]).sum::<f64>() / (n as f64 + 1.0);
        for ch in data.iter_mut() {
            ch[s] -= avg;
        }
    }
    let ref_cov = leadfield_cov(labels).unwrap_or_else(|| DMatrix::identity(n, n));
    eprintln!("PROGRESS 45 GEDAI: computing broadband spatial separation...");
    let (broad, _, broad_score, broad_threshold) =
        gedai_per_band(&data, rate, epoch_seconds, &ref_cov, threshold_type, true)?;
    eprintln!("PROGRESS 50 GEDAI: decomposing signal into MODWT MRA bands...");
    let bands = modwt_mra_all(&broad, 3);
    let exclude = (600.0 / rate).ceil() as usize;
    let process_bands = bands.len().saturating_sub(exclude).max(1).min(bands.len());
    let mut clean_sum = vec![vec![0.0; broad[0].len()]; n];
    let mut thresholds = vec![broad_threshold];
    for (i, band) in bands.iter().take(process_bands).enumerate() {
        let pct = 50 + (25 * (i + 1) / process_bands);
        eprintln!("PROGRESS {} GEDAI: cleaning MRA frequency band {}/{}...", pct, i + 1, process_bands);
        let (clean, _, _, threshold) =
            gedai_per_band(band, rate, epoch_seconds, &ref_cov, threshold_type, true)?;
        thresholds.push(threshold);
        for c in 0..n {
            for s in 0..clean[c].len() {
                clean_sum[c][s] += clean[c][s];
            }
        }
    }
    for band in bands.iter().skip(process_bands) {
        for c in 0..n {
            for s in 0..band[c].len() {
                clean_sum[c][s] += band[c][s];
            }
        }
    }
    let artifacts = subtract(&data, &clean_sum);
    let score = sensai_basic(&clean_sum, &artifacts, rate, epoch_seconds, &ref_cov, 1.0)
        .unwrap_or(broad_score);
    Ok(GedaiResult {
        clean: clean_sum,
        score,
        thresholds,
    })
}

pub fn gedai_per_band(
    data: &[Vec<f64>],
    rate: f64,
    epoch_seconds: f64,
    ref_cov: &DMatrix<f64>,
    threshold_type: &str,
    optimize: bool,
) -> Result<(Vec<Vec<f64>>, Vec<Vec<f64>>, f64, f64), String> {
    let n = data.len();
    let epoch = ((rate * epoch_seconds).round() as usize).max(4);
    let epoch = if epoch % 2 == 0 { epoch } else { epoch + 1 };
    let epochs = data[0].len() / epoch;
    if epochs < 2 {
        return Err("GEDAI requires at least two epochs".into());
    }
    let len = epochs * epoch;
    let stream1 = epoch_view(data, 0, epoch, epochs);
    let stream2 = epoch_view(data, epoch / 2, epoch, epochs - 1);
    let (evals1, evecs1) = gevd_epochs(&stream1, ref_cov)?;
    let (evals2, evecs2) = gevd_epochs(&stream2, ref_cov)?;
    let threshold = match threshold_type {
        "auto+" | "auto" | "auto-" if optimize => {
            let noise = if threshold_type == "auto+" {
                1.0
            } else if threshold_type == "auto" {
                3.0
            } else {
                6.0
            };
            optimize_threshold(&stream1, rate, epoch_seconds, ref_cov, &evals1, &evecs1, noise)
        }
        "auto+" => 3.0,
        "auto" => 6.0,
        "auto-" => 9.0,
        other => other.parse().unwrap_or(6.0),
    };
    let (mut clean1, art1) = clean_eeg(&stream1, threshold, &evals1, &evecs1);
    let (mut clean2, mut art2) = clean_eeg(&stream2, threshold, &evals2, &evecs2);
    let shift = epoch / 2;
    let weights = cosine_weights(epoch);
    let len2 = clean2[0].len();
    for c in 0..n {
        for s in 0..shift {
            clean2[c][s] *= weights[s];
            art2[c][s] *= weights[s];
        }
        for s in len2 - shift..len2 {
            clean2[c][s] *= weights[shift + (s - (len2 - shift))];
            art2[c][s] *= weights[shift + (s - (len2 - shift))];
        }
        for s in 0..len2 {
            clean1[c][shift + s] += clean2[c][s];
        }
    }
    let artifacts = subtract(&data.iter().map(|ch| ch[..len].to_vec()).collect::<Vec<_>>(), &clean1);
    let score = sensai_basic(&clean1, &artifacts, rate, epoch_seconds, ref_cov, 1.0).unwrap_or(0.0);
    Ok((clean1, art1, score, threshold))
}

fn epoch_view(data: &[Vec<f64>], offset: usize, epoch: usize, epochs: usize) -> Vec<DMatrix<f64>> {
    (0..epochs)
        .map(|e| {
            DMatrix::from_fn(data.len(), epoch, |c, s| {
                data[c][offset + e * epoch + s]
            })
        })
        .collect()
}

fn gevd_epochs(
    epochs: &[DMatrix<f64>],
    ref_cov: &DMatrix<f64>,
) -> Result<(Vec<Vec<f64>>, Vec<DMatrix<f64>>), String> {
    let n = ref_cov.nrows();
    let eig_ref = SymmetricEigen::new(ref_cov.clone());
    let mean = eig_ref.eigenvalues.iter().sum::<f64>() / n as f64;
    let b = ref_cov * 0.95 + DMatrix::identity(n, n) * (0.05 * mean.max(1e-12));
    let chol = b.cholesky().ok_or("reference covariance is not positive definite")?;
    let l_inv = chol.l().try_inverse().ok_or("Failed to invert L")?;
    let (evals_all, evecs_all): (Vec<Vec<f64>>, Vec<DMatrix<f64>>) = epochs
        .par_iter()
        .map(|epoch| {
            let cov = covariance(epoch);
            let z = &l_inv * cov * l_inv.transpose();
            let eig = SymmetricEigen::new((&z + z.transpose()) * 0.5);
            let mut order: Vec<usize> = (0..n).collect();
            order.sort_by(|a, b| eig.eigenvalues[*b].total_cmp(&eig.eigenvalues[*a]));
            let vals: Vec<f64> = order.iter().map(|i| eig.eigenvalues[*i]).collect();
            let vecs = DMatrix::from_fn(n, n, |r, c| {
                (l_inv.transpose() * eig.eigenvectors.column(order[c]))[r]
            });
            (vals, vecs)
        })
        .unzip();
    Ok((evals_all, evecs_all))
}

fn clean_eeg(
    epochs: &[DMatrix<f64>],
    threshold: f64,
    evals: &[Vec<f64>],
    evecs: &[DMatrix<f64>],
) -> (Vec<Vec<f64>>, Vec<Vec<f64>>) {
    let n = epochs[0].nrows();
    let epoch_len = epochs[0].ncols();
    let mut log_vals: Vec<f64> = evals
        .iter()
        .flat_map(|v| v.iter())
        .filter(|v| v.abs() > 0.0)
        .map(|v| v.abs().ln() + 100.0)
        .collect();
    log_vals.sort_by(|a, b| a.total_cmp(b));
    let idx = ((log_vals.len() as f64) * 0.95).floor() as usize;
    let t1 = (105.0 - threshold) / 100.0;
    let threshold_val = t1 * log_vals[idx.min(log_vals.len() - 1)];
    let threshold_exp = (threshold_val - 100.0).exp();
    let weights = cosine_weights(epoch_len);
    let mut clean = vec![vec![0.0; epochs.len() * epoch_len]; n];
    let mut artifacts = vec![vec![0.0; epochs.len() * epoch_len]; n];
    let results: Vec<(DMatrix<f64>, DMatrix<f64>)> = epochs
        .par_iter()
        .enumerate()
        .map(|(i, epoch)| {
            let mut w = evecs[i].clone();
            for c in 0..n {
                if evals[i][c].abs() < threshold_exp {
                    for r in 0..n {
                        w[(r, c)] = 0.0;
                    }
                }
            }
            let sources = w.transpose() * epoch;
            let recon = evecs[i]
                .transpose()
                .lu()
                .solve(&sources)
                .unwrap_or_else(|| DMatrix::zeros(n, epoch_len));
            let mut cleaned = epoch - &recon;
            let half = epoch_len / 2;
            if i == 0 {
                for c in 0..n {
                    for s in half..epoch_len {
                        cleaned[(c, s)] *= weights[s];
                    }
                }
            } else if i == epochs.len() - 1 {
                for c in 0..n {
                    for s in 0..half {
                        cleaned[(c, s)] *= weights[s];
                    }
                }
            } else {
                for c in 0..n {
                    for s in 0..epoch_len {
                        cleaned[(c, s)] *= weights[s];
                    }
                }
            }
            (cleaned, recon)
        })
        .collect();

    for (i, (cleaned, recon)) in results.iter().enumerate() {
        for c in 0..n {
            for s in 0..epoch_len {
                clean[c][i * epoch_len + s] = cleaned[(c, s)];
                artifacts[c][i * epoch_len + s] = recon[(c, s)];
            }
        }
    }
    (clean, artifacts)
}

fn sensai_basic(
    signal: &[Vec<f64>],
    noise: &[Vec<f64>],
    rate: f64,
    epoch_seconds: f64,
    ref_cov: &DMatrix<f64>,
    noise_mult: f64,
) -> Option<f64> {
    let n = signal.len();
    let epoch = ((rate * epoch_seconds).round() as usize).max(4);
    let epochs = signal[0].len() / epoch;
    if epochs == 0 {
        return None;
    }
    let ref_eig = SymmetricEigen::new(ref_cov.clone());
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by(|a, b| ref_eig.eigenvalues[*a].total_cmp(&ref_eig.eigenvalues[*b]));
    let top = 3.min(n);
    let template = DMatrix::from_fn(n, top, |r, c| {
        ref_eig.eigenvectors[(r, order[n - top + c])]
    });
    let mut sig = Vec::new();
    let mut noi = Vec::new();
    for e in 0..epochs {
        let sm = DMatrix::from_fn(n, epoch, |c, s| signal[c][e * epoch + s]);
        let nm = DMatrix::from_fn(n, epoch, |c, s| noise[c][e * epoch + s]);
        sig.push(subspace_similarity(&covariance(&sm), &template, top));
        noi.push(subspace_similarity(&covariance(&nm), &template, top));
    }
    Some(100.0 * mean(&sig) - noise_mult * 100.0 * mean(&noi))
}

fn subspace_similarity(cov: &DMatrix<f64>, template: &DMatrix<f64>, top: usize) -> f64 {
    let eig = SymmetricEigen::new(cov.clone());
    let n = cov.nrows();
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by(|a, b| eig.eigenvalues[*a].total_cmp(&eig.eigenvalues[*b]));
    let basis = DMatrix::from_fn(n, top, |r, c| {
        eig.eigenvectors[(r, order[n - top + c])]
    });
    let svd = (basis.transpose() * template).svd(false, false);
    svd.singular_values.iter().map(|s| s.clamp(0.0, 1.0)).product()
}

fn optimize_threshold(
    epochs: &[DMatrix<f64>],
    rate: f64,
    epoch_seconds: f64,
    ref_cov: &DMatrix<f64>,
    evals: &[Vec<f64>],
    evecs: &[DMatrix<f64>],
    noise: f64,
) -> f64 {
    let mut f = |t: f64| -> f64 {
        let (clean, art) = clean_eeg(epochs, t, evals, evecs);
        -sensai_basic(&clean, &art, rate, epoch_seconds, ref_cov, noise).unwrap_or(f64::NEG_INFINITY)
    };
    brent_minimize(&mut f, 0.0, 12.0, 1e-3)
}

fn brent_minimize<F: FnMut(f64) -> f64>(f: &mut F, a: f64, b: f64, tol: f64) -> f64 {
    let golden = 0.3819660112501051; // (3 - sqrt(5)) / 2
    let mut ax = a;
    let mut cx = b;
    let mut x = ax + golden * (cx - ax);
    let mut w = x;
    let mut v = w;
    let mut e = 0.0f64;
    
    let mut fx = f(x);
    let mut fw = fx;
    let mut fv = fw;
    
    for _ in 0..100 {
        let m = 0.5 * (ax + cx);
        let tol1 = tol * x.abs() + 1e-8;
        let tol2 = 2.0 * tol1;
        
        if (x - m).abs() <= tol2 - 0.5 * (cx - ax) {
            break;
        }
        
        let mut d = 0.0;
        if e.abs() > tol1 {
            let r = (x - w) * (fx - fv);
            let mut q = (x - v) * (fx - fw);
            let mut p = (x - v) * q - (x - w) * r;
            q = 2.0 * (q - r);
            if q > 0.0 {
                p = -p;
            } else {
                q = -q;
            }
            
            let temp = e;
            e = d;
            
            if p.abs() >= (0.5 * q * temp).abs() || p <= q * (ax - x) || p >= q * (cx - x) {
                e = if x >= m { ax - x } else { cx - x };
                d = golden * e;
            } else {
                d = p / q;
                let u = x + d;
                if u - ax < tol2 || cx - u < tol2 {
                    d = if m - x >= 0.0 { tol1 } else { -tol1 };
                }
            }
        } else {
            e = if x >= m { ax - x } else { cx - x };
            d = golden * e;
        }
        
        let u = if d.abs() >= tol1 {
            x + d
        } else {
            x + if d >= 0.0 { tol1 } else { -tol1 }
        };
        
        let fu = f(u);
        
        if fu <= fx {
            if u >= x { ax = x; } else { cx = x; }
            v = w; fv = fw;
            w = x; fw = fx;
            x = u; fx = fu;
        } else {
            if u < x { ax = u; } else { cx = u; }
            if fu <= fw || w == x {
                v = w; fv = fw;
                w = u; fw = fu;
            } else if fu <= fv || v == x || v == w {
                v = u; fv = fu;
            }
        }
    }
    x
}

fn modwt_mra_all(data: &[Vec<f64>], levels: usize) -> Vec<Vec<Vec<f64>>> {
    let n = data.len();
    let len = data[0].len();
    let mut out = vec![vec![vec![0.0; len]; n]; levels + 1];
    
    for c in 0..n {
        let (w_all, v) = modwt_haar(&data[c], levels);
        let mra = modwtmra_haar(&w_all, &v);
        for b in 0..=levels {
            out[b][c].copy_from_slice(&mra[b]);
        }
    }
    out
}

fn modwt_haar(x: &[f64], levels: usize) -> (Vec<Vec<f64>>, Vec<f64>) {
    let mut v = x.to_vec();
    let mut w_all = Vec::new();
    let n = x.len();
    for j in 1..=levels {
        let step = 1 << (j - 1);
        let mut v_next = vec![0.0; n];
        let mut w_next = vec![0.0; n];
        for t in 0..n {
            let t_minus_step = (t + n - (step % n)) % n;
            v_next[t] = 0.5 * v[t] + 0.5 * v[t_minus_step];
            w_next[t] = 0.5 * v[t] - 0.5 * v[t_minus_step];
        }
        w_all.push(w_next);
        v = v_next;
    }
    (w_all, v)
}

fn modwtmra_haar(w_all: &[Vec<f64>], v: &[f64]) -> Vec<Vec<f64>> {
    let levels = w_all.len();
    let n = v.len();
    let mut mra = Vec::new();
    let zeros = vec![0.0; n];
    
    for j_target in 1..=levels {
        let mut v_curr = vec![0.0; n];
        for j in (1..=levels).rev() {
            let w_curr = if j == j_target { &w_all[j - 1] } else { &zeros };
            v_curr = idwt_step_haar(&v_curr, w_curr, j);
        }
        mra.push(v_curr);
    }
    
    let mut v_curr = v.to_vec();
    for j in (1..=levels).rev() {
        v_curr = idwt_step_haar(&v_curr, &zeros, j);
    }
    mra.push(v_curr);
    
    mra
}

fn idwt_step_haar(v: &[f64], w: &[f64], j: usize) -> Vec<f64> {
    let n = v.len();
    let step = 1 << (j - 1);
    let mut v_prev = vec![0.0; n];
    for t in 0..n {
        let t_plus_step = (t + step) % n;
        v_prev[t] = 0.5 * v[t] + 0.5 * v[t_plus_step] + 0.5 * w[t] - 0.5 * w[t_plus_step];
    }
    v_prev
}

pub fn leadfield_cov(labels: &[String]) -> Option<DMatrix<f64>> {
    #[derive(Deserialize)]
    struct Leadfield {
        labels: Vec<String>,
        gram_matrix_avref: Vec<Vec<f64>>,
    }
    let parsed: Leadfield =
        serde_json::from_str(include_str!("../resources/gedai_leadfield.json")).ok()?;
    let lookup: HashMap<String, usize> = parsed
        .labels
        .iter()
        .enumerate()
        .map(|(i, label)| (label.to_lowercase(), i))
        .collect();
    let idx: Vec<usize> = labels
        .iter()
        .map(|label| lookup.get(&label.to_lowercase()).copied())
        .collect::<Option<Vec<_>>>()?;
    Some(DMatrix::from_fn(labels.len(), labels.len(), |r, c| {
        parsed.gram_matrix_avref[idx[r]][idx[c]]
    }))
}

fn covariance(x: &DMatrix<f64>) -> DMatrix<f64> {
    let n = x.nrows();
    let m = x.ncols();
    let mut centered = x.clone();
    for r in 0..n {
        let row_mean = (0..m).map(|c| x[(r, c)]).sum::<f64>() / m as f64;
        for c in 0..m {
            centered[(r, c)] -= row_mean;
        }
    }
    (&centered * centered.transpose()) / (m.saturating_sub(1).max(1) as f64)
}

fn subtract(a: &[Vec<f64>], b: &[Vec<f64>]) -> Vec<Vec<f64>> {
    a.iter()
        .zip(b)
        .map(|(x, y)| x.iter().zip(y).map(|(u, v)| u - v).collect())
        .collect()
}

fn cosine_weights(n: usize) -> Vec<f64> {
    (1..=n)
        .map(|u| 0.5 - 0.5 * (2.0 * u as f64 * PI / n as f64).cos())
        .collect()
}

fn variance_f32(x: &[f32]) -> f64 {
    let mu = x.iter().map(|v| *v as f64).sum::<f64>() / x.len().max(1) as f64;
    x.iter()
        .map(|v| {
            let d = *v as f64 - mu;
            d * d
        })
        .sum::<f64>()
        / x.len().max(1) as f64
}

fn median(mut x: Vec<f64>) -> f64 {
    if x.is_empty() {
        return 0.0;
    }
    x.sort_by(|a, b| a.total_cmp(b));
    x[x.len() / 2]
}

fn mean(x: &[f64]) -> f64 {
    x.iter().sum::<f64>() / x.len().max(1) as f64
}

fn default_true() -> bool {
    true
}
fn default_target_rate() -> f64 {
    250.0
}
fn default_low() -> f64 {
    0.5
}
fn default_high() -> f64 {
    40.0
}
fn default_notch() -> f64 {
    50.0
}
fn default_epoch() -> f64 {
    1.0
}
fn default_threshold() -> String {
    "auto".into()
}
fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn varied_recording() -> Recording {
        // Six well-behaved channels with comparable variance, one dead channel
        // and one artefact-dominated channel.
        let mut channels: Vec<Vec<f32>> = (0..6)
            .map(|c| {
                (0..200)
                    .map(|i| ((i + c) as f32 * 0.1).sin())
                    .collect::<Vec<f32>>()
            })
            .collect();
        channels.push(vec![0.0; 200]); // dead electrode
        channels.push((0..200).map(|i| (i as f32) * 50.0).collect()); // artefact

        Recording {
            rate: 100.0,
            labels: vec![
                "AF3".into(), "AF4".into(), "Fz".into(), "F3".into(),
                "F4".into(), "T7".into(), "DEAD".into(), "NOISY".into(),
            ],
            channels,
            source_epoch_samples: None,
            epoch_labels: None,
        }
    }

    #[test]
    fn bad_channel_detection_is_data_driven() {
        let bad = detect_bad_channels(&varied_recording());

        // The dead and artefact channels must be caught.
        assert!(bad.contains(&"DEAD".to_string()), "flat channel not detected");
        assert!(bad.contains(&"NOISY".to_string()), "artefact channel not detected");

        // Regression: these seven labels used to be hardcoded as bad on every
        // recording. Healthy channels carrying those names must now pass.
        for label in ["AF4", "Fz", "AF3", "F3", "F4", "T7"] {
            assert!(
                !bad.contains(&label.to_string()),
                "{label} was flagged bad despite healthy data — the hardcoded \
                 bad-channel list has come back"
            );
        }
    }

    #[test]
    fn clean_recording_has_no_bad_channels() {
        let rec = Recording {
            rate: 100.0,
            labels: vec!["AF3".into(), "Fz".into(), "PO4".into()],
            channels: (0..3)
                .map(|c| {
                    (0..200)
                        .map(|i| ((i + c) as f32 * 0.1).sin())
                        .collect::<Vec<f32>>()
                })
                .collect(),
            source_epoch_samples: None,
            epoch_labels: None,
        };
        assert!(
            detect_bad_channels(&rec).is_empty(),
            "a clean recording must yield no bad channels"
        );
    }

    #[test]
    fn explicit_non_eeg_list_drives_channel_normalisation() {
        let mut rec = Recording {
            rate: 100.0,
            labels: vec!["Fp1".into(), "ECG".into(), "FT9".into()],
            channels: vec![vec![1.0; 10], vec![2.0; 10], vec![3.0; 10]],
            source_epoch_samples: None,
            epoch_labels: None,
        };
        normalize_channel_set(&mut rec, &["ECG".to_string()]);
        assert_eq!(rec.labels, vec!["Fp1", "FT9"]);
        assert_eq!(rec.channels.len(), 2);
    }

    #[test]
    fn portable_roundtrip() {
        let mut rec = Recording {
            rate: 100.0,
            labels: vec!["Fz".into(), "Cz".into(), "Pz".into(), "Oz".into()],
            channels: vec![vec![0.0; 100]; 4],
            source_epoch_samples: None,
            epoch_labels: None,
        };
        for s in 0..100 {
            rec.channels[0][s] = (2.0 * PI * 10.0 * s as f64 / 100.0).sin() as f32;
        }
        let path = "/tmp/ccs_preprocess_roundtrip.ccseeg.json";
        save_portable(path, &rec).unwrap();
        let loaded = load_portable(Path::new(path)).unwrap();
        assert_eq!(loaded.labels.len(), 4);
        assert_eq!(loaded.channels[0].len(), 100);
    }

    #[test]
    fn gedai_runs_on_synthetic_data() {
        let labels = vec!["Fz".into(), "Cz".into(), "Pz".into(), "Oz".into()];
        let rate = 100.0;
        let mut ch = vec![vec![0.0f64; 400]; 4];
        for s in 0..400 {
            for c in 0..4 {
                ch[c][s] = (2.0 * PI * (8.0 + c as f64) * s as f64 / rate).sin()
                    + if s > 100 && s < 120 { 8.0 } else { 0.0 };
            }
        }
        let result = gedai(&mut ch, rate, &labels, 1.0, "auto").unwrap();
        assert_eq!(result.clean.len(), 4);
        assert!(result.score.is_finite());
    }
}
