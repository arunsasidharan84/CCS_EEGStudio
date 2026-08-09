use serde::{Deserialize, Serialize};
use rand::seq::SliceRandom;
use rand::SeedableRng;
use rand::rngs::StdRng;

// ── 10-20 Standard Montage Channel Positions & Adjacency ─────────────────
pub const STANDARD_1020_CHANNELS: &[&str] = &[
    "Fp1", "Fz", "F3", "F7", "FT9", "FC5", "FC1", "C3", "T7", "TP9",
    "CP5", "CP1", "Pz", "P3", "P7", "O1", "Oz", "O2", "P4", "P8",
    "TP10", "CP6", "CP2", "Cz", "C4", "T8", "FT10", "FC6", "FC2",
    "F4", "F8", "Fp2",
];

/// Returns 2D coordinates (x, y) for 10-20 channels normalized to [-1, 1]
pub fn get_channel_coords_2d(ch_name: &str) -> (f64, f64) {
    match ch_name.to_uppercase().as_str() {
        "FP1" => (-0.3, 0.85),
        "FP2" => (0.3, 0.85),
        "FZ"  => (0.0, 0.60),
        "F3"  => (-0.45, 0.55),
        "F4"  => (0.45, 0.55),
        "F7"  => (-0.80, 0.60),
        "F8"  => (0.80, 0.60),
        "FT9" => (-0.95, 0.35),
        "FT10" => (0.95, 0.35),
        "FC5" => (-0.65, 0.35),
        "FC1" => (-0.25, 0.35),
        "FC2" => (0.25, 0.35),
        "FC6" => (0.65, 0.35),
        "CZ"  => (0.0, 0.0),
        "C3"  => (-0.50, 0.0),
        "C4"  => (0.50, 0.0),
        "T7"  => (-0.85, 0.0),
        "T8"  => (0.85, 0.0),
        "TP9" => (-0.95, -0.35),
        "TP10" => (0.95, -0.35),
        "CP5" => (-0.65, -0.35),
        "CP1" => (-0.25, -0.35),
        "CP2" => (0.25, -0.35),
        "CP6" => (0.65, -0.35),
        "PZ"  => (0.0, -0.60),
        "P3"  => (-0.45, -0.55),
        "P4"  => (0.45, -0.55),
        "P7"  => (-0.80, -0.60),
        "P8"  => (0.80, -0.60),
        "O1"  => (-0.35, -0.85),
        "OZ"  => (0.0, -0.90),
        "O2"  => (0.35, -0.85),
        _     => (0.0, 0.0),
    }
}

/// Builds 10-20 channel adjacency list (neighbors within distance threshold)
pub fn get_channel_adjacency(labels: &[String]) -> Vec<Vec<usize>> {
    let n = labels.len();
    let mut adj = vec![Vec::new(); n];
    let coords: Vec<(f64, f64)> = labels.iter().map(|l| get_channel_coords_2d(l)).collect();

    for i in 0..n {
        for j in 0..n {
            if i != j {
                let dx = coords[i].0 - coords[j].0;
                let dy = coords[i].1 - coords[j].1;
                let dist = (dx * dx + dy * dy).sqrt();
                if dist < 0.48 { // neighbor distance threshold
                    adj[i].push(j);
                }
            }
        }
    }
    adj
}

// ── Basic Statistics Utilities ───────────────────────────────────────────
pub fn mean(xs: &[f64]) -> f64 {
    if xs.is_empty() { return 0.0; }
    xs.iter().sum::<f64>() / xs.len() as f64
}

pub fn std_dev(xs: &[f64], ddof: usize) -> f64 {
    if xs.len() <= ddof { return 0.0; }
    let m = mean(xs);
    let var = xs.iter().map(|x| (x - m).powi(2)).sum::<f64>() / (xs.len() - ddof) as f64;
    var.sqrt()
}

pub fn sem(xs: &[f64]) -> f64 {
    if xs.is_empty() { return 0.0; }
    std_dev(xs, 1) / (xs.len() as f64).sqrt()
}

pub fn cohens_d(a: &[f64], b: &[f64]) -> f64 {
    let n1 = a.len();
    let n2 = b.len();
    if n1 < 2 || n2 < 2 { return 0.0; }
    let m1 = mean(a);
    let m2 = mean(b);
    let s1 = std_dev(a, 1);
    let s2 = std_dev(b, 1);
    let pooled_var = (((n1 - 1) as f64 * s1.powi(2)) + ((n2 - 1) as f64 * s2.powi(2))) / (n1 + n2 - 2) as f64;
    if pooled_var <= 0.0 { return 0.0; }
    (m1 - m2) / pooled_var.sqrt()
}

