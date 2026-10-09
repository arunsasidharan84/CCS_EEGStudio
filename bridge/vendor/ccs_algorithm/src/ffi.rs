//! C ABI FFI surface for Python (`ctypes`), Dart/Flutter (`dart:ffi`), and external C/C++ apps.
//!
//! Exposes JSON-in / JSON-out functions (`ccs_compute_coupled_session_json`, `ccs_compute_cardiac_isolated_json`, etc.)
//! and memory management (`ccs_free_string`).

use crate::cardiac::{extract_cardiac_features, Modality};
use crate::coupled::{compute_coupled_session, compute_eeg_subepoch, CoupledEpochConfig};
use crate::eeg::Options;
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[derive(Deserialize)]
struct EegInputPayload {
    channels: Vec<Vec<f64>>,
    labels: Option<Vec<String>>,
    srate: Option<f64>,
}

#[derive(Deserialize)]
struct CardiacInputPayload {
    signal: Vec<f64>,
}

#[derive(Serialize)]
struct SqiOutputPayload {
    sqi: f64,
}

fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe {
        CStr::from_ptr(ptr)
            .to_str()
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
}

fn string_to_cptr(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Compute coupled multi-scale session features (`CoupledSessionResult`) from JSON payloads.
///
/// `config_json`: JSON string of `CoupledEpochConfig` (optional/null for default).
/// `eeg_json`: JSON string `{"channels": [[...], ...], "labels": ["Fz", ...], "srate": 250.0}` (optional/null if EEG disabled).
/// `cardiac_json`: JSON string `{"signal": [...]}` (optional/null if cardiac disabled).
#[no_mangle]
pub extern "C" fn ccs_compute_coupled_session_json(
    config_json: *const c_char,
    eeg_json: *const c_char,
    cardiac_json: *const c_char,
) -> *mut c_char {
    let mut config = cstr_to_string(config_json)
        .and_then(|s| serde_json::from_str::<CoupledEpochConfig>(&s).ok())
        .unwrap_or_default();

    let eeg_input =
        cstr_to_string(eeg_json).and_then(|s| serde_json::from_str::<EegInputPayload>(&s).ok());

    if let Some(ref e) = eeg_input {
        if let Some(sr) = e.srate {
            config.eeg_srate = sr;
        }
    } else {
        config.enable_eeg = false;
    }

    let cardiac_input = cstr_to_string(cardiac_json)
        .and_then(|s| serde_json::from_str::<CardiacInputPayload>(&s).ok());

    if cardiac_input.is_none() {
        config.enable_cardiac = false;
    }

    let eeg_channels = eeg_input.as_ref().map(|e| e.channels.as_slice());
    let eeg_labels = eeg_input
        .as_ref()
        .and_then(|e| e.labels.as_ref())
        .map(|l| l.as_slice());
    let cardiac_signal = cardiac_input.as_ref().map(|c| c.signal.as_slice());

    let result = compute_coupled_session(eeg_channels, eeg_labels, cardiac_signal, &config);

    match serde_json::to_string(&result) {
        Ok(json) => string_to_cptr(json),
        Err(e) => string_to_cptr(format!(r#"{{"error": "{}"}}"#, e)),
    }
}

/// Compute isolated EEG subepoch features for a slice of multi-channel EEG data.
#[no_mangle]
pub extern "C" fn ccs_compute_eeg_isolated_json(
    eeg_json: *const c_char,
    options_json: *const c_char,
) -> *mut c_char {
    let eeg_input = match cstr_to_string(eeg_json)
        .and_then(|s| serde_json::from_str::<EegInputPayload>(&s).ok())
    {
        Some(e) => e,
        None => {
            return string_to_cptr(r#"{"error": "Invalid or missing EEG payload"}"#.to_string())
        }
    };

    let options = cstr_to_string(options_json)
        .and_then(|s| serde_json::from_str::<Options>(&s).ok())
        .unwrap_or_else(Options::connectivity_test);

    let srate = eeg_input.srate.unwrap_or(250.0);
    let default_labels: Vec<String> = (0..eeg_input.channels.len())
        .map(|i| format!("EEG_{i}"))
        .collect();
    let labels = eeg_input.labels.as_ref().unwrap_or(&default_labels);

    let duration_sec = if !eeg_input.channels.is_empty() && srate > 0.0 {
        eeg_input.channels[0].len() as f64 / srate
    } else {
        0.0
    };

    let result = compute_eeg_subepoch(
        &eeg_input.channels,
        labels,
        srate,
        0.0,
        duration_sec,
        0,
        0,
        &options,
    );

    match serde_json::to_string(&result) {
        Ok(json) => string_to_cptr(json),
        Err(e) => string_to_cptr(format!(r#"{{"error": "{}"}}"#, e)),
    }
}

/// Compute isolated Cardiac (`PPG` or `ECG`) features (`CardiacFeatures`) over a single signal array.
#[no_mangle]
pub extern "C" fn ccs_compute_cardiac_isolated_json(
    signal_json: *const c_char,
    srate: f64,
    modality_str: *const c_char,
) -> *mut c_char {
    let cardiac_input = match cstr_to_string(signal_json)
        .and_then(|s| serde_json::from_str::<CardiacInputPayload>(&s).ok())
    {
        Some(c) => c,
        None => {
            return string_to_cptr(r#"{"error": "Invalid or missing cardiac payload"}"#.to_string())
        }
    };

    let mod_string = cstr_to_string(modality_str).unwrap_or_else(|| "PPG".to_string());
    let modality = Modality::from_str(&mod_string);

    let result = extract_cardiac_features(&cardiac_input.signal, srate, modality);

    match serde_json::to_string(&result) {
        Ok(json) => string_to_cptr(json),
        Err(e) => string_to_cptr(format!(r#"{{"error": "{}"}}"#, e)),
    }
}

/// Compute SQI (`[0, 1]`) for an isolated channel (`EEG`, `PPG`, or `ECG`).
#[no_mangle]
pub extern "C" fn ccs_compute_sqi_json(
    signal_json: *const c_char,
    srate: f64,
    modality_str: *const c_char,
) -> *mut c_char {
    let cardiac_input = match cstr_to_string(signal_json)
        .and_then(|s| serde_json::from_str::<CardiacInputPayload>(&s).ok())
    {
        Some(c) => c,
        None => {
            return string_to_cptr(r#"{"error": "Invalid or missing signal payload"}"#.to_string())
        }
    };

    let mod_string = cstr_to_string(modality_str).unwrap_or_else(|| "EEG".to_string());
    let sqi = crate::sqi::compute_channel_sqi(&cardiac_input.signal, srate, &mod_string);

    let payload = SqiOutputPayload { sqi };
    match serde_json::to_string(&payload) {
        Ok(json) => string_to_cptr(json),
        Err(e) => string_to_cptr(format!(r#"{{"error": "{}"}}"#, e)),
    }
}

/// Free a C string allocated by Rust (`ccs_compute_*_json`).
///
/// MUST be called from C/Python/Dart after reading the JSON string pointer to prevent memory leaks.
#[no_mangle]
pub extern "C" fn ccs_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
