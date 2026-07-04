use nalgebra::DMatrix;

fn calc_g(x: f64) -> f64 {
    let mut g = 0.0;
    let mut p_n_minus_1 = x; // P_1
    let mut p_n_minus_2 = 1.0; // P_0
    
    for n in 1..=50 {
        let n_f64 = n as f64;
        let p_n = if n == 1 {
            x
        } else {
            ((2.0 * n_f64 - 1.0) * x * p_n_minus_1 - (n_f64 - 1.0) * p_n_minus_2) / n_f64
        };
        
        let term = (2.0 * n_f64 + 1.0) / (n_f64.powi(4) * (n_f64 + 1.0).powi(4));
        g += term * p_n;
        
        if n > 1 {
            p_n_minus_2 = p_n_minus_1;
            p_n_minus_1 = p_n;
        }
    }
    g / (4.0 * std::f64::consts::PI)
}

pub fn make_interpolation_matrix(pos_from: &DMatrix<f64>, pos_to: &DMatrix<f64>) -> DMatrix<f64> {
    let n = pos_from.nrows();
    let m = pos_to.nrows();
    
    // Normalize coordinates
    let norm_from = DMatrix::from_fn(n, 3, |r, c| {
        let norm = (pos_from.row(r).dot(&pos_from.row(r))).sqrt();
        pos_from[(r, c)] / norm
    });
    
    let norm_to = DMatrix::from_fn(m, 3, |r, c| {
        let norm = (pos_to.row(r).dot(&pos_to.row(r))).sqrt();
        pos_to[(r, c)] / norm
    });
    
    let cos_dist = &norm_from * &norm_from.transpose();
    let cos_dist_to = &norm_from * &norm_to.transpose();
    
    let mut c = DMatrix::from_fn(n, n, |r, c_idx| calc_g(cos_dist[(r, c_idx)]));
    let c_to = DMatrix::from_fn(n, m, |r, c_idx| calc_g(cos_dist_to[(r, c_idx)]));
    
    // Add lambda
    for i in 0..n {
        c[(i, i)] += 1e-5;
    }
    
    // Solve system
    // A = [C, 1; 1^T, 0] (n+1 x n+1)
    let mut a = DMatrix::zeros(n + 1, n + 1);
    a.view_mut((0, 0), (n, n)).copy_from(&c);
    for i in 0..n {
        a[(i, n)] = 1.0;
        a[(n, i)] = 1.0;
    }
    
    // B = [C_to; 1^T] (n+1 x m)
    let mut b = DMatrix::zeros(n + 1, m);
    b.view_mut((0, 0), (n, m)).copy_from(&c_to);
    for i in 0..m {
        b[(n, i)] = 1.0;
    }
    
    // x = A^-1 B
    // We can use LU or SVD. LU is faster for square matrices
    let decomp = a.lu();
    let x = decomp.solve(&b).unwrap_or_else(|| DMatrix::zeros(n + 1, m));
    
    x.view((0, 0), (n, m)).into_owned()
}

use crate::montage::STANDARD_1005_POS;
use crate::Recording;
use rand::seq::SliceRandom;
use rand::thread_rng;

pub fn ransac_bad_channels(rec: &Recording, n_resample: usize, min_channels: f64, min_corr: f64) -> Vec<String> {
    let mut picks = Vec::new();
    let mut coords = Vec::new();
    for (i, label) in rec.labels.iter().enumerate() {
        if let Some(pos) = STANDARD_1005_POS.get(label.to_uppercase().as_str()) {
            picks.push(i);
            coords.push(*pos);
        }
    }
    if picks.len() < 4 {
        return Vec::new();
    }
    let n_channels = picks.len();
    let n_subset = (n_channels as f64 * min_channels).round().max(3.0) as usize;
    let pos_matrix = DMatrix::from_fn(n_channels, 3, |r, c| coords[r][c]);
    
    let samples = rec.channels.first().map(|ch| ch.len()).unwrap_or(0);
    let epoch_samples = rec.rate.round() as usize;
    let n_epochs = samples / epoch_samples;
    if n_epochs == 0 {
        return Vec::new();
    }
    
    let mut rng = thread_rng();
    let mut channel_indices: Vec<usize> = (0..n_channels).collect();
    let mut bad_log = vec![0; n_channels];
    
    let mut data = DMatrix::zeros(samples, n_channels);
    for (r_idx, &p) in picks.iter().enumerate() {
        for s in 0..samples {
            data[(s, r_idx)] = rec.channels[p][s] as f64;
        }
    }
    
    let mut mappings = Vec::with_capacity(n_resample);
    for _ in 0..n_resample {
        channel_indices.shuffle(&mut rng);
        let subset = &channel_indices[..n_subset];
        let subset_pos = DMatrix::from_fn(n_subset, 3, |r, c| coords[subset[r]][c]);
        let w = make_interpolation_matrix(&subset_pos, &pos_matrix);
        
        let mut full_w = DMatrix::zeros(n_channels, n_channels);
        for (i, &s_idx) in subset.iter().enumerate() {
            for c in 0..n_channels {
                full_w[(s_idx, c)] = w[(i, c)];
            }
        }
        mappings.push(full_w);
    }
    
    for e in 0..n_epochs {
        let start = e * epoch_samples;
        let epoch_data = data.rows(start, epoch_samples);
        let mut y_pred = vec![DMatrix::zeros(epoch_samples, n_channels); n_resample];
        for (i, w) in mappings.iter().enumerate() {
            y_pred[i] = &epoch_data * w;
        }
        
        let mut median_pred = DMatrix::zeros(epoch_samples, n_channels);
        for s in 0..epoch_samples {
            for c in 0..n_channels {
                let mut vals: Vec<f64> = y_pred.iter().map(|p| p[(s, c)]).collect();
                vals.sort_by(f64::total_cmp);
                median_pred[(s, c)] = vals[n_resample / 2];
            }
        }
        
        for c in 0..n_channels {
            let mut num: f64 = 0.0;
            let mut den1: f64 = 0.0;
            let mut den2: f64 = 0.0;
            for s in 0..epoch_samples {
                let d = epoch_data[(s, c)];
                let p = median_pred[(s, c)];
                num += d * p;
                den1 += d * d;
                den2 += p * p;
            }
            let corr = num / (den1.sqrt() * den2.sqrt() + 1e-15);
            if corr < min_corr {
                bad_log[c] += 1;
            }
        }
    }
    
    let bad_thresh = (n_epochs as f64 * 0.4).ceil() as i32;
    let mut bad_chs = Vec::new();
    for (i, &bad_count) in bad_log.iter().enumerate() {
        if bad_count > bad_thresh {
            bad_chs.push(rec.labels[picks[i]].clone());
        }
    }
    bad_chs
}
