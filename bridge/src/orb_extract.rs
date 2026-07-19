//! ORBIT `.orb` feature extraction — lets NeuroYukti use the CCS spectral
//! feature engine as an alternative to the ORBIT engine.
//!
//! Parses an `.orb` recording (AF7 = `A`, AF8 = `B`, PPG = `E`), runs the CCS
//! Welch/bandpower pipeline over sliding windows, and emits a payload with the
//! SAME shape NeuroYukti already consumes from the ORBIT engine
//! (`{rows, windows, elapsedMs}`).
//!
//! The window -> cognitive-metric mapping in `map_window` is an EXPERIMENTAL
//! default built from standard EEG band ratios. It is intentionally isolated so
//! it can be tuned without touching parsing or the FFI surface.

use crate::features::{acw50, bandpowers};
use regex::Regex;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::sync::OnceLock;
use std::time::Instant;

const SAMPLE_RATE: f64 = 250.0;
const WINDOW_SECONDS: f64 = 30.0;
const STEP_SECONDS: f64 = 4.0;
const EPOCH_SECONDS: f64 = 4.0;

struct OrbSamples {
    af7: Vec<f64>,
    af8: Vec<f64>,
}

fn object_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\{[^{}]*\}").unwrap())
}

fn key_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"([\{,]\s*)([A-Za-z]+)(\s*:)").unwrap())
}

/// Parse every sample object in the file, in order, and concatenate the AF7
/// (`A`) / AF8 (`B`) channels. Handles both quoted (`{"A":[..]}`) and bare
/// (`{A:[..]}`) keys, matching the reference ORBIT parser.
fn parse_orb(path: &str) -> Result<OrbSamples, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("read .orb: {e}"))?;
    let mut af7 = Vec::new();
    let mut af8 = Vec::new();

    for m in object_re().find_iter(&text) {
        // Quote bare identifier keys so the object is strict JSON.
        let fixed = key_re().replace_all(m.as_str(), r#"$1"$2"$3"#);
        let value: serde_json::Value = match serde_json::from_str(&fixed) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let a = num_array(value.get("A"));
        let b = num_array(value.get("B"));
        let n = a.len().min(b.len());
        if n > 0 {
            af7.extend_from_slice(&a[..n]);
            af8.extend_from_slice(&b[..n]);
        }
    }

    if af7.is_empty() {
        return Err("No AF7/AF8 samples found in .orb file".to_string());
    }
    Ok(OrbSamples { af7, af8 })
}

fn num_array(value: Option<&serde_json::Value>) -> Vec<f64> {
    match value {
        Some(serde_json::Value::Array(items)) => {
            items.iter().map(|e| e.as_f64().unwrap_or(0.0)).collect()
        }
        Some(serde_json::Value::Number(n)) => vec![n.as_f64().unwrap_or(0.0)],
        _ => Vec::new(),
    }
}

fn variance(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / values.len() as f64
}

/// Average two channels' band-power maps.
fn avg_bandpowers(af7: &[f64], af8: &[f64]) -> BTreeMap<String, f64> {
    let a = bandpowers(af7, SAMPLE_RATE);
    let b = bandpowers(af8, SAMPLE_RATE);
    let mut out = BTreeMap::new();
    for (k, va) in &a {
        let vb = b.get(k).copied().unwrap_or(*va);
        out.insert(k.clone(), (va + vb) / 2.0);
    }
    out
}

struct MappedWindow {
    time_seconds: f64,
    cognitive_speed: f64,
    cognitive_agility: f64,
    intensity: f64,
    efficiency: f64,
    state: String,
    quality_ok: bool,
    epoch_count: usize,
}

