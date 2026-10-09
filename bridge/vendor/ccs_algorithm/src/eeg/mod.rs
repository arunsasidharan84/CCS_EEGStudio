use serde::{Deserialize, Serialize};

pub use features::BANDS;

pub fn default_true() -> bool {
    true
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Options {
    pub mode: String,
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub bin_seconds: f64,
    pub psd: bool,
    pub fooof: bool,
    pub irasa: bool,
    pub nonlinear: bool,
    pub acw: bool,
    pub connectivity: bool,
    #[serde(default)]
    pub mic: bool,
    #[serde(default)]
    pub mim: bool,
    #[serde(default)]
    pub gc: bool,
    #[serde(default)]
    pub gc_tr: bool,
    #[serde(default)]
    pub coh: bool,
    #[serde(default)]
    pub plv: bool,
    #[serde(default)]
    pub ciplv: bool,
    #[serde(default)]
    pub pli: bool,
    #[serde(default)]
    pub wpli: bool,
    #[serde(default = "default_true")]
    pub remove_non_eeg: bool,
    /// Explicit non-EEG channel labels resolved by the UI. When non-empty the
    /// engine drops exactly these channels and does not apply its own name
    /// heuristics, so UI and engine can never disagree about what is EEG.
    #[serde(default)]
    pub non_eeg_channels: Vec<String>,
}

impl Options {
    pub fn connectivity_test() -> Self {
        Self {
            mode: "full".into(),
            start_seconds: 0.0,
            end_seconds: 1.0,
            bin_seconds: 1.0,
            psd: false,
            fooof: false,
            irasa: false,
            nonlinear: false,
            acw: false,
            connectivity: true,
            mic: true,
            mim: true,
            gc: true,
            gc_tr: true,
            coh: true,
            plv: true,
            ciplv: true,
            pli: true,
            wpli: true,
            remove_non_eeg: false,
            non_eeg_channels: Vec::new(),
        }
    }
}

pub struct Recording {
    pub rate: f64,
    pub labels: Vec<String>,
    pub channels: Vec<Vec<f32>>,
    pub source_epoch_samples: Option<usize>,
    pub epoch_labels: Option<Vec<String>>,
}

#[derive(Clone)]
pub struct Row {
    pub values: Vec<f64>,
    pub channel: String,
    pub epoch: usize,
    pub bin: usize,
    pub start: f64,
    pub end: f64,
    pub epoch_label: Option<String>,
}

pub mod connectivity;
pub mod features;
pub mod fif_loader;
pub mod montage;
pub mod nonlinear;
pub mod orb_extract;
pub mod preprocessing;
pub mod ransac;
pub mod set_loader;
pub mod signal;
pub mod source_loc;
pub mod spectral;
pub mod vhdr_loader;
