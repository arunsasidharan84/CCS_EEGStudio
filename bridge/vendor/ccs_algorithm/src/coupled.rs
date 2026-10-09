//! Coupled Multi-Scale Windowing Engine.
//!
//! Synchronizes subepoch EEG dynamics (e.g. 2s subepochs for fast Welch PSD/connectivity/SQI)
//! with longer macro-epoch cardiac dynamics (e.g. 16s sliding epochs for HRV and PPG/ECG morphology).
//!
//! Highly flexible: supports when both EEG and Cardiac are requested, or when only EEG or only Cardiac is requested.

use crate::cardiac::{extract_cardiac_features, CardiacFeatures, Modality};
use crate::eeg::connectivity::{column_names, compute_epoch};
use crate::eeg::features::{acw50, bandpowers};
use crate::eeg::nonlinear::all as extract_nonlinear;
use crate::eeg::spectral::{fooof_features, irasa_features};
use crate::eeg::Options;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CoupledEpochConfig {
    pub enable_eeg: bool,
    pub enable_cardiac: bool,
    pub eeg_srate: f64,
    pub cardiac_srate: f64,
    pub eeg_subepoch_sec: f64,
    pub cardiac_epoch_sec: f64,
    pub macro_epoch_sec: f64,
    pub window_step_sec: f64,
    pub cardiac_modality: String,
    pub eeg_options: Options,
}

