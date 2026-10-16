//! Gaussian-copula estimators following BraiNets Frites (BSD-3-Clause).
//! Temporal TE uses lagged samples within each epoch; epochs are never pooled.
use nalgebra::DMatrix;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use statrs::{
    distribution::{ContinuousCDF, Normal},
    function::gamma::digamma,
};
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct InformationOptions {
    pub spectral_graph: bool,
    pub gcmi: bool,
    pub te: bool,
    pub output: String,
    pub graph_density: f64,
    pub te_min_delay: usize,
    pub te_max_delay: usize,
    pub te_step: usize,
    pub te_source_history: usize,
    pub te_target_history: usize,
    pub te_history_step: usize,
    pub te_estimator: String,
}
impl Default for InformationOptions {
    fn default() -> Self {
        Self {
            spectral_graph: false,
            gcmi: false,
            te: false,
            output: "both".into(),
            graph_density: 0.2,
            te_min_delay: 0,
            te_max_delay: 1,
            te_step: 1,
            te_source_history: 1,
            te_target_history: 1,
            te_history_step: 1,
            te_estimator: "time_copula_cmi".into(),
        }
    }
}
impl InformationOptions {
    pub fn validate(&self) -> Result<(), String> {
        if !["edges", "graph", "both"].contains(&self.output.as_str())
            || !self.graph_density.is_finite()
            || self.graph_density <= 0.0
            || self.graph_density > 1.0
            || self.te_step == 0
            || self.te_source_history == 0
            || self.te_source_history > 20
            || self.te_target_history == 0
            || self.te_target_history > 20
            || self.te_history_step == 0
            || self.te_history_step > 1000
            || self.te_max_delay > 100000
            || self.te_estimator != "time_copula_cmi"
            || self.te_max_delay <= self.te_min_delay
        {
            return Err("Invalid connectivity output, graph density, or TE delays".into());
        }
        Ok(())
    }
}
pub fn copnorm(x: &[f64]) -> Vec<f64> {
    if x.iter().any(|v| !v.is_finite()) || x.is_empty() || x.iter().all(|v| *v == x[0]) {
        return vec![f64::NAN; x.len()];
    }
    // Ordinal ranks as Frites ctransform, deterministic input-order ties.
    let mut order: Vec<usize> = (0..x.len()).collect();
    order.sort_by(|&a, &b| x[a].total_cmp(&x[b]));
    let normal = Normal::new(0.0, 1.0).unwrap();
    let mut out = vec![0.0; x.len()];
    for (rank, &i) in order.iter().enumerate() {
        out[i] = normal.inverse_cdf((rank + 1) as f64 / (x.len() + 1) as f64);
    }
    out
}
fn entropy(vars: &[&[f64]]) -> f64 {
    let p = vars.len();
    let n = vars[0].len();
    if n <= p
        || vars
            .iter()
            .any(|v| v.len() != n || v.iter().any(|x| !x.is_finite()))
    {
        return f64::NAN;
    }
    let means: Vec<f64> = vars
        .iter()
        .map(|v| v.iter().sum::<f64>() / n as f64)
        .collect();
    let cov = DMatrix::from_fn(p, p, |i, j| {
        vars[i]
            .iter()
            .zip(vars[j])
            .map(|(a, b)| (a - means[i]) * (b - means[j]))
            .sum::<f64>()
            / (n - 1) as f64
    });
    let Some(ch) = cov.cholesky() else {
        return f64::NAN;
    };
    let h = ch.l().diagonal().iter().map(|v| v.ln()).sum::<f64>();
    h - (p as f64) * ((2.0_f64).ln() - ((n - 1) as f64).ln()) / 2.0
        - (1..=p)
            .map(|k| digamma((n - k) as f64 / 2.0) / 2.0)
            .sum::<f64>()
}
pub fn gaussian_mi(x: &[f64], y: &[f64]) -> f64 {
    (entropy(&[x]) + entropy(&[y]) - entropy(&[x, y])) / 2.0_f64.ln()
}
pub fn gaussian_cmi(x: &[f64], y: &[f64], z: &[f64]) -> f64 {
    (entropy(&[x, z]) + entropy(&[y, z]) - entropy(&[x, y, z]) - entropy(&[z])) / 2.0_f64.ln()
}
pub fn gcmi_matrix(channels: &[Vec<f32>], a: usize, b: usize) -> Vec<Vec<f64>> {
    let x: Vec<Vec<f64>> = channels
        .iter()
        .map(|c| copnorm(&c[a..b].iter().map(|&v| v as f64).collect::<Vec<_>>()))
        .collect();
    let n = x.len();
    let mut w = vec![vec![0.0; n]; n];
    for i in 0..n {
        for j in 0..i {
            w[i][j] = gaussian_mi(&x[i], &x[j]);
            w[j][i] = w[i][j];
        }
    }
    w
}
/// I(X past; Y present | Y past), observations along time in ONE epoch.
/// Rank normalization is applied separately to each aligned embedding variable.
pub fn temporal_te_matrix(
    channels: &[Vec<f32>],
    start: usize,
    end: usize,
    o: &InformationOptions,
) -> Result<Vec<Vec<f64>>, String> {
    o.validate()?;
    if channels.len() < 2 || start >= end || channels.iter().any(|c| end > c.len()) {
        return Err("Temporal TE needs at least two nodes and valid epoch bounds".into());
    }
    let history = (o.te_max_delay + (o.te_source_history - 1) * o.te_history_step)
        .max(1 + (o.te_target_history - 1) * o.te_history_step);
    let observations = (end - start).saturating_sub(history);
    let minimum = 20usize.max(o.te_source_history + o.te_target_history + 3);
    if observations < minimum {
        return Err(format!("Temporal TE needs at least {minimum} aligned time samples after lag/history embedding; got {observations}. Use a longer epoch or shorter history/delay."));
    }
    let embed = |channel: usize, lag: usize| {
        copnorm(
            &(start + history..end)
                .map(|t| channels[channel][t - lag] as f64)
                .collect::<Vec<_>>(),
        )
    };
    let present: Vec<_> = (0..channels.len()).map(|c| embed(c, 0)).collect();
    let target_past: Vec<Vec<Vec<f64>>> = (0..channels.len())
        .map(|c| {
            (0..o.te_target_history)
                .map(|h| embed(c, 1 + h * o.te_history_step))
                .collect()
        })
        .collect();
    let delays: Vec<_> = (o.te_min_delay + 1..=o.te_max_delay)
        .step_by(o.te_step)
        .collect();
    let mut w = vec![vec![0.0; channels.len()]; channels.len()];
    w.par_iter_mut().enumerate().for_each(|(i, row)| {
        let source_past: Vec<Vec<Vec<f64>>> = delays
            .iter()
            .map(|&d| {
                (0..o.te_source_history)
                    .map(|h| embed(i, d + h * o.te_history_step))
                    .collect()
            })
            .collect();
        for j in 0..channels.len() {
            if i == j {
                continue;
            }
            let z: Vec<&[f64]> = target_past[j].iter().map(|v| v.as_slice()).collect();
            let yz: Vec<&[f64]> = std::iter::once(present[j].as_slice())
                .chain(z.iter().copied())
                .collect();
            let hz = entropy(&z);
            let hyz = entropy(&yz);
            let mut sum = 0.0;
            for source in &source_past {
                let xz: Vec<&[f64]> = source
                    .iter()
                    .map(|v| v.as_slice())
                    .chain(z.iter().copied())
                    .collect();
                let xyz: Vec<&[f64]> = source
                    .iter()
                    .map(|v| v.as_slice())
                    .chain(yz.iter().copied())
                    .collect();
                sum += (entropy(&xz) + hyz - entropy(&xyz) - hz) / 2.0_f64.ln();
            }
            row[j] = sum / delays.len() as f64;
        }
    });
    Ok(w)
}
pub const GRAPH_NAMES: [&str; 7] = [
    "out_strength",
    "in_strength",
    "degree",
    "clustering",
    "efficiency",
    "global_efficiency",
    "density",
];
/// Positive proportional threshold, symmetric mean projection for paths and clustering.
pub fn graph_features(raw: &[Vec<f64>], density: f64) -> Vec<Vec<f64>> {
    let n = raw.len();
    if n < 2
        || raw
            .iter()
            .enumerate()
            .any(|(i, r)| r.iter().enumerate().any(|(j, v)| i != j && !v.is_finite()))
    {
        return vec![vec![f64::NAN; 7]; n];
    }
    let mut edges = Vec::new();
    for i in 0..n {
        for j in 0..i {
            let v = (raw[i][j].max(0.0) + raw[j][i].max(0.0)) / 2.0;
            if v > 0.0 {
                edges.push((v, i, j));
            }
        }
    }
    edges.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)));
    let keep = ((n * (n - 1) / 2) as f64 * density).round() as usize;
    edges.truncate(keep);
    let max = edges.first().map(|e| e.0).unwrap_or(1.0);
    let mut w = vec![vec![0.0; n]; n];
    let mut selected = vec![vec![false; n]; n];
    for &(v, i, j) in &edges {
        w[i][j] = v / max;
        w[j][i] = v / max;
        selected[i][j] = true;
        selected[j][i] = true;
    }
    let mut dist = vec![vec![f64::INFINITY; n]; n];
    for i in 0..n {
        dist[i][i] = 0.0;
        for j in 0..n {
            if w[i][j] > 0.0 {
                dist[i][j] = 1.0 / w[i][j];
            }
        }
    }
    for k in 0..n {
        for i in 0..n {
            for j in 0..n {
                dist[i][j] = dist[i][j].min(dist[i][k] + dist[k][j]);
            }
        }
    }
    let mut out = vec![vec![0.0; 7]; n];
    for i in 0..n {
        let neighbors: Vec<usize> = (0..n).filter(|&j| selected[i][j]).collect();
        let k = neighbors.len();
        out[i][0] = neighbors.iter().map(|&j| raw[i][j].max(0.0)).sum();
        out[i][1] = neighbors.iter().map(|&j| raw[j][i].max(0.0)).sum();
        out[i][2] = k as f64;
        if k > 1 {
            for &j in &neighbors {
                for &h in &neighbors {
                    out[i][3] += (w[i][j] * w[j][h] * w[h][i]).cbrt();
                }
            }
            out[i][3] /= (k * (k - 1)) as f64;
        }
        out[i][4] = (0..n)
            .filter(|&j| i != j)
            .map(|j| 1.0 / dist[i][j])
            .sum::<f64>()
            / (n - 1) as f64;
        out[i][6] = 2.0 * edges.len() as f64 / (n * (n - 1)) as f64;
    }
    let global = out.iter().map(|r| r[4]).sum::<f64>() / n as f64;
    for row in &mut out {
        row[5] = global;
    }
    out
}
pub fn column_names(labels: &[String], o: &InformationOptions) -> Vec<String> {
    let mut out = Vec::new();
    for (on, name) in [(o.gcmi, "gcmi"), (o.te, "te_time")] {
        if !on {
            continue;
        }
        if o.output != "graph" {
            out.extend(labels.iter().map(|l| format!("conn_{name}_to_{l}")));
        }
        if o.output != "edges" {
            out.extend(GRAPH_NAMES.iter().map(|g| format!("graph_{name}_{g}")));
        }
    }
    out
}
pub fn summarize(matrix: &[Vec<f64>], o: &InformationOptions) -> Vec<Vec<f64>> {
    let graph = graph_features(matrix, o.graph_density);
    matrix
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let mut row = Vec::new();
            if o.output != "graph" {
                row.extend(
                    r.iter()
                        .enumerate()
                        .map(|(j, &v)| if i == j { f64::NAN } else { v }),
                );
            }
            if o.output != "edges" {
                row.extend(&graph[i]);
            }
            row
        })
        .collect()
}

pub fn network_columns(name: &str, labels: &[String], o: &InformationOptions) -> Vec<String> {
    let mut out = Vec::new();
    if o.output != "graph" {
        out.extend(labels.iter().map(|l| format!("conn_pair_{name}_to_{l}")));
    }
    if o.output != "edges" {
        out.extend(GRAPH_NAMES.iter().map(|g| format!("graph_{name}_{g}")));
    }
    out
}
