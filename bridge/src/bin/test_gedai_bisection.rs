use ccs_eeg_engine::preprocessing::{gedai_per_band, leadfield_cov};
use serde::Deserialize;
use std::fs;

#[derive(Deserialize)]
struct PyData {
    data: Vec<Vec<f64>>,
    labels: Vec<String>,
}

fn main() {
    let json_str = match fs::read_to_string("../parity_test/py_data_for_rust.json") {
        Ok(s) => s,
        Err(_) => return,
    };
    let py_data: PyData = serde_json::from_str(&json_str).unwrap();
    let mut data = py_data.data;
    let ref_cov = leadfield_cov(&py_data.labels).unwrap();
    
    let (_, _, sensai, thresh) = gedai_per_band(&mut data, 250.0, 1.0, &ref_cov, "auto", true).unwrap();
    println!("Rust Threshold: {}, Sensai: {}", thresh, sensai);
}
