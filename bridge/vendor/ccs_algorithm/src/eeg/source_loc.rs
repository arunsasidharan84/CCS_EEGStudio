use flate2::read::GzDecoder;
use nalgebra::DMatrix;
use rayon::prelude::*;
use serde::Deserialize;
use std::collections::HashMap;

#[derive(Deserialize)]
struct RoiData {
    name: String,
    indices: Vec<usize>,
}

#[derive(Deserialize)]
struct FsaverageData {
    channels: Vec<String>,
    leadfield: Vec<Vec<f64>>,
    rois: Vec<RoiData>,
}

pub fn convert_to_source_space(
    channels: &[Vec<f64>],
    labels: &[String],
    snr: f64,
) -> Result<(Vec<Vec<f64>>, Vec<String>), String> {
    if channels.is_empty() || channels[0].is_empty() {
        return Err("Input channel data is empty".to_string());
    }
    convert_with_model(channels, labels, snr, "mne", "")
}

/// Fixed-orientation inverse operators; identity sensor noise covariance.
pub fn inverse_operator(
    l: &DMatrix<f64>,
    data: &DMatrix<f64>,
    snr: f64,
    method: &str,
) -> Result<DMatrix<f64>, String> {
    if !snr.is_finite() || snr <= 0.0 {
        return Err("SNR must be positive".into());
    }
    let m = l.nrows();
    let gram = l * l.transpose();
    let alpha = gram.trace() / m as f64 / (snr * snr);
    if method == "lcmv" {
        let mut centered = data.clone();
        for r in 0..m {
            let mean = data.row(r).iter().sum::<f64>() / data.ncols() as f64;
            for c in 0..data.ncols() {
                centered[(r, c)] -= mean;
            }
        }
        let cov = &centered * centered.transpose() / (data.ncols().saturating_sub(1).max(1) as f64);
        let reg = cov.trace() / m as f64 * 0.05;
        let inv = (cov + DMatrix::identity(m, m) * reg)
            .try_inverse()
            .ok_or("LCMV covariance is singular")?;
        let mut w = l.transpose() * inv;
        for r in 0..w.nrows() {
            let gain = (w.row(r) * l.column(r))[(0, 0)];
            if gain <= 0.0 {
                return Err("LCMV source has zero gain".into());
            }
            w.row_mut(r).scale_mut(1.0 / gain);
        }
        return Ok(w);
    }
    if !["mne", "dspm", "sloreta"].contains(&method) {
        return Err(format!("Unknown inverse method: {method}"));
    }
    let inv = (gram + DMatrix::identity(m, m) * alpha)
        .try_inverse()
        .ok_or("Leadfield inverse is singular")?;
    let mut w = l.transpose() * inv;
    if method != "mne" {
        for r in 0..w.nrows() {
            let variance = if method == "dspm" {
                w.row(r).norm_squared()
            } else {
                (w.row(r) * l.column(r))[(0, 0)]
            };
            if variance > 0.0 {
                w.row_mut(r).scale_mut(1.0 / variance.sqrt());
            }
        }
    }
    Ok(w)
}

