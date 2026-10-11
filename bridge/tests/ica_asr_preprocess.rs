//! Smoke tests for the ICA (runica / Picard + ICLabel + blink detection) and ASR options of `preprocessing::run`.
//! Numerical parity with MATLAB/EEGLAB is validated in `ccs_toolbox/rust_ica/validation`.
use ccs_eeg_engine::{preprocessing, Recording};

const LABELS: [&str; 16] = ["Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8", "C3", "Cz", "C4", "P3", "Pz", "P4", "O1", "O2", "T7"];

fn lcg(state: &mut u64) -> f64 {
    *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    ((*state >> 11) as f64 / (1u64 << 53) as f64) - 0.5
}

fn synthetic(seconds: usize, rate: f64) -> Recording {
    let n = (seconds as f64 * rate) as usize;
    let mut s = 7u64;
    let mut ch = vec![vec![0.0f32; n]; LABELS.len()];
    for c in 0..LABELS.len() {
        let phase = c as f64 * 0.7;
        for t in 0..n {
            let time = t as f64 / rate;
            let alpha = 8.0 * (2.0 * std::f64::consts::PI * 10.0 * time + phase).sin();
            ch[c][t] = (alpha + 6.0 * lcg(&mut s)) as f32;
        }
    }
    // blinks every 3 s, strongest on Fp1/Fp2
    let mut b = 2.0;
    while b < seconds as f64 - 2.0 {
        for t in 0..n {
            let d = t as f64 / rate - b;
            if d.abs() < 0.4 {
                let g = (-(d * d) / (2.0 * 0.07 * 0.07)).exp();
                for (c, w) in [(0usize, 120.0), (1, 110.0), (2, 40.0), (6, 35.0), (4, 30.0)] {
                    ch[c][t] += (w * g) as f32;
                }
            }
        }
        b += 3.0;
    }
    Recording { rate, labels: LABELS.iter().map(|l| l.to_string()).collect(), channels: ch, source_epoch_samples: None, epoch_labels: None }
}

fn options(extra: serde_json::Value) -> preprocessing::PreprocessOptions {
    let mut base = serde_json::json!({"downsample": false, "filter": false, "badchannel": false, "gedai": false, "interpolate": false});
    for (k, v) in extra.as_object().unwrap() {
        base[k] = v.clone();
    }
    serde_json::from_value(base).unwrap()
}

#[test]
fn ica_blink_stage_runs_and_reports() {
    let mut rec = synthetic(60, 250.0);
    let dir = std::env::temp_dir().join("ccs_ica_test.ccseeg.json");
    let summary = preprocessing::run(
        &mut rec,
        "synthetic",
        dir.to_str().unwrap(),
        &options(serde_json::json!({"ica_method": "runica", "ica_other": false})),
    )
    .unwrap();
    let ica = summary.ica.expect("ica report");
    assert_eq!(ica["ica"]["method"], "runica");
    assert!(ica["ica"]["blink_events"].as_u64().unwrap() >= 10);
    assert_eq!(ica["ica"]["blink_stage"]["ran"], true);
    assert_eq!(summary.channels, LABELS.len());
}

#[test]
fn asr_reject_shortens_and_correct_keeps_length() {
    let mut rec = synthetic(60, 250.0);
    let n = rec.channels[0].len();
    let out = std::env::temp_dir().join("ccs_asr_test.ccseeg.json");
    let s = preprocessing::run(&mut rec, "synthetic", out.to_str().unwrap(), &options(serde_json::json!({"asr_mode": "correct", "asr_cutoff": 5.0}))).unwrap();
    assert_eq!(s.samples, n);
    assert!(s.ica.unwrap()["asr"]["samples_changed"].as_u64().unwrap() > 0);
    let mut rec = synthetic(60, 250.0);
    let s = preprocessing::run(&mut rec, "synthetic", out.to_str().unwrap(), &options(serde_json::json!({"asr_mode": "reject", "asr_cutoff": 5.0}))).unwrap();
    assert!(s.samples < n);
}

