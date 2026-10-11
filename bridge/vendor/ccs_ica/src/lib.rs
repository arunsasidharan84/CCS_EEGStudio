//! `ccs_ica` — Rust port of the ICA and ICLabel steps of the CCS EEG cleaning pipeline
//! (`accs_CCScleaningpipeline.m`): EEGLAB `pop_runica`/`runica` (Infomax) and the ICLabel classifier.

pub mod asr;
pub mod autoremove;
pub mod blink;
pub mod cli;
pub mod io;
pub mod linalg;
pub mod iclabel;
pub mod pipeline;
pub mod pop_runica;
pub mod picard;
pub mod resample;
pub mod rng;
pub mod runica;
pub mod special;
pub mod studio;
pub mod yulewalk;

pub mod decomp;
pub mod variants;
pub mod butter;
