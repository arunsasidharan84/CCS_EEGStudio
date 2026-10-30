use ccs_eeg_engine::{erp_math::*, erp_workbench::*};
use nalgebra::DMatrix;
use serde_json::Value;
fn fixture() -> Value {
    serde_json::from_str(include_str!("reference/erp_workbench.json")).unwrap()
}
fn list(v: &Value) -> Vec<f64> {
    serde_json::from_value(v.clone()).unwrap()
}
fn rows(v: &Value) -> Vec<Vec<f64>> {
    serde_json::from_value(v.clone()).unwrap()
}
fn matrix(v: &Value) -> DMatrix<f64> {
    let a = rows(v);
    DMatrix::from_fn(a.len(), a[0].len(), |i, j| a[i][j])
}
#[test]
fn measurements_match_numpy() {
    let f = fixture();
    let m = measure(&list(&f["times"]), &list(&f["y"]), [0.1, 0.35], -1.).unwrap();
    let actual = serde_json::to_value(m).unwrap();
    for (k, v) in f["measure"].as_object().unwrap() {
        assert!(
            (actual[k].as_f64().unwrap() - v.as_f64().unwrap()).abs() < 1e-10,
            "{k}"
        );
    }
}
#[test]
fn regression_matches_lstsq() {
    let f = fixture();
    let (beta, rank) = regression(&matrix(&f["x"]), &matrix(&f["response"])).unwrap();
    assert_eq!(rank, 3);
    assert!((beta - matrix(&f["beta"])).amax() < 1e-10);
    let x = DMatrix::from_element(20, 3, 1.);
    assert!(regression(&x, &DMatrix::from_element(20, 1, 1.)).is_err());
}
#[test]
fn sparse_lsqr_matches_scipy() {
    let f = fixture();
    let a = rows(&f["sparse_a"]);
    let design = SparseDesign {
        columns: a[0].len(),
        rows: a
            .iter()
            .map(|r| {
                r.iter()
                    .enumerate()
                    .filter(|(_, v)| **v != 0.)
                    .map(|(i, v)| (i, *v))
                    .collect()
            })
            .collect(),
    };
    let fit = lsqr(&design, &list(&f["sparse_y"]), 1e-11, 2000).unwrap();
    assert!(fit.converged);
    for (a, b) in fit.coefficients.iter().zip(list(&f["lsqr"])) {
        assert!((a - b).abs() < 1e-8);
    }
}
#[test]
fn lda_training_fold_scaling_matches_numpy() {
    let f = fixture();
    let y: Vec<usize> = serde_json::from_value(f["labels"].clone()).unwrap();
    let scores = lda_scores(&matrix(&f["train"]), &y, &matrix(&f["test"]), 0.1).unwrap();
    for (a, b) in scores.iter().zip(list(&f["scores"])) {
        assert!((a - b).abs() < 1e-10);
    }
    assert_eq!(auc(&[0, 1, 0, 1], &[0., 1., 0.2, 0.8]), Some(1.));
}
#[test]
fn corrected_max_t_matches_scipy() {
    let f = fixture();
    let (t, p) = max_t(&rows(&f["differences"]), &rows(&f["signs"]));
    for (a, b) in t.iter().zip(list(&f["t"])) {
        assert!((a - b).abs() < 1e-10);
    }
    assert_eq!(p, list(&f["p"]));
    assert!(paired_test(&[1.]).is_none());
}
#[test]
fn erp_core_profiles_encode_all_seven_tasks() {
    for task in ["MMN", "N170", "N2pc", "N400", "P3", "LRP", "ERN"] {
        let p = profile(task).unwrap();
        assert!(!p.a_codes.is_empty() && !p.b_codes.is_empty());
        assert!(!p.a_codes.iter().any(|c| p.b_codes.contains(c)));
    }
    let p = profile("P3").unwrap();
    assert_eq!(p.b_codes, vec!["11", "22", "33", "44", "55"]);
    assert!(p.a_codes.contains(&"12".into()));
    assert!(profile("N2pc").unwrap().lateralized);
    assert!(profile("LRP").unwrap().epoch[0] < 0.);
}
#[test]
fn sidecar_and_status_event_sequences_are_preserved() {
    let root = std::path::Path::new(
        "/Volumes/One Touch/Arun/EEGdata/DemoData/ERP_CORE/ERP_CORE_EDFformat",
    );
    if !root.exists() {
        return;
    }
    for task in ["MMN", "N170", "N2pc", "N400", "P3", "LRP", "ERN"] {
        let p = root.join(task).join(format!("1_{task}_cleaned.edf"));
        let (a, _) = read_events(&p).unwrap();
        let (b, _) = read_edf_events(&p).unwrap();
        assert_eq!(a.len(), b.len(), "{task}");
        let mut delta = 0f64;
        for (a, b) in a.iter().zip(b) {
            assert_eq!(a.label, b.label, "{task}");
            assert!(a.onset.is_finite() && b.onset.is_finite());
            delta = delta.max((a.onset - b.onset).abs());
        }
        eprintln!("{task} sidecar/Status maximum difference: {} ms (sources are not silently substituted)",delta*1000.);
    }
}
#[test]
fn lateralized_alignment_and_participant_units_are_correct() {
    use ccs_eeg_engine::Recording;
    use std::fs;
    let path = std::env::temp_dir().join(format!("erp-lrp-{}.json", std::process::id()));
    let mut channels = vec![vec![0f32; 2200]; 4];
    let mut events = Vec::new();
    for i in 0..8 {
        let point = 200 + i * 200;
        let side = i % 2;
        for t in point - 10..=point {
            channels[1 - side][t] = -5.;
        }
        events.push(serde_json::json!({"type":"Event","description":if side==0{"111"}else{"212"},"start_seconds":point as f64/100.}));
    }
    fs::write(&path, serde_json::json!({"markers":events}).to_string()).unwrap();
    let output = std::env::temp_dir().join(format!("erp-lrp-out-{}", std::process::id()));
    let mut options = Options::default();
    options.task = "LRP".into();
    options.regression = true;
    options.trial_metadata_path = output
        .join("missing_trial_metadata.csv")
        .to_string_lossy()
        .into();
    let input = Input {
        path: path.to_str().unwrap().into(),
        subject: "same-participant".into(),
    };
    let job = Job {
        inputs: vec![input.clone(), input],
        output: output.to_str().unwrap().into(),
        options,
    };
    let result = run(&job, |_| {
        Ok(Recording {
            rate: 100.,
            labels: vec!["C3".into(), "C4".into(), "Fz".into(), "Pz".into()],
            channels: channels.clone(),
            source_epoch_samples: None,
            epoch_labels: None,
        })
    })
    .unwrap();
    assert!(result["failures"].as_array().unwrap().is_empty());
    assert!(result["files"][0]["regression"].is_null());
    assert!(result["files"][0]["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|w| w.as_str().unwrap().contains("rERP unavailable")));
    assert_eq!(result["groups"][0]["n_subjects"], 1);
    assert_eq!(result["groups"][0]["n_files"], 2);
    assert!(
        (result["files"][0]["measurements"]["B_minus_A"]["mean"]
            .as_f64()
            .unwrap()
            + 5.)
            .abs()
            < 1e-10
    );
    assert!((result["files"][0]["topo_difference"][0].as_f64().unwrap() - 5.).abs() < 1e-10);
    assert!((result["files"][0]["topo_difference"][1].as_f64().unwrap() + 5.).abs() < 1e-10);
    let file = &result["files"][0];
    let times = list(&file["times"]);
    let window = list(&file["profile"]["window"]);
    for (channel, expected) in file["channel_difference"]
        .as_array()
        .unwrap()
        .iter()
        .zip(list(&file["topo_difference"]))
    {
        let measured = measure(&times, &list(channel), [window[0], window[1]], -1.).unwrap();
        assert!((measured.mean - expected).abs() < 1e-10);
    }

    assert!(result["groups"][0]["statistics"][0]["p"].is_null());
    fs::remove_file(path).unwrap();
    fs::remove_dir_all(output).unwrap();
}
#[test]
fn task_detection_requires_a_real_task_token() {
    assert_eq!(
        detect_task("/PATTERN/1_N400_cleaned.edf"),
        Some("N400".into())
    );
    assert_eq!(detect_task("/modern/test.edf"), None);
    assert_eq!(detect_task("/demo/P300/subject1.edf"), Some("P3".into()));
}

#[test]
fn all_seven_tasks_reuse_saved_trials_without_re_epoching() {
    use ccs_eeg_engine::Recording;
    use std::fs;
    let dir = std::env::temp_dir().join(format!("erp-saved-seven-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    for task in ["MMN", "N170", "N2pc", "N400", "P3", "LRP", "ERN"] {
        let p = profile(task).unwrap();
        let rate = 100.;
        let n = ((p.epoch[1] - p.epoch[0]) * rate).round() as usize + 1;
        let mut labels = p.roi.clone();
        for name in ["Fz", "Cz", "Pz", "Oz"] {
            if !labels.contains(&name.to_string()) {
                labels.push(name.into());
            }
        }
        let mut channels = vec![vec![0f32; n * 8]; labels.len()];
        let mut groups = Vec::new();
        for i in 0..8 {
            groups.push(if i % 2 == 0 {
                p.a_codes[0].clone()
            } else {
                p.b_codes[0].clone()
            });
            for t in 0..n {
                let time = p.epoch[0] + t as f64 / rate;
                if time >= p.window[0] - 1e-8 && time <= p.window[1] + 1e-8 {
                    for c in 0..labels.len() {
                        channels[c][i * n + t] = if c == i % 2 { -3. } else { 1. };
                    }
                }
            }
        }
        let path = dir.join(format!("1_{task}.ccseeg.json"));
        fs::write(&path,serde_json::json!({"sample_rate":rate,"source_epoch_samples":n,"epoch_tmin":p.epoch[0],"epoch_tmax":p.epoch[1],"epoch_labels":groups,"epoch_onsets":(0..8).map(|i|10.+i as f64*3.).collect::<Vec<_>>()} ).to_string()).unwrap();
        let mut options = Options::default();
        options.task = task.into();
        options.export_trial_measurements = task == "MMN";
        let job = Job {
            inputs: vec![Input {
                path: path.to_string_lossy().into(),
                subject: "1".into(),
            }],
            output: dir.join(task).to_string_lossy().into(),
            options,
        };
        let result = run(&job, |_| {
            Ok(Recording {
                rate,
                labels: labels.clone(),
                channels: channels.clone(),
                source_epoch_samples: Some(n),
                epoch_labels: Some(groups.clone()),
            })
        })
        .unwrap();
        assert!(
            result["failures"].as_array().unwrap().is_empty(),
            "{task}: {}",
            result["failures"]
        );
        let f = &result["files"][0];
        assert_eq!(f["channel_a"].as_array().unwrap().len(), labels.len());
        assert_eq!(f["channel_b"].as_array().unwrap().len(), labels.len());
        assert_eq!(f["channel_a"][0].as_array().unwrap().len(), n);
        assert_eq!(f["n_a"], 4);
        assert_eq!(f["n_b"], 4);
        let measurements = fs::read_to_string(std::path::Path::new(&job.output).join("erp_measurements.csv")).unwrap();
        for name in f["condition_names"].as_array().unwrap() {
            let name = name.as_str().unwrap();
            let row = measurements.lines().skip(1).find(|row| row.split(',').nth(3) == Some(name)).unwrap();
            assert_eq!(row.split(',').nth(4), Some("4"), "named condition trial count: {name}");
        }

        let trial_csv = std::path::Path::new(&job.output).join("erp_trial_measurements.csv");
        assert_eq!(trial_csv.exists(), task == "MMN");
        if task == "MMN" {
            assert_eq!(fs::read_to_string(trial_csv).unwrap().lines().count(), 9);
        }

        assert_eq!(f["times"].as_array().unwrap().len(), n);
        assert_eq!(f["rejected_behavior"], 0);
        assert_eq!(f["accepted_events"][0]["onset_s"], 10.);
    }
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn saved_locking_codes_can_regroup_and_reverse_the_comparison() {
    use ccs_eeg_engine::Recording;
    use std::fs;
    let dir = std::env::temp_dir().join(format!("erp-regroup-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("1_ERN.ccseeg");
    let metadata = serde_json::json!({"sample_rate":100.,"source_epoch_samples":171,"epoch_tmin":-0.5,"epoch_tmax":1.2,"epoch_labels":["Congruent","Congruent","Incongruent","Incongruent","Congruent","Incongruent"],"epoch_onsets":[10.,13.,16.,19.,22.,25.],"markers":[{"epoch_index":0,"description":"111","start_seconds":0.5},{"epoch_index":1,"description":"112","start_seconds":0.5},{"epoch_index":2,"description":"212","start_seconds":0.5},{"epoch_index":3,"description":"222","start_seconds":0.5},{"epoch_index":4,"description":"112","start_seconds":0.5},{"epoch_index":5,"description":"111","start_seconds":0.5}]});
    fs::write(&path, metadata.to_string()).unwrap();
    let mut p = profile("ERN").unwrap();
    p.a_codes = vec!["Error response".into()];
    p.b_codes = vec!["Correct response".into()];
    let mut options = Options::default();
    options.task = "ERN".into();
    options.regroup_epochs = true;
    options.profile_override = Some(p);
    let job = Job {
        inputs: vec![Input {
            path: path.to_string_lossy().into(),
            subject: "1".into(),
        }],
        output: dir.join("out").to_string_lossy().into(),
        options,
    };
    let r = run(&job, |_| {
        Ok(Recording {
            rate: 100.,
            labels: vec!["FCz".into(), "Cz".into(), "Pz".into(), "Oz".into()],
            channels: vec![vec![0.; 1026]; 4],
            source_epoch_samples: Some(171),
            epoch_labels: Some(vec![
                "Congruent".into(),
                "Congruent".into(),
                "Incongruent".into(),
                "Incongruent".into(),
                "Congruent".into(),
                "Incongruent".into(),
            ]),
        })
    })
    .unwrap();
    assert!(
        r["failures"].as_array().unwrap().is_empty(),
        "{}",
        r["failures"]
    );
    assert_eq!(r["files"][0]["n_a"], 2);
    assert_eq!(r["files"][0]["n_b"], 4);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn portable_continuous_events_use_only_time_preserved_sidecars() {
    let dir = std::env::temp_dir().join(format!("erp-marker-sidecar-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("clean.ccseeg.json");
    std::fs::write(&path, r#"{"format":"ccseeg-v1"}"#).unwrap();
    let side = format!("{}.preprocessing.json", path.display());
    std::fs::write(
        &side,
        r#"{"timeline_preserved":true,"markers":[{"description":"111","start_seconds":2.5}]}"#,
    )
    .unwrap();
    let (events, _) = read_events(&path).unwrap();
    assert_eq!(events[0].label, "111");
    assert_eq!(events[0].onset, 2.5);
    std::fs::write(
        &side,
        r#"{"timeline_preserved":false,"markers":[{"description":"111","start_seconds":2.5}]}"#,
    )
    .unwrap();
    assert!(read_events(&path).is_err());
    std::fs::remove_dir_all(dir).unwrap();
}
