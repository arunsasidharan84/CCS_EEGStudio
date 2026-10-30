use nalgebra::{DMatrix, SymmetricEigen};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, f64::consts::PI, fs, io::Write, path::Path};

use crate::eeg::{spectral::resample_poly, Recording};
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
    #[serde(default="default_bad_variance_ratio")]
    pub bad_variance_ratio:f64,
    #[serde(default="default_spline_stiffness")]
    pub spline_stiffness:i32,
    #[serde(default="default_spline_regularization")]
    pub spline_regularization:f64,
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
    pub reference_mode: String,
    #[serde(default)]
    pub reference_channels: Vec<String>,
    #[serde(default)]
    pub fir_taps: usize,
    #[serde(default="default_filter_type")]
    pub filter_type: String,
    #[serde(default="default_iir_order")]
    pub iir_order: usize,
    #[serde(default = "default_notch_width")]
    pub notch_width_hz: f64,
    #[serde(default = "default_notch_transition")]
    pub notch_transition_hz: f64,
    #[serde(default = "default_source_snr")]
    pub source_snr: f64,
    #[serde(default)]
    pub source_method: String,
    #[serde(default)]
    pub source_model_path: String,
    #[serde(default)]
    pub source_regions: Vec<String>,
    #[serde(default)]
    pub epoch_before_gedai: bool,
    #[serde(default)]
    pub epoch_length_seconds: Option<f64>,
    /// Explicit non-EEG channel labels resolved by the UI.  Empty means "use
    /// the built-in `is_eeg_label` heuristic".
    #[serde(default)]
    pub non_eeg_channels: Vec<String>,
    /// Stimulus-locked epoching (ERP). When set, the continuous recording is
    /// downsampled and filtered first, then cut into epochs around these
    /// events, and bad-channel detection / GEDAI / interpolation run on the
    /// epochs (GEDAI uses one trial per window).
    #[serde(default)]
    pub stim_epochs: Option<StimEpochOptions>,
    /// ICA-based cleaning ("none" | "runica" | "picard"), run *before* ASR / GEDAI.  Blink-locked ICA stage plus a
    /// second ICA stage; components are classified with ICLabel (parity-validated against EEGLAB/MATLAB).
    #[serde(default)]
    pub ica_method: String,
    #[serde(default = "default_true")]
    pub ica_blink: bool,
    #[serde(default = "default_true")]
    pub ica_other: bool,
    /// Eye channel used to detect blinks (empty = Fp1/Fp2/AFz/Fz/F7/F8/AF3/AF4, else first channel).
    #[serde(default)]
    pub ica_eye_channel: String,
    #[serde(default = "default_ica_blink_epochs")]
    pub ica_blink_epochs: usize,
    #[serde(default = "default_ica_blink_hi")]
    pub ica_blink_threshold: f64,
    #[serde(default = "default_ica_blink_lo")]
    pub ica_blink_threshold_floor: f64,
    #[serde(default = "default_true")]
    pub ica_remove_ecg: bool,
    /// ICLabel classes removed by the second stage (empty = Muscle, Line Noise, Channel Noise).
    #[serde(default)]
    pub ica_artefacts: Vec<String>,
    #[serde(default = "default_ica_other_hi")]
    pub ica_other_threshold: f64,
    #[serde(default = "default_ica_other_lo")]
    pub ica_other_threshold_floor: f64,
    /// ASR burst rejection applied to the ICA fit data (as `pop_clean_rawdata` in the MATLAB pipeline).
    #[serde(default = "default_true")]
    pub ica_fit_asr: bool,
    /// ASR burst cutoff of the ICA fit copy (`ica2_BurstCriterion`, pipeline default 15).
    #[serde(default = "default_ica_fit_cutoff")]
    pub ica_fit_asr_cutoff: f64,
    #[serde(default = "default_ica_seed")]
    pub ica_seed: u32,
    /// Artifact Subspace Reconstruction ("off" | "correct" | "reject"), after ICA when both are enabled.
    #[serde(default)]
    pub asr_mode: String,
    #[serde(default = "default_asr_cutoff")]
    pub asr_cutoff: f64,
    /// ASR flavour: "" / "standard" | "riemannian" | "adaptive" | "juggler_dbscan" | "juggler_gev" | "easr" | "vmd" | "emd".
    /// Standard and riemannian are ports of clean_rawdata (MATLAB-validated); the others are documented interpretations.
    #[serde(default)]
    pub asr_variant: String,
    #[serde(default = "default_adapt_alpha")]
    pub asr_adapt_alpha: f64,
    #[serde(default = "default_adapt_block")]
    pub asr_adapt_block_seconds: f64,
    #[serde(default = "default_embed_dim")]
    pub asr_embed_dim: usize,
    #[serde(default = "default_embed_tau")]
    pub asr_embed_tau: usize,
    #[serde(default = "default_n_modes")]
    pub asr_modes: usize,
    #[serde(default = "default_dbscan_topk")]
    pub asr_dbscan_top_k: usize,
    /// Non-ASR muscle / motion cleaner run after ICA and before ASR: "" | "bss_cca" | "icanclean" | "wica".
    #[serde(default)]
    pub muscle_method: String,
    /// BSS-CCA: number of lowest-autocorrelation sources removed (0 = use `bsscca_rho`).
    #[serde(default = "default_bsscca_n")]
    pub bsscca_n_remove: usize,
    #[serde(default)]
    pub bsscca_rho: f64,
    #[serde(default = "default_icc_threshold")]
    pub icc_threshold: f64,
    #[serde(default = "default_icc_segment")]
    pub icc_segment_seconds: f64,
    #[serde(default = "default_icc_lo")]
    pub icc_stop_low_hz: f64,
    #[serde(default = "default_icc_hi")]
    pub icc_stop_high_hz: f64,
    #[serde(default = "default_wica_levels")]
    pub wica_levels: usize,
    #[serde(default = "default_wica_mult")]
    pub wica_threshold_mult: f64,
}

#[derive(Deserialize, Clone, Default, Debug)]
pub struct StimEpochOptions {
    /// Event onsets in seconds from the start of the recording.
    pub onsets: Vec<f64>,
    /// Event label per onset (e.g. "Stimulus/S 51"); becomes epoch_labels.
    pub labels: Vec<String>,
    /// Epoch start / end relative to the event, seconds (MNE: tmax inclusive).
    pub tmin: f64,
    pub tmax: f64,
    /// Optional per-epoch baseline correction window (seconds).
    #[serde(default)]
    pub baseline: Option<[f64; 2]>,
}

/// Epoch timing written next to the data so analyses know the time axis.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct EpochMeta {
    pub epoch_tmin: f64,
    pub epoch_tmax: f64,
    #[serde(default)]
    pub epoch_baseline: Option<[f64; 2]>,
    #[serde(default)]
    pub epoch_onsets: Vec<f64>,
    #[serde(default)]
    pub epochs_dropped: usize,
}