pub fn welch_t_test(a: &[f64], b: &[f64]) -> (f64, f64, f64) { // (t, p, df)
    let n1 = a.len() as f64;
    let n2 = b.len() as f64;
    if n1 < 2.0 || n2 < 2.0 { return (0.0, 1.0, 1.0); }
    let m1 = mean(a);
    let m2 = mean(b);
    let v1 = std_dev(a, 1).powi(2);
    let v2 = std_dev(b, 1).powi(2);
    let se = (v1 / n1 + v2 / n2).sqrt();
    if se <= 0.0 { return (0.0, 1.0, 1.0); }
    let t = (m1 - m2) / se;
    let df = (v1 / n1 + v2 / n2).powi(2) / ((v1 / n1).powi(2) / (n1 - 1.0) + (v2 / n2).powi(2) / (n2 - 1.0));

    // Approximate two-tailed p-value using Student's t approximation
    let p = approx_t_pvalue(t.abs(), df);
    (t, p, df)
}

fn approx_t_pvalue(t: f64, df: f64) -> f64 {
    // Normal approximation for large df, or basic Series approximation
    let z = t / (1.0 + t * t / (4.0 * df)).sqrt();
    let p_norm = 0.5 * erfc(z / std::f64::consts::SQRT_2);
    (2.0 * p_norm).clamp(0.0, 1.0)
}

fn erfc(x: f64) -> f64 {
    // Complementary error function approximation
    let a1 = 0.254829592;
    let a2 = -0.284496736;
    let a3 = 1.421413741;
    let a4 = -1.453152027;
    let a5 = 1.061405429;
    let p  = 0.3275911;

    let sign = if x < 0.0 { -1.0 } else { 1.0 };
    let abs_x = x.abs();
    let t = 1.0 / (1.0 + p * abs_x);
    let y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * (-abs_x * abs_x).exp();
    if sign < 0.0 { 2.0 - (1.0 - y) } else { 1.0 - y }
}

// ── Benjamini-Hochberg FDR ──────────────────────────────────────────────
pub fn fdr_bh(pvals: &[f64], alpha: f64) -> (Vec<bool>, Vec<f64>) {
    let n = pvals.len();
    if n == 0 { return (Vec::new(), Vec::new()); }
    let mut indexed: Vec<(usize, f64)> = pvals.iter().cloned().enumerate().collect();
    indexed.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));

    let mut q_raw = vec![0.0; n];
    for k in 0..n {
        let rank = (k + 1) as f64;
        q_raw[k] = indexed[k].1 * (n as f64) / rank;
    }

    // Accumulate minimum from right to left
    let mut q_sorted = vec![0.0; n];
    let mut min_q: f64 = 1.0;
    for k in (0..n).rev() {
        min_q = min_q.min(q_raw[k]);
        q_sorted[k] = min_q.clamp(0.0, 1.0);
    }

    let mut q = vec![0.0; n];
    let mut reject = vec![false; n];
    for k in 0..n {
        let orig_idx = indexed[k].0;
        q[orig_idx] = q_sorted[k];
        reject[orig_idx] = q_sorted[k] <= alpha;
    }

    (reject, q)
}

// ── Cluster Permutation Test for Waveforms ──────────────────────────────
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ErpCluster {
    pub start_idx: usize,
    pub end_idx: usize,
    pub mass: f64,
    pub p_value: f64,
    pub start_sec: f64,
    pub end_sec: f64,
}

pub fn cluster_permutation_test_1d(
    cond_a: &[Vec<f64>], // (n_trials_a, n_times)
    cond_b: &[Vec<f64>], // (n_trials_b, n_times)
    times: &[f64],
    n_perm: usize,
    seed: u64,
) -> (Vec<f64>, Vec<ErpCluster>) {
    let n_a = cond_a.len();
    let n_b = cond_b.len();
    let n_times = times.len();

    if n_a < 2 || n_b < 2 || n_times == 0 {
        return (vec![0.0; n_times], Vec::new());
    }

    // Critical t-threshold (approx 2.0 for alpha=0.05)
    let df = (n_a + n_b - 2) as f64;
    let t_thresh = 1.98;

    let calc_t = |a: &[Vec<f64>], b: &[Vec<f64>]| -> Vec<f64> {
        let mut t_obs = vec![0.0; n_times];
        for t in 0..n_times {
            let sample_a: Vec<f64> = a.iter().map(|row| row[t]).collect();
            let sample_b: Vec<f64> = b.iter().map(|row| row[t]).collect();
            let (stat, _, _) = welch_t_test(&sample_a, &sample_b);
            t_obs[t] = stat;
        }
        t_obs
    };

    let find_clusters = |t_arr: &[f64]| -> Vec<(usize, usize, f64)> {
        let mut clusters = Vec::new();
        let mut idx = 0;
        while idx < n_times {
            if t_arr[idx].abs() > t_thresh {
                let start = idx;
                let sign = t_arr[idx].signum();
                while idx < n_times && t_arr[idx].abs() > t_thresh && t_arr[idx].signum() == sign {
                    idx += 1;
                }
                let end = idx;
                let mass: f64 = t_arr[start..end].iter().map(|x| x.abs()).sum();
                clusters.push((start, end, mass));
            } else {
                idx += 1;
            }
        }
        clusters
    };

    let t_obs = calc_t(cond_a, cond_b);
    let obs_clusters = find_clusters(&t_obs);

    // Permutation distribution of max cluster mass
    let mut pooled = Vec::with_capacity(n_a + n_b);
    pooled.extend_from_slice(cond_a);
    pooled.extend_from_slice(cond_b);

    let mut rng = StdRng::seed_from_u64(seed);
    let mut max_null_masses = vec![0.0; n_perm];

    for p in 0..n_perm {
        let mut perm_indices: Vec<usize> = (0..pooled.len()).collect();
        perm_indices.shuffle(&mut rng);

        let perm_a: Vec<Vec<f64>> = perm_indices[0..n_a].iter().map(|&i| pooled[i].clone()).collect();
        let perm_b: Vec<Vec<f64>> = perm_indices[n_a..].iter().map(|&i| pooled[i].clone()).collect();

        let t_perm = calc_t(&perm_a, &perm_b);
        let perm_clusters = find_clusters(&t_perm);
        let max_m = perm_clusters.iter().map(|c| c.2).fold(0.0, f64::max);
        max_null_masses[p] = max_m;
    }

    let mut result_clusters = Vec::new();
    for (start, end, mass) in obs_clusters {
        let ge_count = max_null_masses.iter().filter(|&&m| m >= mass).count();
        let p_val = (ge_count as f64 + 1.0) / (n_perm as f64 + 1.0);
        result_clusters.push(ErpCluster {
            start_idx: start,
            end_idx: end,
            mass,
            p_value: p_val,
            start_sec: times[start],
            end_sec: times[end.min(n_times - 1)],
        });
    }

    (t_obs, result_clusters)
}

