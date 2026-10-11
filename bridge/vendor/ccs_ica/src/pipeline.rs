//! The two ICA stages of `accs_CCScleaningpipeline.m`:
//!
//! * `ica1_blink_ecg`  (`accs_eyeblinkremoval.m`): ICA on (up to `nepochs`) blink-locked 2 s epochs of the
//!   1 Hz high-passed data, ICLabel, dynamic Eye/Heart threshold, projection removal from the original data.
//! * `ica2_other` (`pop_runica` + `pop_iclabel` + `accs_autoICAremoval.m`): ICA on the cleaned continuous data,
//!   ICLabel, dynamic threshold on Muscle / Line Noise / Channel Noise, projection removal.
//!
//! Blink detection, epoching, high-pass filtering and ASR are upstream preprocessing steps that are *inputs*
//! here (they are not part of the ICA/ICLabel stage).

use crate::autoremove::*;
use crate::iclabel::{iclabel, ChanLoc, Eeg};
use crate::linalg::*;
use crate::pop_runica::{pop_runica, IcaResult};
use crate::rng::Rng;
use crate::runica::{RunicaOpts, Sphering};

#[derive(Debug)]
pub struct StageResult {
    pub ica: IcaResult,
    pub classifications: Mat,
    pub selection: Selection,
    /// Cleaned data (same shape as the target data).
    pub clean: Mat,
    pub icaweights_after: Mat,
    pub icawinv_after: Mat,
}

/// ICA algorithm used by the pipeline stages.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IcaMethod {
    /// EEGLAB `runica` (Infomax) through `pop_runica`.
    Runica,
    /// Picard (python-picard / eegprep settings: `ortho=False`, `m=10`, `max_iter=512`).
    Picard,
}

/// Fit ICA with the requested algorithm (`pop_runica` or `pop_picard`).
pub fn fit_ica(method: IcaMethod, data: &Mat, ro: &RunicaOpts, rng: &mut dyn Rng) -> Result<IcaResult, String> {
    match method {
        IcaMethod::Runica => pop_runica(data, None, ro, rng),
        IcaMethod::Picard => {
            let mut po = crate::picard::PicardOpts::default();
            po.ortho = false;
            po.m = 10;
            po.max_iter = 512;
            crate::picard::pop_picard(data, None, &po)
        }
    }
}

pub struct Ica2Opts {
    pub method: IcaMethod,
    pub extended: i64,
    pub sphering: Sphering,
    pub maxsteps: Option<usize>,
    pub threshold: Vec<f64>,
    pub removecomp: bool,
    pub artefacts: Vec<String>,
    pub maxcomp2rem: f64,
    pub maxsig2rem: f64,
}

impl Default for Ica2Opts {
    fn default() -> Self {
        Ica2Opts {
            method: IcaMethod::Runica,
            extended: 0,
            sphering: Sphering::Off,
            maxsteps: None,
            threshold: vec![0.99, 0.60],
            removecomp: true,
            artefacts: vec!["Muscle".into(), "Line Noise".into(), "Channel Noise".into()],
            maxcomp2rem: 0.1,
            maxsig2rem: 0.3,
        }
    }
}

fn attach(eeg: &mut Eeg, ica: &IcaResult) {
    eeg.icaweights = ica.icaweights.clone();
    eeg.icasphere = ica.icasphere.clone();
    eeg.icawinv = ica.icawinv.clone();
    eeg.icachansind = ica.icachansind.clone();
}

/// ICA step 2.  `fit_data` is `tempEEG.data` (high-passed, ASR-cleaned, interpolated); `target` is `EEG` (the data
/// the weights are attached to, ICLabel is evaluated on and which is finally cleaned).
pub fn ica2_other(
    fit_data: &Mat,
    target: &Eeg,
    o: &Ica2Opts,
    rng: &mut dyn Rng,
) -> Result<StageResult, String> {
    let mut ro = RunicaOpts::default();
    ro.extended = o.extended;
    ro.sphering = o.sphering;
    if let Some(m) = o.maxsteps {
        ro.maxsteps = m;
    }
    let ica = fit_ica(o.method, fit_data, &ro, rng)?;
    let mut eeg = target.clone();
    attach(&mut eeg, &ica);
    // pop_iclabel twice in the MATLAB pipeline (accs_autoICAremoval repeats it because of an inverted isfield test);
    // the result is deterministic so one evaluation is equivalent.
    let classif = iclabel(&eeg)?;
    let sel = auto_ica_selection(&classif, eeg.data.nrows(), &o.threshold, &o.artefacts, o.maxcomp2rem, o.maxsig2rem)?;
    let (clean, w2, v2) = if o.removecomp {
        pop_subcomp(&eeg.data, &eeg.icaweights, &eeg.icasphere, &eeg.icawinv, &eeg.icachansind, &sel.comp2remove)?
    } else {
        (eeg.data.clone(), eeg.icaweights.clone(), eeg.icawinv.clone())
    };
    Ok(StageResult { ica, classifications: classif, selection: sel, clean, icaweights_after: w2, icawinv_after: v2 })
}

pub struct Ica1Opts {
    pub method: IcaMethod,
    pub nsteps: usize,
    pub threshold: Vec<f64>,
    pub removeecg: bool,
    pub removecomp: bool,
}

impl Default for Ica1Opts {
    fn default() -> Self {
        Ica1Opts { method: IcaMethod::Runica, nsteps: 50, threshold: vec![0.99, 0.60], removeecg: true, removecomp: true }
    }
}

/// ICA step 1.  `epochs` is the (`nbchan x (pnts*trials)`) selection of blink epochs from the 1 Hz high-passed data,
/// `target_data` the original `EEGdata` the blink components are projected out of.
pub fn ica1_blink_ecg(
    epochs: &Mat,
    pnts: usize,
    trials: usize,
    srate: f64,
    chanlocs: &[ChanLoc],
    target_data: &Mat,
    o: &Ica1Opts,
    rng: &mut dyn Rng,
) -> Result<StageResult, String> {
    let mut ro = RunicaOpts::default();
    ro.extended = 0;
    ro.maxsteps = o.nsteps;
    ro.stop = Some(0.01);
    ro.sphering = Sphering::Off;
    let ica = fit_ica(o.method, epochs, &ro, rng)?;
    let mut ep = Eeg {
        data: epochs.clone(),
        pnts,
        trials,
        srate,
        chanlocs: chanlocs.to_vec(),
        icaweights: Mat::zeros(0, 0),
        icasphere: Mat::zeros(0, 0),
        icawinv: Mat::zeros(0, 0),
        icachansind: vec![],
        reference: "common".to_string(),
    };
    attach(&mut ep, &ica);
    let classif = iclabel(&ep)?;
    let sel = eyeblink_selection(&classif, chanlocs.len(), &o.threshold, o.removeecg)?;
    let (clean, w2, v2) = if o.removecomp && !sel.comp2remove.is_empty() {
        pop_subcomp(target_data, &ica.icaweights, &ica.icasphere, &ica.icawinv, &ica.icachansind, &sel.comp2remove)?
    } else {
        (target_data.clone(), ica.icaweights.clone(), ica.icawinv.clone())
    };
    Ok(StageResult { ica, classifications: classif, selection: sel, clean, icaweights_after: w2, icawinv_after: v2 })
}
