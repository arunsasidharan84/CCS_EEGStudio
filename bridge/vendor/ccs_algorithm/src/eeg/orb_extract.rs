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

use crate::cardiac::{extract_cardiac_features, CardiacFeatures, Modality};
use crate::eeg::features::{acw50, bandpowers};
use crate::eeg::nonlinear;
use crate::eeg::spectral::{fooof_features, irasa_features};
use regex::Regex;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::sync::OnceLock;
use std::time::Instant;

const SAMPLE_RATE: f64 = 250.0;
const PPG_SAMPLE_RATE: f64 = 62.5;
const WINDOW_SECONDS: f64 = 30.0;
const STEP_SECONDS: f64 = 4.0;
const EPOCH_SECONDS: f64 = 4.0;

struct OrbSamples {
    af7: Vec<f64>,
    af8: Vec<f64>,
    ppg: Vec<f64>,
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
    let mut ppg = Vec::new();

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
        let e = num_array(value.get("E"));
        if e.len() == 1 {
            ppg.push(e[0]);
        } else if !e.is_empty() {
            // ORBIT normally emits one 62.5 Hz PPG sample beside four 250 Hz
            // EEG samples. Defensive fixtures may provide PPG at EEG rate;
            // retain one native-timebase value per four samples.
            for chunk in e.chunks(4) {
                ppg.push(chunk.iter().sum::<f64>() / chunk.len() as f64);
            }
        }
    }

    if af7.is_empty() {
        return Err("No AF7/AF8 samples found in .orb file".to_string());
    }
    Ok(OrbSamples { af7, af8, ppg })
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

fn median_finite(mut values: Vec<f64>) -> Option<f64> {
    values.retain(|value| value.is_finite());
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let middle = values.len() / 2;
    Some(if values.len().is_multiple_of(2) {
        (values[middle - 1] + values[middle]) / 2.0
    } else {
        values[middle]
    })
}

fn representative_eeg_epochs(signal: &[f64]) -> Vec<&[f64]> {
    let epoch = (4.0 * SAMPLE_RATE) as usize;
    let epoch_count = signal.len() / epoch;
    if epoch_count == 0 {
        return Vec::new();
    }
    let selected = epoch_count.min(12);
    (0..selected)
        .filter_map(|index| {
            let epoch_index = if selected == 1 {
                0
            } else {
                index * (epoch_count - 1) / (selected - 1)
            };
            let values = &signal[epoch_index * epoch..(epoch_index + 1) * epoch];
            (variance(values) > 1e-6).then_some(values)
        })
        .collect()
}

/// Exact representative epoch set used by session-level nonlinear summaries,
/// exposed so downstream audit exports can reproduce values such as DFA.
fn nonlinear_audit_epochs(signal: &[f64], channel: &str) -> Vec<serde_json::Value> {
    let epoch = (4.0 * SAMPLE_RATE) as usize;
    let epoch_count = signal.len() / epoch;
    if epoch_count == 0 {
        return Vec::new();
    }
    let selected = epoch_count.min(12);
    (0..selected)
        .filter_map(|representative_index| {
            let source_index = if selected == 1 {
                0
            } else {
                representative_index * (epoch_count - 1) / (selected - 1)
            };
            let values = &signal[source_index * epoch..(source_index + 1) * epoch];
            if variance(values) <= 1e-6 {
                return None;
            }
            let mut row = serde_json::Map::new();
            row.insert("channel".to_string(), serde_json::json!(channel));
            row.insert(
                "representativeEpochNumber".to_string(),
                serde_json::json!(representative_index + 1),
            );
            row.insert(
                "sourceEpochNumber".to_string(),
                serde_json::json!(source_index + 1),
            );
            row.insert(
                "timeSeconds".to_string(),
                serde_json::json!(source_index as f64 * 4.0),
            );
            row.insert(
                "EEG_SQI_percent".to_string(),
                serde_json::json!(crate::sqi::eeg_epoch_quality(values) * 100.0),
            );
            for (name, value) in nonlinear::all(values) {
                if value.is_finite() {
                    row.insert(nonlinear_label(name).to_string(), serde_json::json!(value));
                }
            }
            Some(serde_json::Value::Object(row))
        })
        .collect()
}

