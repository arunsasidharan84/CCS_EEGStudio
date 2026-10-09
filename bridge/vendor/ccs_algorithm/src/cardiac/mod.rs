//! Cardiac feature extraction engine (`PPG` and `ECG`).
//!
//! Combines peak detection, HRV features, advanced morphology, and signal quality metrics.

use serde::{Deserialize, Serialize};

pub mod hrv;
pub mod morphology;
pub mod peaks;

use hrv::{compute_hrv_features, HrvMetrics};
use morphology::{extract_advanced_morphology, MorphologyMetrics};
use peaks::{detect_ecg_peaks, detect_ppg_peaks};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Modality {
    Ppg,
    Ecg,
    None,
}

impl Modality {
    pub fn from_str(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "PPG" => Modality::Ppg,
            "ECG" => Modality::Ecg,
            _ => Modality::None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Modality::Ppg => "PPG",
            Modality::Ecg => "ECG",
            Modality::None => "NONE",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CardiacFeatures {
    pub modality: String,
    pub num_peaks: usize,
    pub mean_rr_ms: f64,
    pub avg_hr_bpm: f64,
    pub sdnn_ms: f64,
    pub rmssd_ms: f64,
    pub pnn50_pct: f64,
    pub pnn20_pct: f64,
    pub cvnn: f64,
    pub cvsd: f64,
    pub hti: f64,
    pub tinn_ms: f64,
    pub vlf_power: f64,
    pub lf_power: f64,
    pub hf_power: f64,
    pub total_power: f64,
    pub lf_n_pct: f64,
    pub hf_n_pct: f64,
    pub lf_hf_ratio: f64,
    pub sd1_ms: f64,
    pub sd2_ms: f64,
    pub sd1_sd2_ratio: f64,
    pub csi: f64,
    pub cvi: f64,
    pub samp_en: f64,
    pub apg_b_a_ratio: f64,
    pub apg_d_a_ratio: f64,
    pub apg_e_a_ratio: f64,
    pub morph_pulse_amp: f64,
    pub morph_sd_time_ratio: f64,
    pub sqi: f64,
}

impl Default for CardiacFeatures {
    fn default() -> Self {
        Self {
            modality: "NONE".into(),
            num_peaks: 0,
            mean_rr_ms: 0.0,
            avg_hr_bpm: 0.0,
            sdnn_ms: 0.0,
            rmssd_ms: 0.0,
            pnn50_pct: 0.0,
            pnn20_pct: 0.0,
            cvnn: 0.0,
            cvsd: 0.0,
            hti: 0.0,
            tinn_ms: 0.0,
            vlf_power: 0.0,
            lf_power: 0.0,
            hf_power: 0.0,
            total_power: 0.0,
            lf_n_pct: 0.0,
            hf_n_pct: 0.0,
            lf_hf_ratio: 0.0,
            sd1_ms: 0.0,
            sd2_ms: 0.0,
            sd1_sd2_ratio: 0.0,
            csi: 0.0,
            cvi: 0.0,
            samp_en: 0.0,
            apg_b_a_ratio: 0.0,
            apg_d_a_ratio: 0.0,
            apg_e_a_ratio: 0.0,
            morph_pulse_amp: 0.0,
            morph_sd_time_ratio: 0.0,
            sqi: 0.0,
        }
    }
}

pub fn extract_cardiac_features(signal: &[f64], srate: f64, modality: Modality) -> CardiacFeatures {
    if modality == Modality::None || signal.is_empty() || srate <= 0.0 {
        return CardiacFeatures::default();
    }

    let is_ppg = modality == Modality::Ppg;
    let peaks = if is_ppg {
        detect_ppg_peaks(signal, srate)
    } else {
        detect_ecg_peaks(signal, srate)
    };

    let hrv: HrvMetrics = compute_hrv_features(&peaks, srate);
    let morph: MorphologyMetrics = extract_advanced_morphology(signal, &peaks, srate, is_ppg);
    let sqi = crate::sqi::compute_channel_sqi(signal, srate, modality.as_str());

    CardiacFeatures {
        modality: modality.as_str().to_string(),
        num_peaks: peaks.len(),
        mean_rr_ms: hrv.mean_rr,
        avg_hr_bpm: hrv.avg_hr_bpm,
        sdnn_ms: hrv.sdnn,
        rmssd_ms: hrv.rmssd,
        pnn50_pct: hrv.pnn50,
        pnn20_pct: hrv.pnn20,
        cvnn: hrv.cvnn,
        cvsd: hrv.cvsd,
        hti: hrv.hti,
        tinn_ms: hrv.tinn,
        vlf_power: hrv.vlf_power,
        lf_power: hrv.lf_power,
        hf_power: hrv.hf_power,
        total_power: hrv.total_power,
        lf_n_pct: hrv.lf_n,
        hf_n_pct: hrv.hf_n,
        lf_hf_ratio: hrv.lf_hf_ratio,
        sd1_ms: hrv.sd1,
        sd2_ms: hrv.sd2,
        sd1_sd2_ratio: hrv.sd1_sd2_ratio,
        csi: hrv.csi,
        cvi: hrv.cvi,
        samp_en: hrv.samp_en,
        apg_b_a_ratio: morph.apg_b_a_ratio,
        apg_d_a_ratio: morph.apg_d_a_ratio,
        apg_e_a_ratio: morph.apg_e_a_ratio,
        morph_pulse_amp: morph.morph_pulse_amp,
        morph_sd_time_ratio: morph.morph_sd_time_ratio,
        sqi,
    }
}