impl Default for CoupledEpochConfig {
    fn default() -> Self {
        Self {
            enable_eeg: true,
            enable_cardiac: true,
            eeg_srate: 250.0,
            cardiac_srate: 100.0,
            eeg_subepoch_sec: 2.0,
            cardiac_epoch_sec: 16.0,
            macro_epoch_sec: 16.0,
            window_step_sec: 4.0,
            cardiac_modality: "PPG".into(),
            eeg_options: Options::connectivity_test(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SubepochEegResult {
    pub window_idx: usize,
    pub subepoch_idx: usize,
    pub start_sec: f64,
    pub end_sec: f64,
    pub channel_features: BTreeMap<String, BTreeMap<String, f64>>,
    pub connectivity: BTreeMap<String, f64>,
    pub channel_sqi: BTreeMap<String, f64>,
    pub avg_sqi: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CoupledWindowRecord {
    pub window_idx: usize,
    pub start_sec: f64,
    pub end_sec: f64,
    pub eeg_subepochs: Option<Vec<SubepochEegResult>>,
    pub cardiac_features: Option<CardiacFeatures>,
    pub window_overall_sqi: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CoupledSessionResult {
    pub config: CoupledEpochConfig,
    pub total_session_sec: f64,
    pub num_windows: usize,
    pub records: Vec<CoupledWindowRecord>,
}

/// Compute subepoch EEG features across a slice of channel data.
pub fn compute_eeg_subepoch(
    channels: &[Vec<f64>],
    labels: &[String],
    srate: f64,
    start_sec: f64,
    end_sec: f64,
    window_idx: usize,
    subepoch_idx: usize,
    options: &Options,
) -> SubepochEegResult {
    let mut channel_features = BTreeMap::new();
    let mut channel_sqi = BTreeMap::new();
    let mut total_sqi = 0.0;
    let mut valid_sqi_count = 0.0;

    for (ch_idx, signal) in channels.iter().enumerate() {
        let label = labels
            .get(ch_idx)
            .cloned()
            .unwrap_or_else(|| format!("CH_{ch_idx}"));
        let mut feats = BTreeMap::new();

        if options.psd {
            let bp = bandpowers(signal, srate);
            for (k, v) in bp {
                feats.insert(k, v);
            }
        }
        if options.acw {
            let val = acw50(signal, srate);
            feats.insert("ACW50".into(), if val.is_finite() { val } else { 0.0 });
        }
        if options.fooof {
            let ff = fooof_features(signal, srate);
            for (k, v) in ff {
                feats.insert(k, v);
            }
        }
        if options.irasa {
            let ir = irasa_features(signal, srate);
            for (k, v) in ir {
                feats.insert(k, v);
            }
        }
        if options.nonlinear {
            let nl = extract_nonlinear(signal);
            for (k, v) in nl {
                feats.insert(k.to_string(), v);
            }
        }

        let sqi = crate::sqi::eeg_epoch_quality(signal);
        channel_sqi.insert(label.clone(), sqi);
        total_sqi += sqi;
        valid_sqi_count += 1.0;

        channel_features.insert(label, feats);
    }

    let avg_sqi = if valid_sqi_count > 0.0 {
        total_sqi / valid_sqi_count
    } else {
        0.0
    };

    let mut connectivity = BTreeMap::new();
    if options.connectivity && channels.len() >= 2 {
        let rec_channels: Vec<Vec<f32>> = channels
            .iter()
            .map(|ch| ch.iter().map(|&v| v as f32).collect())
            .collect();
        let col_names = column_names(options);
        let n_samples = channels[0].len();
        let rows = compute_epoch(&rec_channels, labels, 0, n_samples, srate, options);
        for (ch_idx, ch_label) in labels.iter().enumerate() {
            if let Some(ch_vals) = rows.get(ch_idx) {
                for (col_idx, &val) in ch_vals.iter().enumerate() {
                    if let Some(col_name) = col_names.get(col_idx) {
                        connectivity.insert(format!("{}_{}", ch_label, col_name), val);
                    }
                }
            }
        }
    }

    SubepochEegResult {
        window_idx,
        subepoch_idx,
        start_sec,
        end_sec,
        channel_features,
        connectivity,
        channel_sqi,
        avg_sqi,
    }
}

/// Compute coupled multi-scale session features across time.
pub fn compute_coupled_session(
    eeg_channels: Option<&[Vec<f64>]>,
    eeg_labels: Option<&[String]>,
    cardiac_channel: Option<&[f64]>,
    config: &CoupledEpochConfig,
) -> CoupledSessionResult {
    let macro_sec = config.macro_epoch_sec.max(1.0);
    let step_sec = config.window_step_sec.max(0.5);

    // Determine total session duration in seconds
    let mut total_sec = 0.0;
    if config.enable_eeg && eeg_channels.is_some() {
        let chs = eeg_channels.unwrap();
        if !chs.is_empty() && config.eeg_srate > 0.0 {
            total_sec = chs[0].len() as f64 / config.eeg_srate;
        }
    }
    if config.enable_cardiac && cardiac_channel.is_some() {
        let card = cardiac_channel.unwrap();
        if !card.is_empty() && config.cardiac_srate > 0.0 {
            let card_sec = card.len() as f64 / config.cardiac_srate;
            if total_sec == 0.0 || card_sec < total_sec {
                total_sec = card_sec;
            }
        }
    }

    if total_sec < macro_sec {
        return CoupledSessionResult {
            config: config.clone(),
            total_session_sec: total_sec,
            num_windows: 0,
            records: Vec::new(),
        };
    }

    let mut start_times = Vec::new();
    let mut cur = 0.0;
    while cur + macro_sec <= total_sec + 1e-6 {
        start_times.push(cur);
        cur += step_sec;
    }

    let default_eeg_labels = if let Some(chs) = eeg_channels {
        (0..chs.len())
            .map(|i| format!("EEG_{i}"))
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let labels_slice = eeg_labels.unwrap_or(&default_eeg_labels);

    let modality = Modality::from_str(&config.cardiac_modality);

    let records: Vec<CoupledWindowRecord> = start_times
        .par_iter()
        .enumerate()
        .map(|(win_idx, &w_start)| {
            let w_end = w_start + macro_sec;

            // Compute EEG subepochs inside this window if enabled
            let eeg_res = if config.enable_eeg && eeg_channels.is_some() {
                let chs = eeg_channels.unwrap();
                let sub_sec = config.eeg_subepoch_sec.max(0.5);
                let mut sub_results = Vec::new();
                let mut sub_start = w_start;
                let mut sub_idx = 0;
                while sub_start + sub_sec <= w_end + 1e-6 {
                    let sub_end = sub_start + sub_sec;
                    let sample_start = (sub_start * config.eeg_srate).round() as usize;
                    let sample_end = (sub_end * config.eeg_srate).round() as usize;

                    let sliced_channels: Vec<Vec<f64>> = chs
                        .iter()
                        .map(|ch| {
                            let end = sample_end.min(ch.len());
                            let start = sample_start.min(end);
                            ch[start..end].to_vec()
                        })
                        .collect();

                    if !sliced_channels.is_empty() && !sliced_channels[0].is_empty() {
                        let sub_res = compute_eeg_subepoch(
                            &sliced_channels,
                            labels_slice,
                            config.eeg_srate,
                            sub_start,
                            sub_end,
                            win_idx,
                            sub_idx,
                            &config.eeg_options,
                        );
                        sub_results.push(sub_res);
                    }
                    sub_start += sub_sec;
                    sub_idx += 1;
                }
                Some(sub_results)
            } else {
                None
            };

            // Compute Cardiac features inside this window if enabled
            let card_res = if config.enable_cardiac && cardiac_channel.is_some() {
                let card = cardiac_channel.unwrap();
                let sample_start = (w_start * config.cardiac_srate).round() as usize;
                let sample_end = (w_end * config.cardiac_srate).round() as usize;
                let end = sample_end.min(card.len());
                let start = sample_start.min(end);
                let slice = &card[start..end];
                if !slice.is_empty() {
                    Some(extract_cardiac_features(
                        slice,
                        config.cardiac_srate,
                        modality,
                    ))
                } else {
                    None
                }
            } else {
                None
            };

            // Calculate overall window SQI combining EEG and Cardiac
            let mut sqi_sum = 0.0;
            let mut sqi_cnt = 0.0;
            if let Some(ref subs) = eeg_res {
                for sub in subs {
                    sqi_sum += sub.avg_sqi;
                    sqi_cnt += 1.0;
                }
            }
            if let Some(ref card) = card_res {
                sqi_sum += card.sqi;
                sqi_cnt += 1.0;
            }
            let window_overall_sqi = if sqi_cnt > 0.0 {
                sqi_sum / sqi_cnt
            } else {
                0.0
            };

            CoupledWindowRecord {
                window_idx: win_idx,
                start_sec: w_start,
                end_sec: w_end,
                eeg_subepochs: eeg_res,
                cardiac_features: card_res,
                window_overall_sqi,
            }
        })
        .collect();

    CoupledSessionResult {
        config: config.clone(),
        total_session_sec: total_sec,
        num_windows: records.len(),
        records,
    }
}
