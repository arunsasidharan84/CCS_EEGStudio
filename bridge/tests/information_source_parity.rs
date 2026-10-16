use ccs_eeg_engine::{information::*, source_loc::inverse_operator};
use nalgebra::DMatrix;
use serde_json::Value;
fn fixture() -> Value {
    serde_json::from_str(include_str!("reference/information_source.json")).unwrap()
}
fn rows(v: &Value) -> Vec<Vec<f64>> {
    serde_json::from_value(v.clone()).unwrap()
}
fn matrix(v: &Value) -> DMatrix<f64> {
    let r = rows(v);
    DMatrix::from_fn(r.len(), r[0].len(), |i, j| r[i][j])
}
#[test]
fn frites_mi_cmi_and_te_parity() {
    let f = fixture();
    let x = rows(&f["x"]);
    let z: Vec<_> = x.iter().map(|r| copnorm(r)).collect();
    assert!((gaussian_mi(&z[0], &z[1]) - f["mi"].as_f64().unwrap()).abs() < 1e-8);
    assert!((gaussian_cmi(&z[0], &z[1], &z[2]) - f["cmi"].as_f64().unwrap()).abs() < 1e-8);
    let ch: Vec<Vec<f32>> = serde_json::from_value(f["temporal"].clone()).unwrap();
    let mut o = InformationOptions::default();
    o.te_min_delay = 2;
    o.te_max_delay = 3;
    let te = temporal_te_matrix(&ch, 0, ch[0].len(), &o).unwrap();
    let reference = rows(&f["te_time"]);
    for i in 0..3 {
        for j in 0..3 {
            assert!((te[i][j] - reference[i][j]).abs() < 1e-8);
        }
    }
    assert!(
        te[0][1] > te[1][0] + 0.05,
        "Known X->Y direction must dominate reverse"
    );
    assert!(
        te[2][1].abs() < 0.03,
        "Independent channel must stay near zero"
    );
    o.te_source_history = 2;
    o.te_target_history = 3;
    o.te_history_step = 2;
    let te = temporal_te_matrix(&ch, 0, ch[0].len(), &o).unwrap();
    let reference = rows(&f["te_time_history"]);
    for i in 0..3 {
        for j in 0..3 {
            assert!((te[i][j] - reference[i][j]).abs() < 1e-8);
        }
    }
}
#[test]
fn inverse_numpy_formula_parity() {
    let f = fixture();
    let l = matrix(&f["leadfield"]);
    let d = matrix(&f["data"]);
    for method in ["mne", "dspm", "sloreta", "lcmv"] {
        let actual = inverse_operator(&l, &d, 3.0, method).unwrap();
        let expected = matrix(&f["operators"][method]);
        assert!((actual - expected).amax() < 1e-10, "{method}");
    }
}
#[test]
fn graph_complete_triangle_and_disconnected() {
    let w = vec![vec![0., 1., 1.], vec![1., 0., 1.], vec![1., 1., 0.]];
    let g = graph_features(&w, 1.);
    for row in g {
        assert_eq!(row, vec![2., 2., 2., 1., 1., 1., 1.]);
    }
    let empty = graph_features(&vec![vec![0.; 3]; 3], 1.);
    assert!(empty.iter().flatten().all(|x| *x == 0.));
}
#[test]
fn missing_inputs_are_not_zero_connectivity() {
    assert!(gaussian_mi(&[1.; 10], &[1.; 10]).is_nan());
    let ch = vec![vec![0f32; 12]; 2];
    assert!(temporal_te_matrix(&ch, 0, 12, &InformationOptions::default()).is_err());
}
#[test]
fn gcmi_constant_and_spectral_matrix_export() {
    let ch = vec![vec![1f32; 200]; 3];
    let w = gcmi_matrix(&ch, 0, 200);
    assert!(w[0][1].is_nan());
    let mut o = ccs_eeg_engine::Options::connectivity_test();
    o.mic = false;
    o.mim = false;
    o.gc = false;
    o.gc_tr = false;
    o.coh = true;
    o.information.spectral_graph = true;
    let labels = vec!["Fz".into(), "Pz".into(), "Oz".into()];
    let networks = ccs_eeg_engine::connectivity::spectral_networks(&ch, 0, 200, 100., &o);
    assert_eq!(
        networks.len(),
        ccs_eeg_engine::connectivity::spectral_network_names(&o).len()
    );
    let rows = ccs_eeg_engine::connectivity::compute_epoch(&ch, &labels, 0, 200, 100., &o);
    assert_eq!(
        rows[0].len(),
        ccs_eeg_engine::connectivity::column_names(&o).len()
    );
}
#[test]
fn custom_forward_and_atlas_validation() {
    use ccs_eeg_engine::source_loc::convert_with_model;
    let f = fixture();
    let labels: Vec<String> = ["A", "B", "C", "D"].iter().map(|s| s.to_string()).collect();
    let mut model = serde_json::json!({"channels":labels,"leadfield":f["leadfield"],"rois":[{"name":"HCPex_example","indices":[0,1,2]},{"name":"Thalamus_example","indices":[3,4,5]}]});
    let path = std::env::temp_dir().join(format!("source-model-{}.json", std::process::id()));
    std::fs::write(&path, model.to_string()).unwrap();
    let data = rows(&f["data"]);
    for method in ["mne", "dspm", "sloreta", "lcmv"] {
        let (values, names) =
            convert_with_model(&data, &labels, 3., method, path.to_str().unwrap()).unwrap();
        assert_eq!(names, vec!["HCPex_example", "Thalamus_example"]);
        assert_eq!(values.len(), 2);
        assert!(values.iter().flatten().all(|v| v.is_finite()));
    }
    model["rois"][0]["indices"] = serde_json::json!([999]);
    std::fs::write(&path, model.to_string()).unwrap();
    assert!(convert_with_model(&data, &labels, 3., "mne", path.to_str().unwrap()).is_err());
    std::fs::remove_file(path).unwrap();
}
#[test]
fn graph_scipy_and_triangle_matrix_parity() {
    let f = fixture();
    let raw = rows(&f["graph_raw"]);
    let expected = rows(&f["graph_expected"]);
    let actual = graph_features(&raw, 0.6);
    for i in 0..raw.len() {
        for j in 0..7 {
            assert!((actual[i][j] - expected[i][j]).abs() < 1e-10, "{i} {j}");
        }
    }
}
#[test]
fn native_csv_temporal_te_single_epoch_and_overlap() {
    use std::{fs, process::Command};
    let f = fixture();
    let ch: Vec<Vec<f32>> = serde_json::from_value(f["temporal"].clone()).unwrap();
    let dir = std::env::temp_dir().join(format!("info-cli-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("input.json");
    let output = dir.join("output.csv");
    let jobpath = dir.join("job.json");
    fs::write(&input,serde_json::json!({"format":"ccseeg-v1","sample_rate":100.,"labels":["Fz","Pz","Oz"],"channels":ch}).to_string()).unwrap();
    let mut o = ccs_eeg_engine::Options::connectivity_test();
    o.mic = false;
    o.mim = false;
    o.gc = false;
    o.gc_tr = false;
    o.coh = false;
    o.plv = false;
    o.ciplv = false;
    o.pli = false;
    o.wpli = false;
    o.reference_mode = "none".into();
    o.information.gcmi = true;
    o.information.te = true;
    o.information.te_min_delay = 2;
    o.information.te_max_delay = 3;
    let mut job = serde_json::json!({"input":input,"output":output,"format":"ccseeg","epoch_seconds":2.5,"options":o});
    fs::write(&jobpath, job.to_string()).unwrap();
    let run = Command::new(env!("CARGO_BIN_EXE_ccs-eeg-engine"))
        .arg(&jobpath)
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    let csv = fs::read_to_string(&output).unwrap();
    let mut lines = csv.lines();
    let header: Vec<_> = lines.next().unwrap().split(',').collect();
    assert!(header.contains(&"graph_gcmi_clustering"));
    let index = header
        .iter()
        .position(|&h| h == "conn_te_time_to_Pz")
        .unwrap();
    let first = csv_fields(lines.next().unwrap());
    assert_eq!(first.len(), header.len());
    assert!(
        (first[index].parse::<f64>().unwrap() - f["te_time_first"][0][1].as_f64().unwrap()).abs()
            < 1e-8
    );
    job["epoch_overlap_seconds"] = serde_json::json!(1.0);
    fs::write(&jobpath, job.to_string()).unwrap();
    let run = Command::new(env!("CARGO_BIN_EXE_ccs-eeg-engine"))
        .arg(&jobpath)
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    let changed = fs::read_to_string(&output).unwrap();
    assert!(
        changed.lines().count() > csv.lines().count(),
        "Overlapping windows must produce additional estimates"
    );
    job["epoch_overlap_seconds"] = serde_json::json!(0.0);
    job["epoch_seconds"] = serde_json::json!(14.0);
    fs::write(&jobpath, job.to_string()).unwrap();
    let run = Command::new(env!("CARGO_BIN_EXE_ccs-eeg-engine"))
        .arg(&jobpath)
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    let single = fs::read_to_string(&output).unwrap();
    assert_eq!(
        single.lines().count(),
        4,
        "A single epoch, three channels, no trial ensemble"
    );
    let row = csv_fields(single.lines().nth(1).unwrap());
    assert!(
        (row[index].parse::<f64>().unwrap() - f["te_time"][0][1].as_f64().unwrap()).abs() < 1e-8
    );
    fs::remove_dir_all(dir).unwrap();
}

fn csv_fields(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                if quoted && chars.peek() == Some(&'"') {
                    field.push('"');
                    chars.next();
                } else {
                    quoted = !quoted;
                }
            }
            ',' if !quoted => {
                out.push(std::mem::take(&mut field));
            }
            _ => field.push(c),
        }
    }
    out.push(field);
    out
}

#[test]
fn temporal_te_never_uses_samples_outside_the_window() {
    let f = fixture();
    let mut ch: Vec<Vec<f32>> = serde_json::from_value(f["temporal"].clone()).unwrap();
    let mut o = InformationOptions::default();
    o.te_min_delay = 2;
    o.te_max_delay = 3;
    let a = temporal_te_matrix(&ch, 0, 250, &o).unwrap();
    for c in &mut ch {
        for v in &mut c[250..] {
            *v = f32::NAN;
        }
    }
    let b = temporal_te_matrix(&ch, 0, 250, &o).unwrap();
    assert_eq!(a, b);
    let swapped = vec![ch[1].clone(), ch[0].clone(), ch[2].clone()];
    let reverse = temporal_te_matrix(&swapped, 0, 250, &o).unwrap();
    assert!((a[0][1] - reverse[1][0]).abs() < 1e-10);
}