#[test]
fn invalid_ica_method_is_rejected() {
    let mut rec = synthetic(30, 250.0);
    let out = std::env::temp_dir().join("ccs_bad_test.ccseeg.json");
    assert!(preprocessing::run(&mut rec, "x", out.to_str().unwrap(), &options(serde_json::json!({"ica_method": "fastica"}))).is_err());
}

#[test]
fn gedai_with_unknown_labels_warns_instead_of_silently_using_identity() {
    let mut rec = synthetic(30, 250.0);
    rec.labels = (0..LABELS.len()).map(|i| format!("PATCH{i}")).collect();
    let out = std::env::temp_dir().join("ccs_gedai_warn.ccseeg.json");
    let s = preprocessing::run(&mut rec, "x", out.to_str().unwrap(), &options(serde_json::json!({"gedai": true}))).unwrap();
    assert_eq!(s.gedai_reference.as_deref(), Some("identity"));
    assert!(s.warnings.iter().any(|w| w.contains("WITHOUT its leadfield reference")), "{:?}", s.warnings);
    let mut rec = synthetic(30, 250.0);
    let s = preprocessing::run(&mut rec, "x", out.to_str().unwrap(), &options(serde_json::json!({"gedai": true}))).unwrap();
    assert_eq!(s.gedai_reference.as_deref(), Some("leadfield"));
}

#[test]
fn asr_variants_run_and_report_variant() {
    for variant in ["riemannian", "adaptive", "juggler_gev"] {
        let mut rec = synthetic(60, 250.0);
        let n = rec.channels[0].len();
        let out = std::env::temp_dir().join("ccs_asr_variant_test.ccseeg.json");
        let s = preprocessing::run(
            &mut rec,
            "synthetic",
            out.to_str().unwrap(),
            &options(serde_json::json!({"asr_mode": "correct", "asr_cutoff": 10.0, "asr_variant": variant})),
        )
        .unwrap_or_else(|e| panic!("{variant}: {e}"));
        assert_eq!(s.samples, n, "{variant}");
        assert_eq!(s.ica.unwrap()["asr"]["variant"], variant);
    }
}

#[test]
fn single_channel_variants_refuse_many_channels() {
    let mut rec = synthetic(60, 250.0);
    let out = std::env::temp_dir().join("ccs_asr_variant_test2.ccseeg.json");
    let s = preprocessing::run(&mut rec, "synthetic", out.to_str().unwrap(), &options(serde_json::json!({"asr_mode": "correct", "asr_variant": "easr"}))).unwrap();
    assert!(s.warnings.iter().any(|w| w.contains("single / low channel")), "{:?}", s.warnings);
}

#[test]
fn muscle_cleaners_run() {
    for method in ["bss_cca", "icanclean", "wica"] {
        let mut rec = synthetic(40, 250.0);
        let out = std::env::temp_dir().join("ccs_muscle_test.ccseeg.json");
        let s = preprocessing::run(&mut rec, "synthetic", out.to_str().unwrap(), &options(serde_json::json!({"muscle_method": method})))
            .unwrap_or_else(|e| panic!("{method}: {e}"));
        let rep = s.ica.expect("report");
        assert_eq!(rep["muscle"]["method"], method, "{:?}", s.warnings);
    }
}

#[test]
fn invalid_variant_options_rejected() {
    let mut rec = synthetic(30, 250.0);
    let out = std::env::temp_dir().join("ccs_variant_bad.ccseeg.json");
    assert!(preprocessing::run(&mut rec, "synthetic", out.to_str().unwrap(), &options(serde_json::json!({"asr_variant": "nonsense"}))).is_err());
    assert!(preprocessing::run(&mut rec, "synthetic", out.to_str().unwrap(), &options(serde_json::json!({"muscle_method": "magic"}))).is_err());
}
