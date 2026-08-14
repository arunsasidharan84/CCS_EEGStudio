//! CCS EEG Studio Bridge Engine
//! Uses `ccs_algorithm` SDK crate as core extraction & preprocessing backend.

pub use ccs_algorithm::eeg::*;
pub use ccs_algorithm::{cardiac, coupled, sqi};

pub mod microstates;
pub mod stats;