/// Cuts stimulus-locked epochs (MNE semantics: samples round(tmin*rate) ..=
/// round(tmax*rate) around round(onset*rate); epochs running past either end
/// are dropped). Returns the concatenated epochs, labels, samples per epoch
/// and the timing metadata.
pub fn cut_stim_epochs(
    data: &[Vec<f64>],
    rate: f64,
    stim: &StimEpochOptions,
) -> Result<(Vec<Vec<f64>>, Vec<String>, usize, EpochMeta), String> {
    if !(stim.tmax > stim.tmin) {
        return Err(format!("epoch tmax ({}) must be after tmin ({})", stim.tmax, stim.tmin));
    }
    let len = data.first().map(Vec::len).unwrap_or(0);
    let start_off = (stim.tmin * rate).round() as i64;
    let stop_off = (stim.tmax * rate).round() as i64;
    let n = (stop_off - start_off + 1) as usize;
    let times: Vec<f64> = (0..n).map(|k| (start_off + k as i64) as f64 / rate).collect();
    let base_idx: Vec<usize> = match stim.baseline {
        Some([b0, b1]) => (0..n)
            .filter(|&k| times[k] >= b0 - 1e-9 && times[k] <= b1 + 1e-9)
            .collect(),
        None => Vec::new(),
    };
    let mut out = vec![Vec::with_capacity(n * stim.onsets.len()); data.len()];
    let mut labels = Vec::new();
    let mut onsets = Vec::new();
    let mut dropped = 0usize;
    for (i, onset) in stim.onsets.iter().enumerate() {
        let ev = (onset * rate).round() as i64;
        let a = ev + start_off;
        if a < 0 || (a as usize) + n > len {
            dropped += 1;
            continue;
        }
        let a = a as usize;
        for (c, ch) in data.iter().enumerate() {
            let seg = &ch[a..a + n];
            let bm = if base_idx.is_empty() {
                0.0
            } else {
                base_idx.iter().map(|&k| seg[k]).sum::<f64>() / base_idx.len() as f64
            };
            out[c].extend(seg.iter().map(|v| v - bm));
        }
        labels.push(stim.labels.get(i).cloned().unwrap_or_else(|| format!("Event {}", i + 1)));
        onsets.push(*onset);
    }
    if labels.len() < 2 {
        return Err(format!(
            "only {} stimulus epoch(s) fit inside the recording ({} events, {} dropped at the edges)",
            labels.len(),
            stim.onsets.len(),
            dropped
        ));
    }
    let meta = EpochMeta {
        epoch_tmin: start_off as f64 / rate,
        epoch_tmax: stop_off as f64 / rate,
        epoch_baseline: stim.baseline,
        epoch_onsets: onsets,
        epochs_dropped: dropped,
    };
    Ok((out, labels, n, meta))
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
    /// ICA / ASR report (components removed, ICLabel classes, ASR samples changed ...); `null` when neither ran.
    pub ica: Option<serde_json::Value>,
    /// GEDAI reference actually used: "leadfield", "identity" (labels unknown: not valid GEDAI) or null when GEDAI did not run.
    pub gedai_reference: Option<String>,
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
    #[serde(flatten)]
    pub epoch_meta: Option<EpochMeta>,
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
    if !["fir","iir"].contains(&options.filter_type.as_str()) { return Err("Filter type must be fir or iir".into()); }
    if options.iir_order < 2 || options.iir_order > 12 || options.iir_order % 2 != 0 { return Err("IIR order must be even, from 2 to 12".into()); }
    if !options.source_snr.is_finite() || options.source_snr<=0.0 { return Err("Source SNR must be positive".into()); }
    if !options.notch_width_hz.is_finite() || options.notch_width_hz<=0.0 || !options.notch_transition_hz.is_finite() || options.notch_transition_hz<=0.0 { return Err("Notch widths must be positive".into()); }
    if !options.bad_variance_ratio.is_finite() || options.bad_variance_ratio<2.0 || options.spline_stiffness<2 || options.spline_stiffness>8 || !options.spline_regularization.is_finite() || options.spline_regularization<=0.0 {return Err("Invalid bad-channel or interpolation parameters".into());}
    if !["", "none", "runica", "picard"].contains(&options.ica_method.as_str()) { return Err("ICA method must be none, runica or picard".into()); }
    if !["", "off", "correct", "reject"].contains(&options.asr_mode.as_str()) { return Err("ASR mode must be off, correct or reject".into()); }
    if !["", "standard", "riemannian", "adaptive", "juggler_dbscan", "juggler_gev", "easr", "vmd", "emd"].contains(&options.asr_variant.as_str()) { return Err("ASR variant must be standard, riemannian, adaptive, juggler_dbscan, juggler_gev, easr, vmd or emd".into()); }
    if !["", "none", "bss_cca", "icanclean", "wica"].contains(&options.muscle_method.as_str()) { return Err("Muscle method must be none, bss_cca, icanclean or wica".into()); }
    if !(0.0..=1.0).contains(&options.asr_adapt_alpha) { return Err("ASR adaptation rate must be between 0 and 1".into()); }
    if options.asr_adapt_block_seconds < 0.5 || options.asr_adapt_block_seconds > 60.0 { return Err("ASR adaptation block must be 0.5-60 s".into()); }
    if options.asr_embed_dim < 2 || options.asr_embed_dim > 32 || options.asr_embed_tau < 1 || options.asr_embed_tau > 50 { return Err("E-ASR embedding dimension must be 2-32 and delay 1-50 samples".into()); }
    if options.asr_modes < 2 || options.asr_modes > 12 { return Err("VMD/EMD mode count must be 2-12".into()); }
    if options.asr_dbscan_top_k < 1 || options.asr_dbscan_top_k > 32 { return Err("DBSCAN feature count must be 1-32".into()); }
    if options.icc_threshold <= 0.0 || options.icc_threshold >= 1.0 || options.icc_segment_seconds < 0.5 || options.icc_stop_low_hz <= 0.0 || options.icc_stop_high_hz <= options.icc_stop_low_hz { return Err("iCanClean: R² threshold must be in (0,1), segment >= 0.5 s and a valid stop band".into()); }
    if options.muscle_method == "bss_cca" && options.bsscca_n_remove == 0 && !(options.bsscca_rho > 0.0 && options.bsscca_rho < 1.0) { return Err("BSS-CCA needs a number of sources to remove or a correlation threshold in (0,1)".into()); }
    if options.wica_levels < 1 || options.wica_levels > 12 || options.wica_threshold_mult <= 0.0 { return Err("wICA: levels must be 1-12 and the threshold multiplier positive".into()); }
    if !options.asr_cutoff.is_finite() || options.asr_cutoff < 1.0 || options.asr_cutoff > 200.0 { return Err("ASR cutoff must be between 1 and 200".into()); }
    if !options.ica_fit_asr_cutoff.is_finite() || options.ica_fit_asr_cutoff < 1.0 || options.ica_fit_asr_cutoff > 200.0 { return Err("ICA fit ASR cutoff must be between 1 and 200".into()); }
    if !(options.ica_blink_threshold <= 1.0 && options.ica_blink_threshold_floor > 0.0 && options.ica_other_threshold <= 1.0 && options.ica_other_threshold_floor > 0.0) { return Err("ICLabel thresholds must be in (0, 1]".into()); }
    if options.asr_mode == "reject" && options.stim_epochs.as_ref().is_some_and(|s| !s.onsets.is_empty()) {
        return Err("ASR reject removes time samples and cannot precede event-locked epoching; use ASR correct to preserve event timing".into());
    }
    let mut warnings = Vec::new();
    let mut ica_report: Option<serde_json::Value> = None;
    normalize_channel_set(rec, &options.non_eeg_channels);

    eprintln!("PROGRESS 10 Converting channels to f64...");
    // Convert to f64 for all processing in parallel
    let mut f64_channels: Vec<Vec<f64>> = rec
        .channels
        .par_iter()
        .map(|ch| ch.iter().map(|v| *v as f64).collect())
        .collect();

    if options.downsample && (options.downsample_freq - rec.rate).abs() > 0.5 && options.downsample_freq > 0.0 {
        eprintln!(
            "PROGRESS 30 Downsampling from {} Hz to {} Hz...",
            rec.rate, options.downsample_freq
        );
        // Represent the rates in millihertz before forming the rational ratio.
        // Multiplying by target/source and rounding each side independently
        // changes the ratio (256 -> 250 became 244/250), causing event drift.
        let scale = 1000.0;
        let up = (options.downsample_freq * scale).round().max(1.0) as usize;
        let down = (rec.rate * scale).round().max(1.0) as usize;
        let output_rate = rec.rate * up as f64 / down as f64;
        let pts_per_epoch = rec.source_epoch_samples;
        f64_channels.par_iter_mut().for_each(|ch| {
            if let Some(pts) = pts_per_epoch {
                if pts > 0 && ch.len() >= pts {
                    let mut resampled = Vec::with_capacity(
                        (ch.len() as f64 * (options.downsample_freq / rec.rate)) as usize + 100,
                    );
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
            rec.source_epoch_samples =
                Some((pts * up).div_ceil(down));
        }
        // Label the samples with their actual generated rate, including when
        // an unusual requested rate is rounded to millihertz precision.
        rec.rate = output_rate;
    }
    if options.filter {
        eprintln!("PROGRESS 40 Applying {} bandpass / FIR notch filters...",options.filter_type);
        let rate = rec.rate;
        let low = options.low_hz;
        let high = options.high_hz;
        let notch = options.notch_hz;
        let pts_per_epoch = rec.source_epoch_samples;
        f64_channels.par_iter_mut().for_each(|ch| {
            if let Some(pts) = pts_per_epoch {
                if pts > 0 && ch.len() >= pts {
                    for chunk in ch.chunks_mut(pts) {
                        apply_bandpass(chunk, rate, low, high, options);
                        if notch > 0.0 {
                            fir_notch_custom(chunk, rate, notch, options.notch_width_hz, options.notch_transition_hz);
                        }
                    }
                    return;
                }
            }
            apply_bandpass(ch, rate, low, high, options);
            if notch > 0.0 {
                fir_notch_custom(ch, rate, notch, options.notch_width_hz, options.notch_transition_hz);
            }
        });
    }

    let bad_channels = if options.badchannel {
        detect_bad_channels_configured(rec,options.bad_variance_ratio)
    } else {
        Vec::new()
    };
    let ica_on = matches!(options.ica_method.as_str(), "runica" | "picard");
    let asr_on = matches!(options.asr_mode.as_str(), "correct" | "reject");
    let muscle_on = matches!(options.muscle_method.as_str(), "bss_cca" | "icanclean" | "wica");
    if ica_on || asr_on || muscle_on {
        {
            let mut trial_options = options.clone();
            if rec.source_epoch_samples.is_some() {
                trial_options.asr_mode = "off".into();
                trial_options.muscle_method = "none".into();
                if asr_on || muscle_on { warnings.push("Standalone ASR / muscle cleaning skipped for epoched input; ICA keeps trial boundaries and uses ASR only on its training copy".into()); }
            }
            match run_ica_asr(&mut f64_channels, rec.rate, &rec.labels, &bad_channels, &trial_options, rec.source_epoch_samples, &mut warnings) {
                Ok((report, keep_mask)) => {
                    if let Some(mask) = keep_mask {
                        for ch in f64_channels.iter_mut() {
                            let kept: Vec<f64> = ch.iter().zip(mask.iter()).filter(|(_, &k)| k).map(|(v, _)| *v).collect();
                            *ch = kept;
                        }
                    }
                    ica_report = Some(report);
                }
                Err(e) => warnings.push(format!("ICA/ASR skipped: {e}")),
            }
        }
    }
    let mut epoch_meta: Option<EpochMeta> = None;
    if let Some(stim) = options.stim_epochs.as_ref().filter(|s| !s.onsets.is_empty()) {
        if rec.source_epoch_samples.is_some() {
            warnings.push("input is already epoched; stimulus epoching skipped".into());
        } else {
            let (epochs, labels, n, meta) = cut_stim_epochs(&f64_channels, rec.rate, stim)?;
            eprintln!(
                "PROGRESS 53 Cut {} stimulus-locked epochs ({} samples, {:.3}..{:.3} s){}",
                labels.len(),
                n,
                meta.epoch_tmin,
                meta.epoch_tmax,
                if meta.epochs_dropped > 0 {
                    format!(", {} dropped at the recording edges", meta.epochs_dropped)
                } else {
                    String::new()
                }
            );
            if meta.epochs_dropped > 0 {
                warnings.push(format!(
                    "{} event(s) too close to the recording edges were dropped",
                    meta.epochs_dropped
                ));
            }
            f64_channels = epochs;
            rec.source_epoch_samples = Some(n);
            rec.epoch_labels = Some(labels);
            epoch_meta = Some(meta);
        }
    }

    // Already-epoched data (stimulus epochs, -epo.fif, epoched .set) keeps its
    // own epochs: re-chunking would break the trial alignment and labels.
    if rec.source_epoch_samples.is_none()
        && (options.epoch_before_gedai || options.epoch_length_seconds.is_some())
    {
        let sec = options
            .epoch_length_seconds
            .unwrap_or(options.gedai_epoch_seconds);
        if sec > 0.0 {
            let pts = (rec.rate * sec).round() as usize;
            if pts > 0 && f64_channels.first().map(|c| c.len()).unwrap_or(0) >= pts {
                let total_pts = f64_channels[0].len();
                let valid_pts = (total_pts / pts) * pts;
                for ch in &mut f64_channels {
                    ch.truncate(valid_pts);
                }
                rec.source_epoch_samples = Some(pts);
                eprintln!("PROGRESS 54 Epoched continuous recording into {} epochs of {} samples before GEDAI", valid_pts / pts, pts);
            }
        }
    }
    let mut sensai_score = None;
    let mut gedai_reference = "";
    let mut thresholds = Vec::new();
    if options.gedai && rec.channels.len() >= 4 {
        // Epoched data: one epoch per GEDAI window, and the data are padded to
        // whole windows (then trimmed back) so no trial is cut off.
        let orig_len = f64_channels.first().map(Vec::len).unwrap_or(0);
        let epoched = rec
            .source_epoch_samples
            .filter(|&n| n >= 4 && orig_len / n >= 2);
        let gedai_seconds = epoched
            .map(|n| n as f64 / rec.rate)
            .unwrap_or(options.gedai_epoch_seconds);
        if epoched.is_some() {
            let win = ((rec.rate * gedai_seconds).round() as usize).max(4);
            let win = if win % 2 == 0 { win } else { win + 1 };
            let padded = ((orig_len + win - 1) / win).max(2) * win;
            if padded > orig_len {
                for ch in &mut f64_channels {
                    ch.resize(padded, 0.0);
                }
            }
            eprintln!(
                "PROGRESS 55 GEDAI on {} epochs ({} samples per window)",
                orig_len / epoched.unwrap(),
                win
            );
        }
        match gedai(
            &mut f64_channels,
            rec.rate,
            &rec.labels,
            gedai_seconds,
            &options.gedai_threshold,
        ) {
            Ok(result) => {
                let missing = leadfield_missing_labels(&rec.labels);
                if !missing.is_empty() {
                    gedai_reference = "identity";
                    warnings.push(format!(
                        "GEDAI ran WITHOUT its leadfield reference: {} of {} channel labels are not in the built-in 10-05 leadfield ({}). \
                         An identity reference covariance was used, so the spatial prior is lost and the output is NOT valid GEDAI cleaning. \
                         Use standard 10-05 electrode names, or use ASR / ICA instead.",
                        missing.len(), rec.labels.len(), missing.join(", ")
                    ));
                } else {
                    gedai_reference = "leadfield";
                }
                let len = result.clean.first().map(Vec::len).unwrap_or(0);
                let len = if epoched.is_some() { orig_len.min(len) } else { len };
                f64_channels = result.clean;
                for ch in &mut f64_channels {
                    ch.truncate(len);
                }
                sensai_score = Some(result.score);
                thresholds = result.thresholds;
            }
            Err(err) => {
                for ch in &mut f64_channels {
                    ch.truncate(orig_len);
                }
                warnings.push(format!("GEDAI skipped: {err}"))
            }
        }
    }
    if options.interpolate && !bad_channels.is_empty() {
        interpolate_bad_channels(&mut f64_channels, &rec.labels, &bad_channels,options.spline_stiffness,options.spline_regularization);
    }

    apply_output_reference(&mut f64_channels, &rec.labels, &options.reference_mode, &options.reference_channels)?;
    let mut source_localized = false;
    if options.source_localization {
        eprintln!("PROGRESS 85 Converting to source space (selected inverse and atlas)...");
        match crate::eeg::source_loc::convert_with_model(&f64_channels, &rec.labels, options.source_snr, if options.source_method.is_empty(){"mne"}else{&options.source_method}, &options.source_model_path) {
            Ok((roi_data, roi_labels)) => {
                if options.source_regions.is_empty() {
                    f64_channels = roi_data;
                    rec.labels = roi_labels;
                } else {
                    let indices: Vec<usize> = options.source_regions.iter().map(|name| roi_labels.iter().position(|label| label.eq_ignore_ascii_case(name)).ok_or_else(|| format!("Unknown source region: {name}"))).collect::<Result<_,_>>()?;
                    f64_channels = indices.iter().map(|i| roi_data[*i].clone()).collect();
                    rec.labels = indices.iter().map(|i| roi_labels[*i].clone()).collect();
                }
                source_localized = true;
            }
            Err(e) => return Err(format!("Source localization failed: {e}")),
        }
    }

    // Copy back to f32 in parallel
    eprintln!("PROGRESS 88 Copying back to f32...");
    rec.channels = f64_channels
        .par_iter()
        .map(|ch| ch.iter().map(|v| *v as f32).collect())
        .collect();

    eprintln!("PROGRESS 90 Writing buffered recording transfer to {}...", output);
    save_portable_with(output, rec, epoch_meta)?;
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
        ica: ica_report,
        gedai_reference: if gedai_reference.is_empty() { None } else { Some(gedai_reference.to_string()) },
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
    save_portable_with(path, rec, None)
}

fn save_portable_with(path: &str, rec: &Recording, epoch_meta: Option<EpochMeta>) -> Result<(), String> {
    #[derive(Serialize)]
    struct PortableRef<'a> {
        format: &'static str,
        sample_rate: f64,
        labels: &'a [String],
        channels: &'a [Vec<f32>],
        source_epoch_samples: Option<usize>,
        epoch_labels: &'a Option<Vec<String>>,
        #[serde(flatten)]
        epoch_meta: Option<EpochMeta>,
    }
    let portable = PortableRef {
        epoch_meta, format: "ccseeg-v1", sample_rate: rec.rate,
        labels: &rec.labels, channels: &rec.channels,
        source_epoch_samples: rec.source_epoch_samples, epoch_labels: &rec.epoch_labels,
    };
    let file = fs::File::create(path).map_err(err)?;
    let mut writer = std::io::BufWriter::with_capacity(1024 * 1024, file);
    serde_json::to_writer(&mut writer, &portable).map_err(err)?;
    writer.write_all(b"\n").map_err(err)?;
    writer.flush().map_err(err)
}

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
    ![
        "GSR", "ECG", "EOG", "EMG", "RESP", "X_DIR", "Y_DIR", "Z_DIR", "STATUS", "MARK",
    ]
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

fn apply_bandpass(x:&mut [f64],rate:f64,low:f64,high:f64,options:&PreprocessOptions) {
    if options.filter_type=="fir" { fir_bandpass_custom(x,rate,low,high,options.fir_taps); return; }
    for highpass in [true,false] {
      let cutoff=if highpass {low}else{high};
      if cutoff<=0.0 || cutoff>=rate/2.0 {continue;}
      for section in 0..options.iir_order/2 {
        let q=1.0/(2.0*((2*section+1) as f64*PI/(2*options.iir_order) as f64).cos());
        let omega=2.0*PI*cutoff/rate; let cosine=omega.cos(); let alpha=omega.sin()/(2.0*q); let a0=1.0+alpha;
        let b0=if highpass {(1.0+cosine)/2.0}else{(1.0-cosine)/2.0};
        let b1=if highpass {-(1.0+cosine)}else{1.0-cosine};
        biquad_zero_phase(x,[b0/a0,b1/a0,b0/a0],[-2.0*cosine/a0,(1.0-alpha)/a0]);
      }
    }
}
fn biquad_zero_phase(x:&mut [f64],b:[f64;3],a:[f64;2]) {
    if x.len()<3 {return;}
    let pad=12.min(x.len()-1);
    let mut values=Vec::with_capacity(x.len()+2*pad);
    for i in (1..=pad).rev(){values.push(2.0*x[0]-x[i]);}
    values.extend_from_slice(x);
    for i in 1..=pad {values.push(2.0*x[x.len()-1]-x[x.len()-1-i]);}
    for _ in 0..2 {
      let initial=values[0]; let gain=(b[0]+b[1]+b[2])/(1.0+a[0]+a[1]);
      let mut z1=(gain-b[0])*initial; let mut z2=(b[2]-a[1]*gain)*initial;
      for v in &mut values {let input=*v; let output=b[0]*input+z1; z1=b[1]*input-a[0]*output+z2; z2=b[2]*input-a[1]*output; *v=output;}
      values.reverse();
    }
    x.copy_from_slice(&values[pad..pad+x.len()]);
}

fn fir_bandpass(x: &mut [f64], rate: f64, low: f64, high: f64) {
    fir_bandpass_custom(x,rate,low,high,0)
}
fn fir_bandpass_custom(x: &mut [f64], rate: f64, low: f64, high: f64, taps: usize) {
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
    let len = if taps == 0 { mne_filter_len(rate, trans) } else { taps.max(3) | 1 };

    let kernel = match (low > 0.0, high > 0.0 && high < rate / 2.0) {
        (true, true) => fir_bandpass_kernel(rate, low_cutoff, high_cutoff, len),
        (true, false) => fir_highpass_kernel(rate, low_cutoff, len),
        (false, true) => fir_lowpass_kernel(rate, high_cutoff, len),
        (false, false) => return,
    };
    apply_centered_fir(x, &kernel);
}

fn fir_notch(x: &mut [f64], rate: f64, freq: f64) {
    fir_notch_custom(x,rate,freq,1.0,2.0)
}
fn fir_notch_custom(x: &mut [f64], rate: f64, freq: f64, width: f64, trans: f64) {
    if x.is_empty() || freq <= 0.0 || freq >= rate / 2.0 {
        return;
    }
    let width = width.max(0.1);
    let trans = trans.max(0.1);

    // For bandstop, MNE sets transition band 0.5 Hz by default
    let low_cutoff = (freq - width / 2.0) - trans / 2.0;
    let high_cutoff = (freq + width / 2.0) + trans / 2.0;

    let mut kernel =
        fir_bandpass_kernel(rate, low_cutoff, high_cutoff, mne_filter_len(rate, trans));
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

#[cfg(test)]
fn detect_bad_channels(rec:&Recording)->Vec<String>{detect_bad_channels_configured(rec,25.0)}
fn detect_bad_channels_configured(rec: &Recording, variance_ratio:f64) -> Vec<String> {
    let mut bad_chs: Vec<String> = Vec::new();

    let vars: Vec<f64> = rec.channels.iter().map(|ch| variance_f32(ch)).collect();
    let med = median(vars.clone());
    for (i, var) in vars.iter().enumerate() {
        if *var < 1e-18 || *var > med * variance_ratio {
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

fn interpolate_bad_channels(channels: &mut [Vec<f64>], labels: &[String], bad: &[String],stiffness:i32,regularization:f64) {
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
    use crate::eeg::montage::STANDARD_1005_POS;
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
    let w = crate::eeg::ransac::make_interpolation_matrix_configured(&pos_good, &pos_bad,stiffness,regularization);

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
    eprintln!("PROGRESS 56 GEDAI: computing broadband spatial separation...");
    let (broad, _, broad_score, broad_threshold) =
        gedai_per_band(&data, rate, epoch_seconds, &ref_cov, threshold_type, true)?;
    eprintln!("PROGRESS 60 GEDAI: decomposing signal into MODWT MRA bands...");
    let bands = modwt_mra_all(&broad, 3);
    let exclude = (600.0 / rate).ceil() as usize;
    let process_bands = bands.len().saturating_sub(exclude).max(1).min(bands.len());
    let mut clean_sum = vec![vec![0.0; broad[0].len()]; n];
    let mut thresholds = vec![broad_threshold];
    for (i, band) in bands.iter().take(process_bands).enumerate() {
        let pct = 60 + (15 * (i + 1) / process_bands);
        eprintln!(
            "PROGRESS {} GEDAI: cleaning MRA frequency band {}/{}...",
            pct,
            i + 1,
            process_bands
        );
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
            optimize_threshold(
                &stream1,
                rate,
                epoch_seconds,
                ref_cov,
                &evals1,
                &evecs1,
                noise,
            )
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
    let artifacts = subtract(
        &data.iter().map(|ch| ch[..len].to_vec()).collect::<Vec<_>>(),
        &clean1,
    );
    let score = sensai_basic(&clean1, &artifacts, rate, epoch_seconds, ref_cov, 1.0).unwrap_or(0.0);
    Ok((clean1, art1, score, threshold))
}

fn epoch_view(data: &[Vec<f64>], offset: usize, epoch: usize, epochs: usize) -> Vec<DMatrix<f64>> {
    (0..epochs)
        .map(|e| DMatrix::from_fn(data.len(), epoch, |c, s| data[c][offset + e * epoch + s]))
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
    let chol = b
        .cholesky()
        .ok_or("reference covariance is not positive definite")?;
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
    let threshold_exp = if log_vals.is_empty() {f64::INFINITY} else {
        let idx = ((log_vals.len() as f64) * 0.95).floor() as usize;
        let t1 = (105.0-threshold)/100.0;
        (t1*log_vals[idx.min(log_vals.len()-1)]-100.0).exp()
    };
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
    let template = DMatrix::from_fn(n, top, |r, c| ref_eig.eigenvectors[(r, order[n - top + c])]);
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
    let basis = DMatrix::from_fn(n, top, |r, c| eig.eigenvectors[(r, order[n - top + c])]);
    let svd = (basis.transpose() * template).svd(false, false);
    svd.singular_values
        .iter()
        .map(|s| s.clamp(0.0, 1.0))
        .product()
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
        -sensai_basic(&clean, &art, rate, epoch_seconds, ref_cov, noise)
            .unwrap_or(f64::NEG_INFINITY)
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
            if u >= x {
                ax = x;
            } else {
                cx = x;
            }
            v = w;
            fv = fw;
            w = x;
            fw = fx;
            x = u;
            fx = fu;
        } else {
            if u < x {
                ax = u;
            } else {
                cx = u;
            }
            if fu <= fw || w == x {
                v = w;
                fv = fw;
                w = u;
                fw = fu;
            } else if fu <= fv || v == x || v == w {
                v = u;
                fv = fu;
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

/// Channel labels that are not present in the built-in GEDAI leadfield (empty = full leadfield reference available).
pub fn leadfield_missing_labels(labels: &[String]) -> Vec<String> {
    #[derive(Deserialize)]
    struct Leadfield {
        labels: Vec<String>,
    }
    let Ok(parsed) = serde_json::from_str::<Leadfield>(include_str!("../resources/gedai_leadfield.json")) else {
        return labels.to_vec();
    };
    let known: std::collections::HashSet<String> = parsed.labels.iter().map(|l| l.to_lowercase()).collect();
    labels.iter().filter(|l| !known.contains(&l.to_lowercase())).cloned().collect()
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

fn default_bad_variance_ratio()->f64 {25.0}
fn default_spline_stiffness()->i32 {4}
fn default_spline_regularization()->f64 {1e-5}
fn default_filter_type()->String {"fir".into()}
fn default_iir_order()->usize {4}
fn default_notch_width() -> f64 { 1.0 }
fn default_notch_transition() -> f64 { 2.0 }
fn default_source_snr() -> f64 { 3.0 }

pub fn apply_output_reference(data: &mut [Vec<f64>], labels: &[String], mode: &str, channels: &[String]) -> Result<(),String> {
    if mode.is_empty() || mode == "none" { return Ok(()); }
    let indices: Vec<usize> = match mode {
      "average" => (0..data.len()).collect(),
      "channels" => channels.iter().map(|name| labels.iter().position(|label| label.eq_ignore_ascii_case(name)).ok_or_else(|| format!("Reference channel {name} is not available among EEG channels"))).collect::<Result<_,_>>()?,
      _ => return Err(format!("Unsupported reference mode: {mode}")),
    };
    if indices.is_empty() { return Err("Choose at least one reference channel".into()); }
    for sample in 0..data[0].len() {
      let reference = indices.iter().map(|i| data[*i][sample]).sum::<f64>() / indices.len() as f64;
      for channel in data.iter_mut() { channel[sample] -= reference; }
    }
    Ok(())
}

fn default_ica_blink_epochs() -> usize { 20 }
fn default_ica_fit_cutoff() -> f64 { 15.0 }
fn default_ica_blink_hi() -> f64 { 0.99 }
fn default_ica_blink_lo() -> f64 { 0.60 }
fn default_ica_other_hi() -> f64 { 0.99 }
fn default_ica_other_lo() -> f64 { 0.60 }
fn default_ica_seed() -> u32 { 1 }
fn default_asr_cutoff() -> f64 { 20.0 }
fn default_adapt_alpha() -> f64 { 0.05 }
fn default_adapt_block() -> f64 { 2.0 }
fn default_embed_dim() -> usize { 8 }
fn default_embed_tau() -> usize { 2 }
fn default_n_modes() -> usize { 4 }
fn default_dbscan_topk() -> usize { 5 }
fn default_bsscca_n() -> usize { 3 }
fn default_icc_threshold() -> f64 { 0.7 }
fn default_icc_segment() -> f64 { 2.0 }
fn default_icc_lo() -> f64 { 1.0 }
fn default_icc_hi() -> f64 { 8.0 }
fn default_wica_levels() -> usize { 5 }
fn default_wica_mult() -> f64 { 1.0 }
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

    #[test]
    fn cut_stim_epochs_follows_mne_sample_convention() {
        let rate = 250.0;
        let ch: Vec<f64> = (0..5000).map(|s| s as f64).collect();
        let stim = StimEpochOptions {
            onsets: vec![0.2, 4.0, 10.0, 19.9],
            labels: vec!["S 51".into(), "S 52".into(), "S 51".into(), "S 52".into()],
            tmin: -0.5,
            tmax: 1.2,
            baseline: None,
        };
        let (out, labels, n, meta) = cut_stim_epochs(&[ch.clone(), ch], rate, &stim).unwrap();
        assert_eq!(n, 426); // -125 ..= 300
        assert_eq!(labels, vec!["S 52".to_string(), "S 51".to_string()]); // first + last dropped
        assert_eq!(meta.epochs_dropped, 2);
        assert_eq!(out[0].len(), 2 * 426);
        assert_eq!(out[0][0], 1000.0 - 125.0);
        assert_eq!(out[0][426], 2500.0 - 125.0);
        assert!((meta.epoch_tmin + 0.5).abs() < 1e-12 && (meta.epoch_tmax - 1.2).abs() < 1e-12);
    }

    #[test]
    fn stim_epoch_baseline_is_removed() {
        let ch: Vec<f64> = vec![3.0; 1000];
        let stim = StimEpochOptions {
            onsets: vec![2.0, 5.0],
            labels: vec!["a".into(), "b".into()],
            tmin: -0.2,
            tmax: 0.5,
            baseline: Some([-0.2, 0.0]),
        };
        let (out, _, n, _) = cut_stim_epochs(&[ch], 100.0, &stim).unwrap();
        assert_eq!(n, 71);
        assert!(out[0].iter().all(|v| v.abs() < 1e-12));
    }

    #[test]
    fn stim_epochs_are_cut_before_gedai_and_keep_every_trial() {
        let rate = 100.0;
        let labels: Vec<String> = ["Fz", "Cz", "Pz", "Oz", "C3", "C4", "F3", "F4"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let n = 6000;
        let mut channels = vec![vec![0f32; n]; labels.len()];
        for (c, ch) in channels.iter_mut().enumerate() {
            for (s, v) in ch.iter_mut().enumerate() {
                let t = s as f64 / rate;
                *v = ((t * 7.3 * (c + 1) as f64).sin() * 5.0
                    + (t * 1.1 + c as f64).cos() * 2.0
                    + ((s * 7919 + c * 104729) % 97) as f64 / 97.0) as f32;
            }
        }
        let mut rec = Recording {
            rate,
            labels,
            channels,
            source_epoch_samples: None,
            epoch_labels: None,
        };
        let mut onsets: Vec<f64> = (0..25).map(|i| 1.0 + i as f64 * 2.3).collect();
        onsets.insert(0, 0.2); // too close to the start: dropped
        let ev_labels: Vec<String> = (0..onsets.len())
            .map(|i| if i % 4 == 0 { "Stimulus/S 52".into() } else { "Stimulus/S 51".into() })
            .collect();
        let opts: PreprocessOptions = serde_json::from_value(serde_json::json!({
            "downsample": false, "downsample_freq": 100.0,
            "filter": true, "low_hz": 0.5, "high_hz": 30.0, "notch_hz": 0.0,
            "badchannel": false, "gedai": true, "interpolate": false,
            "epoch_before_gedai": true, "gedai_epoch_seconds": 1.0, "gedai_threshold": "auto",
            "stim_epochs": {"onsets": onsets, "labels": ev_labels,
                            "tmin": -0.5, "tmax": 1.2, "baseline": [-0.2, 0.0]}
        }))
        .unwrap();
        let out = "/tmp/ccs_stim_epochs_test.ccseeg.json";
        run(&mut rec, "synthetic", out, &opts).unwrap();
        assert_eq!(rec.source_epoch_samples, Some(171));
        assert_eq!(rec.epoch_labels.as_ref().unwrap().len(), 25);
        assert_eq!(rec.channels[0].len(), 25 * 171);
        assert!(rec.channels[0].iter().all(|v| v.is_finite()));
        let v: serde_json::Value = serde_json::from_slice(&fs::read(out).unwrap()).unwrap();
        assert_eq!(v["source_epoch_samples"], 171);
        assert!((v["epoch_tmin"].as_f64().unwrap() + 0.5).abs() < 1e-12);
        assert!((v["epoch_tmax"].as_f64().unwrap() - 1.2).abs() < 1e-12);
        assert_eq!(v["epoch_labels"].as_array().unwrap().len(), 25);
        assert_eq!(v["epochs_dropped"], 1);
        let back = load_portable(Path::new(out)).unwrap();
        assert_eq!(back.source_epoch_samples, Some(171));
    }

    #[test]
    fn epoched_input_is_not_rechunked_or_truncated() {
        let rate = 100.0;
        let labels: Vec<String> = ["Fz", "Cz", "Pz", "Oz", "C3", "C4"].iter().map(|s| s.to_string()).collect();
        let per = 171;
        let epochs = 13;
        let mut channels = vec![vec![0f32; per * epochs]; labels.len()];
        for (c, ch) in channels.iter_mut().enumerate() {
            for (s, v) in ch.iter_mut().enumerate() {
                *v = ((s as f64 * 0.21 * (c + 2) as f64).sin() * 4.0 + ((s * 31 + c * 7) % 13) as f64 * 0.1) as f32;
            }
        }
        let mut rec = Recording {
            rate,
            labels,
            channels,
            source_epoch_samples: Some(per),
            epoch_labels: Some((0..epochs).map(|i| format!("S {}", 51 + i % 2)).collect()),
        };
        let opts: PreprocessOptions = serde_json::from_value(serde_json::json!({
            "downsample_freq": 100.0, "filter": false, "badchannel": false, "gedai": true,
            "interpolate": false, "epoch_before_gedai": true, "gedai_epoch_seconds": 1.0
        }))
        .unwrap();
        run(&mut rec, "synthetic", "/tmp/ccs_epoched_input_test.ccseeg.json", &opts).unwrap();
        assert_eq!(rec.source_epoch_samples, Some(per));
        assert_eq!(rec.channels[0].len(), per * epochs);
    }

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
                "AF3".into(),
                "AF4".into(),
                "Fz".into(),
                "F3".into(),
                "F4".into(),
                "T7".into(),
                "DEAD".into(),
                "NOISY".into(),
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
        assert!(
            bad.contains(&"DEAD".to_string()),
            "flat channel not detected"
        );
        assert!(
            bad.contains(&"NOISY".to_string()),
            "artefact channel not detected"
        );

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
    fn buffered_portable_matches_legacy_bytes() {
        let rec = Recording { rate: 1000., labels: vec!["Pz".into()],
            channels: vec![(0..100_000).map(|i| (i as f32 * 0.013).sin()).collect()],
            source_epoch_samples: Some(1000), epoch_labels: Some(vec!["Standard".into();100]) };
        let base = std::env::temp_dir().join(format!("ccs-buffer-check-{}", std::process::id()));
        let legacy_path = base.with_extension("legacy");
        let buffered_path = base.with_extension("buffered");
        let owned = PortableRecording { format: "ccseeg-v1".into(), sample_rate:rec.rate,
            labels: rec.labels.clone(), channels: rec.channels.clone(), source_epoch_samples: rec.source_epoch_samples,
            epoch_labels:rec.epoch_labels.clone(), epoch_meta:None };
        let started = std::time::Instant::now();
        let mut legacy = fs::File::create(&legacy_path).unwrap();
        serde_json::to_writer(&mut legacy, &owned).unwrap(); legacy.write_all(b"\n").unwrap();
        drop(legacy);
        let old = started.elapsed(); let started = std::time::Instant::now();
        save_portable(buffered_path.to_str().unwrap(), &rec).unwrap();
        eprintln!("Portable save 100k samples: legacy {:?}, buffered {:?}", old, started.elapsed());
        let old_bytes = fs::read(&legacy_path).unwrap();
        let new_bytes = fs::read(&buffered_path).unwrap();
        // JSON property order is immaterial; values, labels and samples must match.
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&old_bytes).unwrap(), serde_json::from_slice::<serde_json::Value>(&new_bytes).unwrap());
        let restored = load_portable(&buffered_path).unwrap();
        assert_eq!(restored.channels, rec.channels);
        assert_eq!(restored.epoch_labels, rec.epoch_labels);
        assert_eq!(restored.source_epoch_samples, rec.source_epoch_samples);
        fs::remove_file(legacy_path).unwrap(); fs::remove_file(buffered_path).unwrap();
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


// ---------------------------------------------------------------------------------------------------------------
// ICA (runica / Picard + ICLabel + blink detection) and ASR, backed by the parity-validated `ccs_ica` crate
// ---------------------------------------------------------------------------------------------------------------

/// ICLabel/topoplot location (EEGLAB `theta` deg, `radius`) of a channel from the built-in 10-05 table.
/// The table is in MNE head coordinates (x right, y anterior, z up); EEGLAB's `theta` is measured from the nose,
/// positive to the right, and `radius = 0.5 - elevation/180`.
fn ica_chan_loc(label: &str) -> ccs_ica::iclabel::ChanLoc {
    let mut key = label.trim().to_uppercase();
    if let Some(rest) = key.strip_prefix("EEG ") { key = rest.to_string(); }
    if let Some(i) = key.find(|c: char| c == '-' || c == ' ') { key.truncate(i); }
    let pos = crate::eeg::montage::STANDARD_1005_POS.get(key.as_str()).copied();
    let (theta, radius) = match pos {
        Some([x, y, z]) => {
            let theta = x.atan2(y).to_degrees();
            let elev = z.atan2((x * x + y * y).sqrt()).to_degrees();
            (Some(theta), Some(0.5 - elev / 180.0))
        }
        None => (None, None),
    };
    ccs_ica::iclabel::ChanLoc { label: label.to_string(), theta, radius }
}

/// Runs ICA (blink stage + general stage) and/or ASR on the continuous data in place.  Bad channels are left out of
/// the decomposition (they are interpolated later).  Returns the JSON report and, for ASR reject mode, the keep-mask.
fn run_ica_asr(
    data: &mut Vec<Vec<f64>>,
    rate: f64,
    labels: &[String],
    bad_channels: &[String],
    options: &PreprocessOptions,
    epoch_samples: Option<usize>,
    warnings: &mut Vec<String>,
) -> Result<(serde_json::Value, Option<Vec<bool>>), String> {
    use ccs_ica::pipeline::IcaMethod;
    use ccs_ica::studio::*;
    let bad: std::collections::HashSet<String> = bad_channels.iter().map(|b| b.to_lowercase()).collect();
    let mut report = serde_json::json!({});
    let mut keep_mask: Option<Vec<bool>> = None;

    if matches!(options.ica_method.as_str(), "runica" | "picard") {
        let locs_all: Vec<_> = labels.iter().map(|l| ica_chan_loc(l)).collect();
        let good: Vec<usize> = (0..labels.len()).filter(|&i| !bad.contains(&labels[i].to_lowercase()) && locs_all[i].theta.is_some()).collect();
        let unlocated: Vec<&str> = (0..labels.len()).filter(|&i| locs_all[i].theta.is_none()).map(|i| labels[i].as_str()).collect();
        if !unlocated.is_empty() {
            warnings.push(format!("ICA/ICLabel left out channels without a 10-05 scalp position: {}", unlocated.join(", ")));
        }
        if good.len() < 8 {
            return Err(format!("ICA needs at least 8 good channels with scalp positions (found {})", good.len()));
        }
        if data[0].len() as f64 / rate < 20.0 {
            return Err("ICA needs at least 20 s of data".into());
        }
        eprintln!("PROGRESS 46 ICA ({}): high-pass copy for the decomposition...", options.ica_method);
        let target: Vec<Vec<f64>> = good.iter().map(|&i| data[i].clone()).collect();
        let hp: Vec<Vec<f64>> = if options.filter && options.low_hz >= 1.0 {
            target.clone()
        } else {
            target.par_iter().map(|ch| { let mut c = ch.clone(); for trial in c.chunks_mut(epoch_samples.unwrap_or(ch.len())) { fir_bandpass_custom(trial, rate, 1.0, 0.0, options.fir_taps); } c }).collect()
        };
        let locs: Vec<_> = good.iter().map(|&i| locs_all[i].clone()).collect();
        let mut o = StudioIcaOpts::default();
        o.method = if options.ica_method == "picard" { IcaMethod::Picard } else { IcaMethod::Runica };
        o.blink_stage = options.ica_blink;
        o.other_stage = options.ica_other;
        o.eye_chan = if options.ica_eye_channel.trim().is_empty() { None } else { Some(options.ica_eye_channel.trim().to_string()) };
        o.nepochs = options.ica_blink_epochs.max(2);
        o.blink_threshold = vec![options.ica_blink_threshold, options.ica_blink_threshold_floor];
        o.remove_ecg = options.ica_remove_ecg;
        if !options.ica_artefacts.is_empty() { o.other_artefacts = options.ica_artefacts.clone(); }
        o.other_threshold = vec![options.ica_other_threshold, options.ica_other_threshold_floor];
        o.fit_asr_cutoff = if options.ica_fit_asr { Some(options.ica_fit_asr_cutoff) } else { None };
        o.seed = options.ica_seed;
        o.epoch_samples = epoch_samples;
        eprintln!("PROGRESS 48 ICA ({}): blink detection, decomposition and ICLabel...", options.ica_method);
        let (clean, rep) = clean_ica(&target, &hp, &locs, rate, &o)?;
        for (k, &i) in good.iter().enumerate() {
            data[i] = clean[k].clone();
        }
        let stage = |s: &StageReport| serde_json::json!({
            "ran": s.ran, "components": s.components, "removed": s.removed, "removed_class": s.removed_class,
            "signals_lost": s.signals_lost, "note": s.note,
        });
        for n in &rep.notes {
            if !n.starts_with("Blink detection filters saved trials independently") { warnings.push(n.clone()); }
        }
        if !rep.stage1.note.is_empty() { warnings.push(rep.stage1.note.clone()); }
        report["ica"] = serde_json::json!({
            "method": options.ica_method, "channels_used": good.iter().map(|&i| labels[i].clone()).collect::<Vec<_>>(),
            "notes": rep.notes, "eye_channel": rep.eye_chan, "blink_events": rep.blink_events, "blink_epochs": rep.blink_epochs_used,
            "blink_stage": stage(&rep.stage1), "other_stage": stage(&rep.stage2),
        });
    }

    let vopts = {
        let mut v = VariantOpts::default();
        v.asr_variant = if options.asr_variant.is_empty() { "standard".into() } else { options.asr_variant.clone() };
        v.adapt_alpha = options.asr_adapt_alpha;
        v.adapt_block_seconds = options.asr_adapt_block_seconds;
        v.embed_dim = options.asr_embed_dim;
        v.embed_tau = options.asr_embed_tau;
        v.n_modes = options.asr_modes;
        v.dbscan_top_k = options.asr_dbscan_top_k;
        v.muscle_method = options.muscle_method.clone();
        v.bsscca_n_remove = options.bsscca_n_remove;
        v.bsscca_rho = options.bsscca_rho;
        v.icc_threshold = options.icc_threshold;
        v.icc_segment = options.icc_segment_seconds;
        v.icc_stop_lo = options.icc_stop_low_hz;
        v.icc_stop_hi = options.icc_stop_high_hz;
        v.wica_levels = options.wica_levels;
        v.wica_mult = options.wica_threshold_mult;
        v.seed = options.ica_seed;
        v
    };

    if matches!(options.muscle_method.as_str(), "bss_cca" | "icanclean" | "wica") {
        let good: Vec<usize> = (0..labels.len()).filter(|&i| !bad.contains(&labels[i].to_lowercase())).collect();
        if good.len() < 4 {
            return Err("Muscle cleaners need at least 4 good channels".into());
        }
        eprintln!("PROGRESS 50 Muscle/motion cleaner ({})...", options.muscle_method);
        let rows: Vec<Vec<f64>> = good.iter().map(|&i| data[i].clone()).collect();
        let hp_rows: Vec<Vec<f64>> = if options.filter && options.low_hz >= 1.0 {
            rows.clone()
        } else {
            rows.par_iter().map(|ch| { let mut c = ch.clone(); fir_bandpass_custom(&mut c, rate, 1.0, 0.0, options.fir_taps); c }).collect()
        };
        match extra_clean(&hp_rows, rate, &vopts) {
            Ok((clean, rep)) => {
                // as for ASR: apply the correction (cleaned - high-passed) to the original so < 1 Hz content is kept
                for (k, &i) in good.iter().enumerate() {
                    for t in 0..data[i].len() {
                        data[i][t] += clean[k][t] - hp_rows[k][t];
                    }
                }
                report["muscle"] = rep;
            }
            Err(e) => warnings.push(format!("Muscle cleaner ({}) skipped: {e}", options.muscle_method)),
        }
    }

    if matches!(options.asr_mode.as_str(), "correct" | "reject") {
        let reject = options.asr_mode == "reject";
        let good: Vec<usize> = (0..labels.len()).filter(|&i| !bad.contains(&labels[i].to_lowercase())).collect();
        if good.len() < 2 {
            return Err("ASR needs at least 2 good channels".into());
        }
        eprintln!("PROGRESS 52 ASR ({}, cutoff {})...", options.asr_mode, options.asr_cutoff);
        let rows: Vec<Vec<f64>> = good.iter().map(|&i| data[i].clone()).collect();
        let hp_rows: Vec<Vec<f64>> = if options.filter && options.low_hz >= 1.0 {
            rows.clone()
        } else {
            rows.par_iter().map(|ch| { let mut c = ch.clone(); fir_bandpass_custom(&mut c, rate, 1.0, 0.0, options.fir_taps); c }).collect()
        };
        // clean_rawdata expects high-passed data; ASR is estimated on the 1 Hz copy and the correction is applied
        // to the same samples of the unfiltered-below-1 Hz data only in reject mode (mask) or via the difference.
        match asr_clean_variant(&hp_rows, rate, options.asr_cutoff, reject, &vopts) {
            Ok((out, asr_note)) => {
                if !asr_note.is_empty() { warnings.push(asr_note); }
                if reject {
                    keep_mask = out.keep_mask.clone();
                } else {
                    // repaired(hp) - hp is the ASR correction; add it to the original (preserves < 1 Hz content)
                    for (k, &i) in good.iter().enumerate() {
                        for t in 0..data[i].len() {
                            data[i][t] += out.data[k][t] - hp_rows[k][t];
                        }
                    }
                }
                report["asr"] = serde_json::json!({
                    "mode": options.asr_mode, "cutoff": options.asr_cutoff, "variant": vopts.asr_variant,
                    "samples_changed": out.changed_samples, "samples_total": data[0].len(),
                    "samples_kept": keep_mask.as_ref().map(|m| m.iter().filter(|&&k| k).count()),
                });
                if reject {
                    warnings.push("ASR reject mode removed samples; time stamps of the output no longer map 1:1 to the input".into());
                }
            }
            Err(e) => warnings.push(format!("ASR skipped: {e}")),
        }
    }
    Ok((report, keep_mask))
}