pub fn convert_with_model(
    channels: &[Vec<f64>],
    labels: &[String],
    snr: f64,
    method: &str,
    model_path: &str,
) -> Result<(Vec<Vec<f64>>, Vec<String>), String> {
    if channels.is_empty()
        || channels[0].is_empty()
        || channels.len() != labels.len()
        || channels
            .iter()
            .any(|c| c.len() != channels[0].len() || c.iter().any(|v| !v.is_finite()))
    {
        return Err("Invalid source input dimensions or nonfinite data".into());
    }
    let samples = channels[0].len();

    eprintln!("PROGRESS 10 Loading canonical fsaverage leadfield model...");
    let compressed = include_bytes!("../resources/fsaverage_1005_roi.json.gz");
    let model: FsaverageData = if model_path.is_empty() {
        serde_json::from_reader(GzDecoder::new(&compressed[..]))
    } else {
        let file = std::fs::File::open(model_path).map_err(|e| format!("Forward model: {e}"))?;
        if model_path.ends_with(".gz") {
            serde_json::from_reader(GzDecoder::new(file))
        } else {
            serde_json::from_reader(file)
        }
    }
    .map_err(|e| format!("Forward model JSON: {e}"))?;
    if model.channels.is_empty()
        || model.leadfield.len() != model.channels.len()
        || model.leadfield[0].is_empty()
        || model
            .leadfield
            .iter()
            .any(|r| r.len() != model.leadfield[0].len() || r.iter().any(|v| !v.is_finite()))
        || model.rois.is_empty()
        || model.rois.iter().any(|r| {
            r.indices.is_empty() || r.indices.iter().any(|&i| i >= model.leadfield[0].len())
        })
    {
        return Err("Invalid forward model dimensions or atlas source indices".into());
    }

    let canon_lookup: HashMap<String, usize> = model
        .channels
        .iter()
        .enumerate()
        .map(|(i, name)| (name.to_lowercase().replace('.', "").replace('-', ""), i))
        .collect();

    let mut matched_rec_idx = Vec::new();
    let mut matched_canon_idx = Vec::new();
    for (i, label) in labels.iter().enumerate() {
        let norm = label.to_lowercase().replace('.', "").replace('-', "");
        if let Some(&c_idx) = canon_lookup.get(&norm) {
            matched_rec_idx.push(i);
            matched_canon_idx.push(c_idx);
        }
    }

    let m = matched_rec_idx.len();
    if m < 4 {
        return Err(format!(
            "Only found {} matched 10-05 channels out of {}. Need at least 4 for source localization.",
            m, labels.len()
        ));
    }

    eprintln!(
        "PROGRESS 20 Constructing forward leadfield for {} matched channels...",
        m
    );
    let n_sources = model.leadfield[0].len();
    let l_mat = DMatrix::from_fn(m, n_sources, |r, c| {
        model.leadfield[matched_canon_idx[r]][c]
    });

    eprintln!("PROGRESS 40 Computing regularized inverse operator (MNE / minimum norm)...");
    let data = DMatrix::from_fn(m, samples, |r, c| channels[matched_rec_idx[r]][c]);
    let w_mat = inverse_operator(&l_mat, &data, snr, method)?;

    eprintln!(
        "PROGRESS 60 Projecting {} samples to {} cortical dipoles...",
        samples, n_sources
    );
    let x_data: Vec<Vec<f64>> = matched_rec_idx
        .iter()
        .map(|&idx| channels[idx].clone())
        .collect();

    eprintln!("PROGRESS 80 Extracting atlas ROI time courses (mean-flip alignment)...");
    let n_rois = model.rois.len();
    let roi_channels: Vec<Vec<f64>> = (0..n_rois)
        .into_par_iter()
        .map(|r_idx| {
            let roi = &model.rois[r_idx];
            let k = roi.indices.len();
            if k == 0 {
                return vec![0.0f64; samples];
            }

            let mut w_roi = DMatrix::zeros(k, m);
            for (row_idx, &dipole_idx) in roi.indices.iter().enumerate() {
                for col_idx in 0..m {
                    w_roi[(row_idx, col_idx)] = w_mat[(dipole_idx, col_idx)];
                }
            }

            let mut s_roi = vec![vec![0.0f64; samples]; k];
            for row_idx in 0..k {
                for s in 0..samples {
                    let mut sum = 0.0;
                    for col_idx in 0..m {
                        sum += w_roi[(row_idx, col_idx)] * x_data[col_idx][s];
                    }
                    s_roi[row_idx][s] = sum;
                }
            }

            let mut mean_tc = vec![0.0f64; samples];
            for s in 0..samples {
                let sum: f64 = (0..k).map(|row_idx| s_roi[row_idx][s]).sum();
                mean_tc[s] = sum / (k as f64);
            }

            let mut flips = vec![1.0f64; k];
            for row_idx in 0..k {
                let dot: f64 = (0..samples).map(|s| s_roi[row_idx][s] * mean_tc[s]).sum();
                if dot < 0.0 {
                    flips[row_idx] = -1.0;
                }
            }

            let mut roi_tc = vec![0.0f64; samples];
            for s in 0..samples {
                let sum: f64 = (0..k)
                    .map(|row_idx| flips[row_idx] * s_roi[row_idx][s])
                    .sum();
                roi_tc[s] = (sum / (k as f64))
                    * if method == "mne" || method == "lcmv" {
                        10000.0
                    } else {
                        1.0
                    };
            }
            roi_tc
        })
        .collect();

    let roi_labels: Vec<String> = model.rois.iter().map(|r| r.name.clone()).collect();
    eprintln!("PROGRESS 100 Source localization complete (atlas ROIs extracted).");

    Ok((roi_channels, roi_labels))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_source_space_amplitude() {
        let labels = vec![
            "Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8", "T3", "C3", "Cz", "C4", "T4", "T5", "P3",
            "Pz", "P4", "T6", "O1", "O2",
        ]
        .into_iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();

        let samples = 1000;
        let mut channels = Vec::new();
        for (i, _) in labels.iter().enumerate() {
            let ch = (0..samples)
                .map(|s| 50.0 * ((s as f64) * 0.1 + (i as f64)).sin())
                .collect();
            channels.push(ch);
        }

        let (rois, roi_labels) = convert_to_source_space(&channels, &labels, 3.0).unwrap();
        assert_eq!(rois.len(), 68);
        assert_eq!(roi_labels.len(), 68);

        let max_val = rois
            .iter()
            .flat_map(|ch| ch.iter())
            .cloned()
            .fold(0.0f64, |a, b| a.max(b.abs()));
        println!("MAX ROI AMPLITUDE: {}", max_val);
    }
}
