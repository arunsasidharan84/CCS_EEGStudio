//! High-level, in-memory cleaning API used by the CCS EEG Studio engine: blink-locked ICA stage + general ICA stage
//! (`runica` or Picard, ICLabel selection) with optional ASR on the ICA fit data, plus a stand-alone ASR repair.
//!
//! All data are `channels x samples` in microvolts.  The caller supplies the 1 Hz high-passed copy of the data
//! (`hp`) the ICA is fitted on, exactly like `tempEEG0 = pop_eegfiltnew(.., 'locutoff',1)` in the MATLAB pipeline.

use crate::asr::{burst_rejection, clean_asr, clean_windows, AsrParams};
use crate::autoremove::pop_subcomp;
use crate::blink::eyeblink_detection;
use crate::iclabel::{ChanLoc, Eeg};
use crate::linalg::*;
use crate::pipeline::{ica1_blink_ecg, ica2_other, Ica1Opts, Ica2Opts, IcaMethod};
use crate::rng::{NativeRng, Rng};

#[derive(Clone, Debug)]
pub struct StudioIcaOpts {
    pub method: IcaMethod,
    /// Run the blink-locked ICA stage (`accs_eyeblinkremoval`).
    pub blink_stage: bool,
    /// Eye channel for blink detection (case-insensitive label); `None` -> Fp1/Fp2/AFz/Fz/F7/F8/AF3/AF4, else first.
    pub eye_chan: Option<String>,
    pub nepochs: usize,
    pub nsteps: usize,
    pub blink_threshold: Vec<f64>,
    pub remove_ecg: bool,
    /// Run the second ICA stage (muscle / line noise / channel noise).
    pub other_stage: bool,
    pub other_artefacts: Vec<String>,
    pub other_threshold: Vec<f64>,
    pub maxcomp2rem: f64,
    pub maxsig2rem: f64,
    /// ASR burst-rejection cutoff applied to the ICA-2 fit data (`pop_clean_rawdata` step); `None` = off.
    pub fit_asr_cutoff: Option<f64>,
    pub seed: u32,
    /// Trial length; temporal operations never bridge adjacent trials.
    pub epoch_samples: Option<usize>,
}

