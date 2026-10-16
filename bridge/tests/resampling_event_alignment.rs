use ccs_eeg_engine::{preprocessing, spectral, Recording};
use serde_json::json;
fn options() -> preprocessing::PreprocessOptions {
    serde_json::from_value(json!({"downsample":true,"downsample_freq":250.,"filter":false,"badchannel":false,"gedai":false,"interpolate":false,"reference_mode":"none"})).unwrap()
}
#[test]
fn resampling_256_to_250_keeps_late_events_aligned() {
    let n = 256 * 300;
    let mut x = vec![0f32; n];
    for t in [10, 100, 250, 299] {
        x[t * 256] = 1.;
    }
    let mut rec = Recording {
        rate: 256.,
        labels: vec!["Fz".into(), "Cz".into(), "Pz".into(), "Oz".into()],
        channels: vec![x.clone(); 4],
        source_epoch_samples: None,
        epoch_labels: None,
    };
    let path = std::env::temp_dir().join(format!("resample-timeline-{}.json", std::process::id()));
    preprocessing::run(&mut rec, "synthetic", path.to_str().unwrap(), &options()).unwrap();
    assert_eq!(rec.rate, 250.);
    assert_eq!(rec.channels[0].len(), 250 * 300);
    for t in [10, 100, 250, 299] {
        let centre = t * 250;
        let peak = (centre - 2..=centre + 2)
            .max_by(|&a, &b| {
                rec.channels[0][a]
                    .abs()
                    .total_cmp(&rec.channels[0][b].abs())
            })
            .unwrap();
        assert_eq!(peak, centre, "event at {t} seconds drifted");
        assert!(rec.channels[0][centre] > 0.9);
    }
    std::fs::remove_file(path).unwrap();
}
#[test]
fn resampled_trials_use_actual_ceil_length_without_cross_trial_drift() {
    let points = 462;
    let source: Vec<f32> = (0..points * 4)
        .map(|i| ((i / points + 1) as f32) * if i % points == 200 { 1. } else { 0. })
        .collect();
    let mut rec = Recording {
        rate: 256.,
        labels: vec!["Fz".into(), "Cz".into(), "Pz".into(), "Oz".into()],
        channels: vec![source.clone(); 4],
        source_epoch_samples: Some(points),
        epoch_labels: Some(vec!["A".into(); 4]),
    };
    let path = std::env::temp_dir().join(format!("resample-epochs-{}.json", std::process::id()));
    preprocessing::run(&mut rec, "synthetic", path.to_str().unwrap(), &options()).unwrap();
    assert_eq!(rec.source_epoch_samples, Some(452));
    assert_eq!(rec.channels[0].len(), 452 * 4);
    for (i, chunk) in source.chunks(points).enumerate() {
        let expected = spectral::resample_poly(
            &chunk.iter().map(|&v| v as f64).collect::<Vec<_>>(),
            125,
            128,
        );
        for (a, b) in rec.channels[0][i * 452..(i + 1) * 452].iter().zip(expected) {
            assert!((*a as f64 - b).abs() < 1e-6);
        }
    }
    std::fs::remove_file(path).unwrap();
}
