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
    let samples = channels[0].len();

    eprintln!("PROGRESS 10 Loading canonical fsaverage leadfield model...");
    let compressed = include_bytes!("../resources/fsaverage_1005_roi.json.gz");
    let decoder = GzDecoder::new(&compressed[..]);
    let model: FsaverageData = serde_json::from_reader(decoder)
        .map_err(|e| format!("Failed to parse fsaverage model: {}", e))?;

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

    eprintln!("PROGRESS 20 Constructing forward leadfield for {} matched channels...", m);
    let n_sources = model.leadfield[0].len();
    let l_mat = DMatrix::from_fn(m, n_sources, |r, c| {
        model.leadfield[matched_canon_idx[r]][c]
    });

    eprintln!("PROGRESS 40 Computing regularized inverse operator (MNE / eLORETA)...");
    let l_lt = &l_mat * l_mat.transpose();
    let tr_l_lt = l_lt.trace();
    let lambda2 = if snr > 0.0 { 1.0 / (snr * snr) } else { 1.0 / 9.0 };
    let alpha = tr_l_lt / (m as f64) * lambda2;

    let mut reg_l_lt = l_lt;
    for i in 0..m {
        reg_l_lt[(i, i)] += alpha;
    }

    let inv_l_lt = reg_l_lt.try_inverse().ok_or("Failed to invert L*L^T matrix")?;
    let w_mat = l_mat.transpose() * inv_l_lt;

    eprintln!("PROGRESS 60 Projecting {} samples to {} cortical dipoles...", samples, n_sources);
    let x_data: Vec<Vec<f64>> = matched_rec_idx
        .iter()
        .map(|&idx| channels[idx].clone())
        .collect();

    eprintln!("PROGRESS 80 Extracting 68 ROI time courses (mean-flip alignment)...");
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
                let sum: f64 = (0..k).map(|row_idx| flips[row_idx] * s_roi[row_idx][s]).sum();
                roi_tc[s] = (sum / (k as f64)) * 10000.0;
            }
            roi_tc
        })
        .collect();

    let roi_labels: Vec<String> = model.rois.iter().map(|r| r.name.clone()).collect();
    eprintln!("PROGRESS 100 Source localization complete (68 ROIs extracted).");

    Ok((roi_channels, roi_labels))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_source_space_amplitude() {
        let labels = vec![
            "Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8",
            "T3", "C3", "Cz", "C4", "T4",
            "T5", "P3", "Pz", "P4", "T6",
            "O1", "O2"
        ].into_iter().map(|s| s.to_string()).collect::<Vec<_>>();

        let samples = 1000;
        let mut channels = Vec::new();
        for (i, _) in labels.iter().enumerate() {
            let ch = (0..samples).map(|s| 50.0 * ((s as f64) * 0.1 + (i as f64)).sin()).collect();
            channels.push(ch);
        }

        let (rois, roi_labels) = convert_to_source_space(&channels, &labels, 3.0).unwrap();
        assert_eq!(rois.len(), 68);
        assert_eq!(roi_labels.len(), 68);

        let max_val = rois.iter().flat_map(|ch| ch.iter()).cloned().fold(0.0f64, |a, b| a.max(b.abs()));
        println!("MAX ROI AMPLITUDE: {}", max_val);
    }
}