impl Default for StudioIcaOpts {
    fn default() -> Self {
        StudioIcaOpts {
            method: IcaMethod::Runica,
            blink_stage: true,
            eye_chan: None,
            nepochs: 20,
            nsteps: 50,
            blink_threshold: vec![0.99, 0.60],
            remove_ecg: true,
            other_stage: true,
            other_artefacts: vec!["Muscle".into(), "Line Noise".into(), "Channel Noise".into()],
            other_threshold: vec![0.99, 0.60],
            maxcomp2rem: 0.1,
            maxsig2rem: 0.3,
            fit_asr_cutoff: Some(15.0),
            seed: 1,
            epoch_samples: None,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct StageReport {
    pub ran: bool,
    pub components: usize,
    /// 1-based indices of removed components.
    pub removed: Vec<usize>,
    /// Dominant ICLabel class of each removed component.
    pub removed_class: Vec<String>,
    pub signals_lost: f64,
    pub note: String,
}

#[derive(Clone, Debug, Default)]
pub struct StudioIcaReport {
    pub blink_events: usize,
    pub blink_epochs_used: usize,
    pub eye_chan: String,
    pub stage1: StageReport,
    pub stage2: StageReport,
    pub notes: Vec<String>,
}

const CLASSES: [&str; 7] = ["Brain", "Muscle", "Eye", "Heart", "Line Noise", "Channel Noise", "Other"];

fn to_mat(rows: &[Vec<f64>]) -> Mat {
    let c = rows.len();
    let n = rows[0].len();
    Mat::from_fn(c, n, |i, j| rows[i][j])
}

fn from_mat(m: &Mat) -> Vec<Vec<f64>> {
    (0..m.nrows()).map(|i| m.row(i).iter().cloned().collect()).collect()
}

fn dominant_class(classif: &Mat, comp1: usize) -> String {
    let r = comp1 - 1;
    let mut best = 0;
    for k in 1..classif.ncols().min(7) {
        if classif[(r, k)] > classif[(r, best)] {
            best = k;
        }
    }
    CLASSES[best].to_string()
}

fn pick_eye_channel(locs: &[ChanLoc], wanted: &Option<String>) -> usize {
    // accs_CCScleaningpipeline: keep the requested channel if present, otherwise `intersect(lower(chanlist), candidates, 'stable')`
    // i.e. the first channel *in recording order* that is one of the candidates; else the first channel.
    if let Some(w) = wanted {
        if let Some(i) = locs.iter().position(|l| l.label.eq_ignore_ascii_case(w)) {
            return i;
        }
    }
    let cands = ["fp1", "fp2", "afz", "fz", "f7", "f8", "af3", "af4"];
    locs.iter().position(|l| cands.iter().any(|c| l.label.eq_ignore_ascii_case(c))).unwrap_or(0)
}

/// Blink-locked epochs (`[-1 1]` s, `round(2*srate)` samples) of the high-passed data, at most `nepochs`, random subset.
fn blink_epochs(hp: &Mat, events_1based: &[usize], srate: f64, nepochs: usize, epoch_samples: Option<usize>, rng: &mut dyn Rng) -> (Mat, usize, usize) {
    let pnts = epoch_samples.unwrap_or(usize::MAX).min((2.0 * srate).round() as usize);
    let half = (pnts / 2) as i64;
    let total = hp.ncols() as i64;
    let mut starts: Vec<usize> = vec![];
    if events_1based.is_empty() {
        // eeg_regepochs fallback: consecutive 2 s windows
        let mut s = 0usize;
        while s + pnts <= hp.ncols() {
            starts.push(s);
            s += pnts;
        }
    } else {
        for &e in events_1based {
            let mut s = e as i64 - 1 - half;
            if let Some(n) = epoch_samples {
                let first = ((e.saturating_sub(1) / n) * n) as i64;
                let last = (first + n as i64).min(total) - pnts as i64;
                if last < first { continue; }
                s = s.clamp(first, last);
            }
            if s >= 0 && s + pnts as i64 <= total {
                starts.push(s as usize);
            }
        }
    }
    if let Some(n) = epoch_samples { starts.retain(|&s| s / n == (s + pnts - 1) / n); }
    starts.sort_unstable(); starts.dedup();
    let trials = starts.len();
    let take = nepochs.min(trials);
    let perm = rng.randperm(trials);
    let mut out = Mat::zeros(hp.nrows(), take * pnts);
    for (k, &p) in perm.iter().take(take).enumerate() {
        for c in 0..hp.nrows() {
            for t in 0..pnts {
                out[(c, k * pnts + t)] = hp[(c, starts[p] + t)];
            }
        }
    }
    (out, pnts, take)
}

/// Two-stage ICA cleaning.  `target` = data to be cleaned, `hp` = its 1 Hz high-passed copy, `locs` the per-channel
/// ICLabel locations (every channel must have one).
pub fn clean_ica(target: &[Vec<f64>], hp: &[Vec<f64>], locs: &[ChanLoc], srate: f64, o: &StudioIcaOpts) -> Result<(Vec<Vec<f64>>, StudioIcaReport), String> {
    let c = target.len();
    if c < 4 {
        return Err("ICA needs at least 4 channels".into());
    }
    if locs.len() != c || hp.len() != c {
        return Err("channel/location count mismatch".into());
    }
    if locs.iter().any(|l| l.theta.is_none() || l.radius.is_none()) {
        return Err("ICA/ICLabel needs a scalp position for every channel".into());
    }
    let mut rng = NativeRng::new(o.seed);
    let mut rep = StudioIcaReport::default();
    let mut data = to_mat(target);
    let mut hpm = to_mat(hp);

    if o.blink_stage {
        let eye = pick_eye_channel(locs, &o.eye_chan);
        rep.eye_chan = locs[eye].label.clone();
        let mut events = Vec::new();
        let boundary = o.epoch_samples.unwrap_or(target[eye].len());
        eprintln!("PROGRESS 47 ICA: blink detection within {} saved trial(s)", target[eye].len().div_ceil(boundary));
        let trial_filter = if o.epoch_samples.is_some() {
            rep.notes.push("Blink detection filters saved trials independently with within-trial reflection for short windows; event times and boundaries are retained".into());
            Some(crate::blink::eegfilt_coefficients(srate, 1.5, 15.0)?)
        } else { None };
        for (trial, samples) in target[eye].chunks(boundary).enumerate() {
            let groups = if let Some(ref b) = trial_filter {
                crate::blink::eyeblink_detection_epoch(samples, srate, b)?
            } else { eyeblink_detection(samples, srate)? };
            events.extend(groups.iter().flatten().map(|&e| e + trial * boundary));
        }
        rep.blink_events = events.len();
        let (epochs, pnts, trials) = blink_epochs(&hpm, &events, srate, o.nepochs, o.epoch_samples, &mut rng);
        rep.blink_epochs_used = trials;
        if trials < 2 {
            rep.stage1.note = "too few blink epochs; blink ICA skipped".into();
        } else {
            let mut o1 = Ica1Opts::default();
            o1.method = o.method;
            o1.nsteps = o.nsteps;
            o1.threshold = o.blink_threshold.clone();
            o1.removeecg = o.remove_ecg;
            eprintln!("PROGRESS 48 ICA pass 1/{}: eye/ECG fitting and ICLabel", if o.other_stage {2} else {1});
            let r = ica1_blink_ecg(&epochs, pnts, trials, srate, locs, &data, &o1, &mut rng)?;
            rep.stage1 = StageReport {
                ran: true,
                components: r.ica.icaweights.nrows(),
                removed: r.selection.comp2remove.clone(),
                removed_class: r.selection.comp2remove.iter().map(|&k| dominant_class(&r.classifications, k)).collect(),
                signals_lost: r.selection.signalslost,
                note: String::new(),
            };
            if !r.selection.comp2remove.is_empty() {
                // the cleaning is a linear projection, so applying it to the high-passed copy equals high-passing the cleaned data
                let (hp_clean, _, _) = pop_subcomp(&hpm, &r.ica.icaweights, &r.ica.icasphere, &r.ica.icawinv, &r.ica.icachansind, &r.selection.comp2remove)?;
                data = r.clean;
                hpm = hp_clean;
            }
        }
    }

    if o.other_stage {
        eprintln!("PROGRESS 49 ICA: prepare fit copy (training ASR {}; original output samples retained)", if o.fit_asr_cutoff.is_some() {"on"} else {"off"});
        let fit = match o.fit_asr_cutoff {
            Some(cut) if hpm.ncols() as f64 > 10.0 * srate => {
                let rows = from_mat(&hpm);
                let params = AsrParams::clean_artifacts(cut);
                let cleaned = if let Some(points) = o.epoch_samples {
                    match crate::asr::epoched_asr_fit(&rows,srate,cut,points) {
                        Ok(fit) => fit,
                        Err(e) => { rep.notes.push(format!("ICA training ASR unavailable: {e}; retaining the fit samples")); rows.clone() }
                    }
                } else {
                    let (repaired, _) = clean_asr(&rows,srate,&params)?;
                    let br=burst_rejection(&rows,&repaired);
                    clean_windows(&br.data,srate,0.25,[f64::NEG_INFINITY,7.0],1.0).0
                };
                // pop_clean_rawdata(.., 'BurstRejection','on') also keeps its default WindowCriterion 0.25 / [-inf 7]
                if !cleaned.is_empty() && cleaned[0].len() as f64 > 0.5 * srate * 10.0 {
                    to_mat(&cleaned)
                } else {
                    rep.notes.push("ASR rejected nearly all samples of the ICA fit data; fitting ICA on unrejected data".into());
                    hpm.clone()
                }
            }
            _ => hpm.clone(),
        };
        let mut o2 = Ica2Opts::default();
        o2.method = o.method;
        o2.threshold = o.other_threshold.clone();
        o2.artefacts = o.other_artefacts.clone();
        o2.maxcomp2rem = o.maxcomp2rem;
        o2.maxsig2rem = o.maxsig2rem;
        let target_eeg = Eeg {
            data: data.clone(),
            pnts: data.ncols(),
            trials: 1,
            srate,
            chanlocs: locs.to_vec(),
            icaweights: Mat::zeros(0, 0),
            icasphere: Mat::zeros(0, 0),
            icawinv: Mat::zeros(0, 0),
            icachansind: vec![],
            reference: "common".to_string(),
        };
        eprintln!("PROGRESS 50 ICA pass {}/{}: general artifact fitting and ICLabel", if o.blink_stage {2} else {1}, if o.blink_stage {2} else {1});
        let r = ica2_other(&fit, &target_eeg, &o2, &mut rng)?;
        rep.stage2 = StageReport {
            ran: true,
            components: r.ica.icaweights.nrows(),
            removed: r.selection.comp2remove.clone(),
            removed_class: r.selection.comp2remove.iter().map(|&k| dominant_class(&r.classifications, k)).collect(),
            signals_lost: r.selection.signalslost,
            note: String::new(),
        };
        data = r.clean;
    }
    Ok((from_mat(&data), rep))
}

/// Result of [`asr_clean`].
pub struct AsrOutcome {
    /// Repaired data (same length) or, in reject mode, the data with the modified samples removed.
    pub data: Vec<Vec<f64>>,
    /// Reject mode: per-sample keep mask of the input (apply it to any other channel that must stay aligned).
    pub keep_mask: Option<Vec<bool>>,
    /// Number of samples ASR had to modify.
    pub changed_samples: usize,
}

/// Stand-alone ASR (`clean_asr` parameters of `clean_artifacts`, Euclidean): `reject = false` returns the repaired data
/// (same length); `reject = true` drops the samples ASR had to modify (`BurstRejection = on`).
pub fn asr_clean(data: &[Vec<f64>], srate: f64, cutoff: f64, reject: bool) -> Result<AsrOutcome, String> {
    let params = AsrParams::clean_artifacts(cutoff);
    let input = data.to_vec();
    let (repaired, _) = clean_asr(&input, srate, &params)?;
    let changed_samples = (0..data[0].len()).filter(|&t| data.iter().zip(repaired.iter()).map(|(a, b)| (a[t] - b[t]).abs()).sum::<f64>() >= 1e-8).count();
    if reject {
        let br = burst_rejection(&input, &repaired);
        Ok(AsrOutcome { data: br.data, keep_mask: Some(br.sample_mask), changed_samples })
    } else {
        Ok(AsrOutcome { data: repaired, keep_mask: None, changed_samples })
    }
}

// ------------------------------------------------------------------------------------------------------------
// ASR variants and alternative cleaners (see `variants.rs` for the verification status of each)
// ------------------------------------------------------------------------------------------------------------

/// Options of the ASR variants / alternative cleaners as exposed in the CCS_EEGStudio preprocessing step.
#[derive(Clone, Debug)]
pub struct VariantOpts {
    /// "standard" | "riemannian" | "adaptive" | "juggler_dbscan" | "juggler_gev" | "easr" | "vmd" | "emd"
    pub asr_variant: String,
    pub adapt_alpha: f64,
    pub adapt_block_seconds: f64,
    pub embed_dim: usize,
    pub embed_tau: usize,
    pub n_modes: usize,
    pub dbscan_top_k: usize,
    /// "" | "bss_cca" | "icanclean" | "wica"
    pub muscle_method: String,
    pub bsscca_n_remove: usize,
    pub bsscca_rho: f64,
    pub icc_threshold: f64,
    pub icc_segment: f64,
    pub icc_stop_lo: f64,
    pub icc_stop_hi: f64,
    pub wica_levels: usize,
    pub wica_mult: f64,
    pub seed: u32,
    /// Trial length; temporal operations never bridge adjacent trials.
    pub epoch_samples: Option<usize>,
}
impl Default for VariantOpts {
    fn default() -> Self {
        VariantOpts {
            asr_variant: "standard".into(), adapt_alpha: 0.05, adapt_block_seconds: 2.0, embed_dim: 8, embed_tau: 2, n_modes: 4,
            dbscan_top_k: 5, muscle_method: String::new(), bsscca_n_remove: 3, bsscca_rho: 0.0, icc_threshold: 0.7, icc_segment: 2.0,
            icc_stop_lo: 1.0, icc_stop_hi: 8.0, wica_levels: 5, wica_mult: 1.0, seed: 1,
            epoch_samples: None,
        }
    }
}

/// ASR of the chosen variant (same contract as [`asr_clean`]).  Returns the outcome and a short note about the run.
pub fn asr_clean_variant(data: &[Vec<f64>], srate: f64, cutoff: f64, reject: bool, v: &VariantOpts) -> Result<(AsrOutcome, String), String> {
    use crate::variants::*;
    if matches!(v.asr_variant.as_str(), "" | "standard") {
        return Ok((asr_clean(data, srate, cutoff, reject)?, String::new()));
    }
    let mut params = AsrParams::clean_artifacts(cutoff);
    let input = data.to_vec();
    let mut note = String::new();
    let low_channels = |name: &str| -> Result<(), String> {
        if data.len() > 8 {
            Err(format!("ASR variant '{name}' is meant for single / low channel counts (<= 8 channels, got {}); use standard or riemannian ASR", data.len()))
        } else {
            Ok(())
        }
    };
    let repaired: Vec<Vec<f64>> = match v.asr_variant.as_str() {
        "riemannian" => {
            params.riemannian = true;
            params.rasr_block_seconds = Some(30.0);
            clean_asr(&input, srate, &params)?.0
        }
        "adaptive" => {
            let (y, n) = adaptive_asr(&input, srate, &params, &AdaptiveAsrOpts { alpha: v.adapt_alpha, block_seconds: v.adapt_block_seconds })?;
            note = format!("adaptive ASR: {n} calibration updates");
            y
        }
        "juggler_dbscan" | "juggler_gev" => {
            let st = if v.asr_variant == "juggler_gev" { Juggler::Gev } else { Juggler::Dbscan };
            let (y, sel) = juggler_asr(&input, srate, st, v.dbscan_top_k.max(1), &params)?;
            note = format!("calibration samples selected by {}", sel.detail);
            y
        }
        "easr" => {
            low_channels("E-ASR")?;
            easr(&input, srate, v.embed_dim.max(2), v.embed_tau.max(1), &params)?
        }
        "vmd" => {
            low_channels("VMD-ASR")?;
            vmd_asr(&input, srate, &crate::decomp::VmdOpts { k: v.n_modes.max(2), ..Default::default() }, &params)?
        }
        "emd" => {
            low_channels("EMD-ASR")?;
            emd_asr(&input, srate, v.n_modes.max(2), &params)?
        }
        other => return Err(format!("unknown ASR variant '{other}'")),
    };
    let changed_samples = (0..data[0].len()).filter(|&t| data.iter().zip(repaired.iter()).map(|(a, b)| (a[t] - b[t]).abs()).sum::<f64>() >= 1e-8).count();
    let out = if reject {
        let br = burst_rejection(&input, &repaired);
        AsrOutcome { data: br.data, keep_mask: Some(br.sample_mask), changed_samples }
    } else {
        AsrOutcome { data: repaired, keep_mask: None, changed_samples }
    };
    Ok((out, note))
}

/// Muscle / motion artefact cleaners that are not ASR: BSS-CCA, iCanClean (pseudo-reference) and wICA.
pub fn extra_clean(data: &[Vec<f64>], srate: f64, v: &VariantOpts) -> Result<(Vec<Vec<f64>>, serde_json::Value), String> {
    use crate::variants::*;
    let input = data.to_vec();
    match v.muscle_method.as_str() {
        "bss_cca" => {
            let o = if v.bsscca_n_remove > 0 {
                BssCcaOpts { lag: 1, n_remove: Some(v.bsscca_n_remove), rho_threshold: None }
            } else {
                BssCcaOpts { lag: 1, n_remove: None, rho_threshold: Some(v.bsscca_rho) }
            };
            let (y, rep) = bss_cca(&input, &o)?;
            let lo: Vec<f64> = rep.rho.iter().rev().take(5).cloned().collect();
            Ok((y, serde_json::json!({"method": "bss_cca", "removed": rep.removed, "components": rep.rho.len(), "lowest_rho": lo})))
        }
        "icanclean" => {
            let o = ICanCleanOpts { segment_len: v.icc_segment, overlap: 0.0, threshold: v.icc_threshold, max_reject_fraction: 0.5, ref_stop_band: (v.icc_stop_lo, v.icc_stop_hi) };
            let (y, rep) = icanclean_pseudo(&input, srate, &o)?;
            let tot: usize = rep.removed_per_window.iter().sum();
            Ok((y, serde_json::json!({"method": "icanclean", "windows": rep.n_windows, "components_removed_total": tot,
                "components_removed_mean_per_window": tot as f64 / rep.n_windows.max(1) as f64})))
        }
        "wica" => {
            let y = wica(&input, &WicaOpts { levels: v.wica_levels.max(1), threshold_mult: v.wica_mult, seed: v.seed })?;
            Ok((y, serde_json::json!({"method": "wica", "levels": v.wica_levels, "threshold_mult": v.wica_mult})))
        }
        other => Err(format!("unknown muscle method '{other}'")),
    }
}

#[cfg(test)]
mod epoch_boundary_tests {
    use super::*;
    #[test]
    fn blink_training_windows_never_span_trials() {
        let hp = Mat::from_fn(4, 600, |_, t| (t / 150) as f64);
        let mut rng = NativeRng::new(1);
        let (epochs, points, trials) = blink_epochs(&hp, &[76, 151, 226, 301, 376, 451, 526], 100., 20, Some(150), &mut rng);
        assert_eq!(points, 150);
        assert!(trials >= 2);
        for trial in 0..trials {
            let first = epochs[(0, trial * points)];
            for t in 0..points { assert_eq!(epochs[(0, trial * points + t)], first); }
        }
    }
}