/// Median nonlinear features from at most twelve representative clean 4-second
/// epochs. Sample entropy is quadratic in epoch length, so applying it to an
/// entire multi-minute recording would add load without improving temporal
/// robustness.
fn nonlinear_summary(signal: &[f64]) -> BTreeMap<&'static str, f64> {
    let mut collected: BTreeMap<&'static str, Vec<f64>> = BTreeMap::new();
    for values in representative_eeg_epochs(signal) {
        for (name, value) in nonlinear::all(values) {
            if value.is_finite() {
                collected.entry(name).or_default().push(value);
            }
        }
    }
    collected
        .into_iter()
        .filter_map(|(name, values)| median_finite(values).map(|value| (name, value)))
        .collect()
}

fn add_metric(rows: &mut Vec<serde_json::Value>, name: &str, value: f64, decimals: usize) {
    if value.is_finite() {
        rows.push(serde_json::json!({
            "metric": name,
            "value": format!("{value:.decimals$}"),
        }));
    }
}

fn nonlinear_label(name: &str) -> &'static str {
    match name {
        "perm_entropy_nonlinear" => "Permutation Entropy",
        "svd_entropy_nonlinear" => "SVD Entropy",
        "sample_entropy_nonlinear" => "Sample Entropy",
        "dfa_nonlinear" => "DFA",
        "petrosian_nonlinear" => "Petrosian Fractal Dimension",
        "katz_nonlinear" => "Katz Fractal Dimension",
        "higuchi_nonlinear" => "Higuchi Fractal Dimension",
        "lziv_nonlinear" => "Lempel-Ziv Complexity",
        _ => "Nonlinear Feature",
    }
}

fn add_eeg_features(
    rows: &mut Vec<serde_json::Value>,
    signal: &[f64],
    channel: &str,
    duration_seconds: f64,
) {
    let epochs = representative_eeg_epochs(signal);
    if let Some(value) = median_finite(
        epochs
            .iter()
            .map(|epoch| acw50(epoch, SAMPLE_RATE))
            .collect(),
    ) {
        add_metric(rows, &format!("ACW50 ({channel})"), value, 4);
    }
    if let Some(value) = median_finite(
        epochs
            .iter()
            .map(|epoch| crate::sqi::eeg_epoch_quality(epoch) * 100.0)
            .collect(),
    ) {
        add_metric(rows, &format!("EEG SQI ({channel}, %)"), value, 2);
    }
    for (band, value) in bandpowers(signal, SAMPLE_RATE) {
        add_metric(
            rows,
            &format!("{} (rel. power, {channel})", band.replace("_PSD", "")),
            value,
            6,
        );
    }
    if duration_seconds >= 30.0 {
        for (name, value) in nonlinear_summary(signal) {
            add_metric(
                rows,
                &format!("{} ({channel})", nonlinear_label(name)),
                value,
                6,
            );
        }
    }
    // Stable spectral decomposition needs more data than ordinary Welch band
    // power. One minute is a conservative lower bound for these summaries.
    if duration_seconds >= 60.0 {
        let fooof = fooof_features(signal, SAMPLE_RATE);
        for (key, label) in [
            ("exponent_FOOOF", "FOOOF Aperiodic Exponent"),
            ("r_squared_FOOOF", "FOOOF Fit R²"),
            ("oscspectraledge_FOOOF", "FOOOF Oscillatory Edge (Hz)"),
        ] {
            if let Some(value) = fooof.get(key) {
                add_metric(rows, &format!("{label} ({channel})"), *value, 6);
            }
        }
        let irasa = irasa_features(signal, SAMPLE_RATE);
        for (key, label) in [
            ("slope_Irasa", "IRASA Aperiodic Slope"),
            ("rsquared_Irasa", "IRASA Fit R²"),
            ("oscspectraledge_Irasa", "IRASA Oscillatory Edge (Hz)"),
        ] {
            if let Some(value) = irasa.get(key) {
                add_metric(rows, &format!("{label} ({channel})"), *value, 6);
            }
        }
    }
}