// ── e-TFCE Statistics for Channel Features ──────────────────────────────
pub fn etfce_channel_stats(
    base_matrix: &[Vec<f64>], // (n_epochs_base, n_channels)
    test_matrix: &[Vec<f64>], // (n_epochs_test, n_channels)
    adjacency: &[Vec<usize>],
    n_perm: usize,
    seed: u64,
) -> (Vec<f64>, Vec<f64>) { // (t_obs, raw_pvals)
    let n_ch = base_matrix[0].len();
    let mut t_obs = vec![0.0; n_ch];

    for c in 0..n_ch {
        let base_col: Vec<f64> = base_matrix.iter().map(|row| row[c]).collect();
        let test_col: Vec<f64> = test_matrix.iter().map(|row| row[c]).collect();
        let (stat, _, _) = welch_t_test(&test_col, &base_col);
        t_obs[c] = stat;
    }

    // Simplified e-TFCE score calculation on graph
    let calc_tfce_score = |t_arr: &[f64]| -> Vec<f64> {
        let mut score = vec![0.0; n_ch];
        let dh = 0.2;
        let mut h = 0.0;
        while h < 6.0 {
            for c in 0..n_ch {
                if t_arr[c].abs() > h {
                    // Count adjacent active channels
                    let mut ext: f64 = 1.0;
                    for &nbr in &adjacency[c] {
                        if t_arr[nbr].abs() > h {
                            ext += 1.0;
                        }
                    }
                    let e_term = ext.powf(0.5);
                    let h_term = h.powf(2.0);
                    score[c] += e_term * h_term * dh;
                }
            }
            h += dh;
        }
        score
    };

    let obs_scores = calc_tfce_score(&t_obs);

    // Permutation testing for max score
    let mut pooled = Vec::new();
    pooled.extend_from_slice(base_matrix);
    pooled.extend_from_slice(test_matrix);

    let n_base = base_matrix.len();
    let mut rng = StdRng::seed_from_u64(seed);
    let mut max_null_scores = vec![0.0; n_perm];

    for p in 0..n_perm {
        let mut perm_indices: Vec<usize> = (0..pooled.len()).collect();
        perm_indices.shuffle(&mut rng);

        let perm_base: Vec<Vec<f64>> = perm_indices[0..n_base].iter().map(|&i| pooled[i].clone()).collect();
        let perm_test: Vec<Vec<f64>> = perm_indices[n_base..].iter().map(|&i| pooled[i].clone()).collect();

        let mut perm_t = vec![0.0; n_ch];
        for c in 0..n_ch {
            let b_col: Vec<f64> = perm_base.iter().map(|row| row[c]).collect();
            let t_col: Vec<f64> = perm_test.iter().map(|row| row[c]).collect();
            let (stat, _, _) = welch_t_test(&t_col, &b_col);
            perm_t[c] = stat;
        }
        let perm_scores = calc_tfce_score(&perm_t);
        let max_s = perm_scores.iter().cloned().fold(0.0, f64::max);
        max_null_scores[p] = max_s;
    }

    let mut p_vals = vec![1.0; n_ch];
    for c in 0..n_ch {
        let ge_count = max_null_scores.iter().filter(|&&s| s >= obs_scores[c]).count();
        p_vals[c] = (ge_count as f64 + 1.0) / (n_perm as f64 + 1.0);
    }

    (t_obs, p_vals)
}
