//! Canonical Rust library and C ABI for `CCS_Algorithm`.
//!
//! Provides standalone modules for:
//! - `eeg`: Spectral (PSD/Welch, FOOOF, IRASA), non-linear, and functional connectivity features.
//! - `cardiac`: PPG/ECG pulse detection, time/frequency/non-linear HRV, and advanced morphology (`AnalyseRingData_v015.py` parity).
//! - `sqi`: Signal Quality Index for EEG, PPG, and ECG channels (`Orbit_Algorithm` parity).
//! - `coupled`: Multi-scale coupled windowing engine synchronizing subepoch EEG and macro-epoch cardiac records.
//! - `ffi`: JSON-based C ABI (`extern "C"`) compiling to `cdylib`/`staticlib` for mobile/desktop/Python integration.

pub mod cardiac;
pub mod coupled;
pub mod eeg;
pub mod ffi;
pub mod sqi;

pub use ffi::*;