fn add_cardiac_features(
    rows: &mut Vec<serde_json::Value>,
    cardiac: &CardiacFeatures,
    duration_seconds: f64,
) {
    if duration_seconds < 30.0 || cardiac.num_peaks < 20 {
        return;
    }
    add_metric(rows, "Detected Pulse Count", cardiac.num_peaks as f64, 0);
    add_metric(rows, "Heart Rate (bpm)", cardiac.avg_hr_bpm, 3);
    add_metric(rows, "Mean RR (ms)", cardiac.mean_rr_ms, 3);
    add_metric(rows, "PPG SQI (%)", cardiac.sqi * 100.0, 2);
    add_metric(rows, "APG b/a Ratio", cardiac.apg_b_a_ratio, 6);
    add_metric(rows, "APG d/a Ratio", cardiac.apg_d_a_ratio, 6);
    add_metric(rows, "APG e/a Ratio", cardiac.apg_e_a_ratio, 6);
    add_metric(rows, "Pulse Amplitude", cardiac.morph_pulse_amp, 6);
    add_metric(
        rows,
        "Systolic/Diastolic Time Ratio",
        cardiac.morph_sd_time_ratio,
        6,
    );

    // Ultra-short time-domain HRV is retained from one minute onward.
    if duration_seconds >= 60.0 && cardiac.num_peaks >= 40 {
        add_metric(rows, "RMSSD (ms)", cardiac.rmssd_ms, 3);
        add_metric(rows, "pNN20 (%)", cardiac.pnn20_pct, 3);
        add_metric(rows, "pNN50 (%)", cardiac.pnn50_pct, 3);
        add_metric(rows, "CVSD", cardiac.cvsd, 6);
        add_metric(rows, "HRV Sample Entropy", cardiac.samp_en, 6);
    }

    // Two minutes supports a qualified short-recording estimate of slower HRV
    // and Poincare/frequency-domain measures. VLF remains excluded here.
    if duration_seconds >= 120.0 && cardiac.num_peaks >= 80 {
        add_metric(rows, "SDNN (ms)", cardiac.sdnn_ms, 3);
        add_metric(rows, "CVNN", cardiac.cvnn, 6);
        add_metric(rows, "HRV Triangular Index", cardiac.hti, 6);
        add_metric(rows, "TINN (ms)", cardiac.tinn_ms, 3);
        if cardiac.lf_power > 0.0 && cardiac.hf_power > 0.0 && cardiac.lf_hf_ratio > 0.0 {
            add_metric(rows, "LF Power", cardiac.lf_power, 10);
            add_metric(rows, "HF Power", cardiac.hf_power, 10);
            add_metric(rows, "LF Normalized (%)", cardiac.lf_n_pct, 3);
            add_metric(rows, "HF Normalized (%)", cardiac.hf_n_pct, 3);
            add_metric(rows, "LF/HF Ratio", cardiac.lf_hf_ratio, 6);
        }
        add_metric(rows, "Poincare SD1 (ms)", cardiac.sd1_ms, 3);
        add_metric(rows, "Poincare SD2 (ms)", cardiac.sd2_ms, 3);
        add_metric(rows, "Poincare SD1/SD2", cardiac.sd1_sd2_ratio, 6);
        add_metric(rows, "Cardiac Sympathetic Index", cardiac.csi, 6);
        add_metric(rows, "Cardiac Vagal Index", cardiac.cvi, 6);
    }

    // VLF and total power need a conventional five-minute short-term record.
    if duration_seconds >= 300.0 && cardiac.num_peaks >= 180 {
        add_metric(rows, "VLF Power", cardiac.vlf_power, 6);
        add_metric(rows, "HRV Total Power", cardiac.total_power, 6);
    }
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

    // Do not reject a whole recording merely because it is shorter than the
    // preferred 30-second trend window. Four seconds is enough for the basic
    // band-power/ACW summaries; longer-duration feature families are gated
    // independently below.
    let minimum = (EPOCH_SECONDS * SAMPLE_RATE) as usize;
    if samples.af7.len() < minimum {
        return Err("Recording is shorter than the 4-second CCS minimum".to_string());
    }
    let preferred_window = (WINDOW_SECONDS * SAMPLE_RATE) as usize;
    let win = preferred_window.min(samples.af7.len());
    let step = (STEP_SECONDS * SAMPLE_RATE) as usize;

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
    let mut rows = vec![
        serde_json::json!({"metric": "Engine", "value": "CCS EEG Studio (experimental)"}),
        serde_json::json!({"metric": "File", "value": orb_path.rsplit('/').next().unwrap_or(orb_path)}),
        serde_json::json!({"metric": "Duration", "value": format!("{:.1}s", duration_seconds)}),
        serde_json::json!({"metric": "Windows", "value": format!("{}", windows.len())}),
    ];
    // Preserve the original averaged band rows for backwards compatibility,
    // then expose channel-resolved and nonlinear summaries.
    for (band, power) in &session_bp {
        rows.push(serde_json::json!({
            "metric": band.replace("_PSD", " (rel. power)"),
            "value": format!("{:.4}", power),
        }));
    }
    add_eeg_features(&mut rows, &samples.af7, "AF7", duration_seconds);
    add_eeg_features(&mut rows, &samples.af8, "AF8", duration_seconds);

    let ppg_duration_seconds = samples.ppg.len() as f64 / PPG_SAMPLE_RATE;
    if !samples.ppg.is_empty() {
        let cardiac = extract_cardiac_features(&samples.ppg, PPG_SAMPLE_RATE, Modality::Ppg);
        add_cardiac_features(&mut rows, &cardiac, ppg_duration_seconds);
    }

    let audit_epochs = nonlinear_audit_epochs(&samples.af7, "AF7")
        .into_iter()
        .chain(nonlinear_audit_epochs(&samples.af8, "AF8"))
        .collect::<Vec<_>>();

    let out = serde_json::json!({
        "rows": rows,
        "auditEpochs": audit_epochs,
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
        "validity": {
            "eegDurationSeconds": duration_seconds,
            "ppgDurationSeconds": ppg_duration_seconds,
            "channels": ["AF7", "AF8", if samples.ppg.is_empty() { "" } else { "PPG" }],
            "vlfMinimumSeconds": 300,
            "frequencyHrvMinimumSeconds": 120,
            "timeDomainHrvMinimumSeconds": 60,
        },
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

#[cfg(test)]
mod tests {
    use super::*;

    fn metric_names(rows: &[serde_json::Value]) -> Vec<&str> {
        rows.iter()
            .filter_map(|row| row.get("metric")?.as_str())
            .collect()
    }

    #[test]
    fn cardiac_metrics_follow_duration_and_peak_validity() {
        let cardiac = CardiacFeatures {
            num_peaks: 200,
            avg_hr_bpm: 65.0,
            mean_rr_ms: 923.0,
            rmssd_ms: 32.0,
            sdnn_ms: 40.0,
            vlf_power: 1.0,
            total_power: 3.0,
            ..CardiacFeatures::default()
        };

        let mut rows = Vec::new();
        add_cardiac_features(&mut rows, &cardiac, 45.0);
        let names = metric_names(&rows);
        assert!(names.contains(&"Heart Rate (bpm)"));
        assert!(!names.contains(&"RMSSD (ms)"));

        rows.clear();
        add_cardiac_features(&mut rows, &cardiac, 90.0);
        let names = metric_names(&rows);
        assert!(names.contains(&"RMSSD (ms)"));
        assert!(!names.contains(&"SDNN (ms)"));

        rows.clear();
        add_cardiac_features(&mut rows, &cardiac, 180.0);
        let names = metric_names(&rows);
        assert!(names.contains(&"SDNN (ms)"));
        assert!(!names.contains(&"VLF Power"));

        rows.clear();
        add_cardiac_features(&mut rows, &cardiac, 300.0);
        let names = metric_names(&rows);
        assert!(names.contains(&"VLF Power"));
    }
}