/// EXPERIMENTAL band-ratio -> cognitive-metric mapping. Tune here.
fn map_window(bp: &BTreeMap<String, f64>, time_seconds: f64, quality_ok: bool) -> MappedWindow {
    let g = |k: &str| bp.get(k).copied().unwrap_or(0.0);
    let delta = g("Delta_PSD");
    let theta = g("Theta_PSD");
    let alpha = g("Alpha_PSD");
    let beta = g("Beta1_PSD") + g("Beta2_PSD");
    let gamma = g("Gamma1_PSD");
    let eps = 1e-9;

    // Sanitize non-finite (flat/zero-power windows) to keep the JSON strictly
    // numeric — serde would otherwise emit `null` and break the host's cast.
    let fin = |x: f64| if x.is_finite() { x } else { 0.0 };

    // Ratios scaled to a 0..100-ish range for the trend charts.
    let efficiency = fin(alpha / (theta + beta + eps) * 100.0).clamp(0.0, 100.0);
    let intensity = fin((beta + gamma) * 100.0).clamp(0.0, 100.0);
    let cognitive_speed = fin(gamma / (delta + theta + eps) * 100.0).clamp(0.0, 100.0);
    let cognitive_agility = fin(beta / (alpha + eps) * 100.0).clamp(0.0, 100.0);

    // Dominant-band label as a coarse "state".
    let mut bands = [
        ("Delta", delta),
        ("Theta", theta),
        ("Alpha", alpha),
        ("Beta", beta),
        ("Gamma", gamma),
    ];
    bands.sort_by(|a, b| b.1.total_cmp(&a.1));
    let state = format!("{}-dominant", bands[0].0);

    MappedWindow {
        time_seconds,
        cognitive_speed,
        cognitive_agility,
        intensity,
        efficiency,
        state,
        quality_ok,
        epoch_count: (WINDOW_SECONDS / EPOCH_SECONDS).floor() as usize,
    }
}

pub fn extract_orb_features_json(orb_path: &str) -> Result<String, String> {
    let started = Instant::now();
    let samples = parse_orb(orb_path)?;

    let win = (WINDOW_SECONDS * SAMPLE_RATE) as usize;
    let step = (STEP_SECONDS * SAMPLE_RATE) as usize;
    if samples.af7.len() < win {
        return Err("Recording is too short for CCS window extraction".to_string());
    }

    let mut windows = Vec::new();
    let mut start = 0usize;
    while start + win <= samples.af7.len() {
        let af7 = &samples.af7[start..start + win];
        let af8 = &samples.af8[start..start + win];
        let quality_ok = variance(af7) > 1e-6 && variance(af8) > 1e-6;
        let bp = avg_bandpowers(af7, af8);
        let time_seconds = start as f64 / SAMPLE_RATE;
        windows.push(map_window(&bp, time_seconds, quality_ok));
        start += step;
    }

    // Session-level rows from the whole recording.
    let session_bp = avg_bandpowers(&samples.af7, &samples.af8);
    let duration_seconds = samples.af7.len() as f64 / SAMPLE_RATE;
    let acw = acw50(&samples.af7, SAMPLE_RATE);

    let mut rows = vec![
        serde_json::json!({"metric": "Engine", "value": "CCS EEG Studio (experimental)"}),
        serde_json::json!({"metric": "File", "value": orb_path.rsplit('/').next().unwrap_or(orb_path)}),
        serde_json::json!({"metric": "Duration", "value": format!("{:.1}s", duration_seconds)}),
        serde_json::json!({"metric": "Windows", "value": format!("{}", windows.len())}),
        serde_json::json!({"metric": "ACW50 (AF7)", "value": format!("{:.3}", acw)}),
    ];
    for (band, power) in &session_bp {
        rows.push(serde_json::json!({
            "metric": band.replace("_PSD", " (rel. power)"),
            "value": format!("{:.4}", power),
        }));
    }

    let out = serde_json::json!({
        "rows": rows,
        "windows": windows.iter().map(|w| serde_json::json!({
            "timeSeconds": w.time_seconds,
            "cognitiveSpeed": w.cognitive_speed,
            "cognitiveAgility": w.cognitive_agility,
            "intensity": w.intensity,
            "efficiency": w.efficiency,
            "state": w.state,
            "qualityOk": w.quality_ok,
            "epochCount": w.epoch_count,
        })).collect::<Vec<_>>(),
        "elapsedMs": started.elapsed().as_millis(),
    });
    serde_json::to_string(&out).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// C ABI — mirrors the ORBIT SDK so NeuroYukti can load it over FFI on mobile.
// ---------------------------------------------------------------------------

/// Extract CCS features from an `.orb` file. Returns a JSON string (free with
/// `ccs_eeg_free_string`). On error returns `{"error": "..."}`.
#[no_mangle]
pub extern "C" fn ccs_eeg_extract_orb_json(orb_path: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| unsafe {
        if orb_path.is_null() {
            return Err("null path".to_string());
        }
        let path = CStr::from_ptr(orb_path)
            .to_str()
            .map_err(|_| "invalid utf8 path".to_string())?;
        extract_orb_features_json(path)
    });
    let json = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => serde_json::json!({ "error": error }).to_string(),
        Err(_) => serde_json::json!({ "error": "CCS engine panicked" }).to_string(),
    };
    CString::new(json).unwrap().into_raw()
}

/// Free a string returned by this library.
#[no_mangle]
pub extern "C" fn ccs_eeg_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe { drop(CString::from_raw(ptr)) };
}
