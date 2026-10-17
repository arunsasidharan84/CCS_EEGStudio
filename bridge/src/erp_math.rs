//! ERP numerical kernels. Definitions and supported reference scope are documented
//! in docs/erp_workbench.md; no claim of full Unfold/ERPLAB toolbox coverage.
use nalgebra::{DMatrix, DVector};
use serde::Serialize;
use statrs::distribution::{ContinuousCDF, StudentsT};
#[derive(Debug, Clone, Serialize)]
pub struct Measures {
    pub mean: f64,
    pub signed_auc: f64,
    pub positive_auc: f64,
    pub negative_auc: f64,
    pub peak_amplitude: f64,
    pub peak_latency: f64,
    pub fractional_area_latency: Option<f64>,
    pub fractional_peak_latency: Option<f64>,
}
pub fn measure(
    times: &[f64],
    y: &[f64],
    window: [f64; 2],
    polarity: f64,
) -> Result<Measures, String> {
    let indices: Vec<_> = times
        .iter()
        .enumerate()
        .filter(|(_, t)| **t >= window[0] - 1e-10 && **t <= window[1] + 1e-10)
        .map(|(i, _)| i)
        .collect();
    if times.len() != y.len() || indices.len() < 2 || y.iter().any(|v| !v.is_finite()) {
        return Err("Measurement window needs at least two finite samples".into());
    }
    let mut signed = 0.;
    let mut pos = 0.;
    let mut neg = 0.;
    let mut cumulative = vec![0.; indices.len()];
    for k in 1..indices.len() {
        let i = indices[k - 1];
        let j = indices[k];
        let dt = times[j] - times[i];
        signed += (y[i] + y[j]) * dt / 2.;
        pos += (y[i].max(0.) + y[j].max(0.)) * dt / 2.;
        neg += (y[i].min(0.) + y[j].min(0.)) * dt / 2.;
        cumulative[k] =
            cumulative[k - 1] + ((polarity * y[i]).max(0.) + (polarity * y[j]).max(0.)) * dt / 2.;
    }

    // Determine effective polarity: if 0., auto-detect from window's dominant deflection
    let eff_polarity = if polarity.abs() > 1e-6 {
        polarity
    } else {
        let win_mean = indices.iter().map(|&i| y[i]).sum::<f64>() / indices.len() as f64;
        let mut max_pos = 0.0f64;
        let mut max_neg = 0.0f64;
        for &i in &indices {
            let diff = y[i] - win_mean;
            if diff > max_pos {
                max_pos = diff;
            }
            if -diff > max_neg {
                max_neg = -diff;
            }
        }
        if max_pos >= max_neg {
            1.0
        } else {
            -1.0
        }
    };

    // Find candidate local extrema within the window (excluding window endpoints)
    let mut local_peaks = Vec::new();
    let mut opp_local_peaks = Vec::new();
    for idx_k in 1..indices.len().saturating_sub(1) {
        let prev = y[indices[idx_k - 1]];
        let curr = y[indices[idx_k]];
        let next = y[indices[idx_k + 1]];
        if eff_polarity > 0.0 {
            if curr >= prev && curr >= next && (curr > prev || curr > next) {
                local_peaks.push(indices[idx_k]);
            }
            if curr <= prev && curr <= next && (curr < prev || curr < next) {
                opp_local_peaks.push(indices[idx_k]);
            }
        } else {
            if curr <= prev && curr <= next && (curr < prev || curr < next) {
                local_peaks.push(indices[idx_k]);
            }
            if curr >= prev && curr >= next && (curr > prev || curr > next) {
                opp_local_peaks.push(indices[idx_k]);
            }
        }
    }

    let peak = if !local_peaks.is_empty() {
        // Choose the local peak with the maximum prominent amplitude
        let mut best = local_peaks[0];
        for &p in &local_peaks[1..] {
            if eff_polarity * y[p] > eff_polarity * y[best] {
                best = p;
            }
        }
        best
    } else {
        // If no strict interior local peak, check best sample in indices
        let mut best = indices[0];
        for &i in &indices {
            if eff_polarity * y[i] > eff_polarity * y[best] {
                best = i;
            }
        }
        // If the extremum lands on the window endpoint, but an interior local peak exists
        // (e.g. component polarity was positive like P2/P3a but setting was negative),
        // pick the prominent interior local peak instead of an endpoint artifact.
        if (best == indices[0] || best == *indices.last().unwrap()) && !opp_local_peaks.is_empty() {
            let mut best_opp = opp_local_peaks[0];
            for &p in &opp_local_peaks[1..] {
                if -eff_polarity * y[p] > -eff_polarity * y[best_opp] {
                    best_opp = p;
                }
            }
            best = best_opp;
        }
        best
    };

    let total = *cumulative.last().unwrap();
    let area = if total > 0. {
        let k = (1..indices.len())
            .find(|&k| cumulative[k] >= total * 0.5)
            .unwrap();
        let frac = (total * 0.5 - cumulative[k - 1]) / (cumulative[k] - cumulative[k - 1]);
        Some(times[indices[k - 1]] + frac * (times[indices[k]] - times[indices[k - 1]]))
    } else {
        None
    };
    let threshold = eff_polarity * y[peak] * 0.5;
    let mut onset = None;
    if threshold > 0. {
        for pair in indices.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            if b > peak {
                break;
            }
            let (va, vb) = (eff_polarity * y[a], eff_polarity * y[b]);
            if va < threshold && vb >= threshold {
                onset = Some(times[a] + (threshold - va) / (vb - va) * (times[b] - times[a]));
                break;
            }
        }
    }
    Ok(Measures {
        mean: indices.iter().map(|&i| y[i]).sum::<f64>() / indices.len() as f64,
        signed_auc: signed,
        positive_auc: pos,
        negative_auc: neg,
        peak_amplitude: y[peak],
        peak_latency: times[peak],
        fractional_area_latency: area,
        fractional_peak_latency: onset,
    })
}
pub fn t_stat(x: &[f64]) -> f64 {
    let n = x.len();
    if n < 2 {
        return 0.;
    }
    let m = x.iter().sum::<f64>() / n as f64;
    let v = x.iter().map(|v| (v - m).powi(2)).sum::<f64>() / (n - 1) as f64;
    if v <= 1e-28 {
        if m.abs() < 1e-14 {
            0.
        } else {
            m.signum() * 1e12
        }
    } else {
        m / (v / n as f64).sqrt()
    }
}
pub fn paired_test(x: &[f64]) -> Option<(f64, f64)> {
    if x.len() < 2 {
        return None;
    }
    let t = t_stat(x);
    let dist = StudentsT::new(0., 1., (x.len() - 1) as f64).ok()?;
    Some((t, 2. * dist.sf(t.abs())))
}
/// SVD least squares, matching numpy.linalg.lstsq for the explicit design.
pub fn regression(x: &DMatrix<f64>, y: &DMatrix<f64>) -> Result<(DMatrix<f64>, usize), String> {
    if x.nrows() != y.nrows() || x.nrows() < x.ncols() + 1 {
        return Err("Regression needs more observations than predictors".into());
    }
    let svd = x.clone().svd(true, true);
    let max = svd.singular_values.iter().copied().fold(0., f64::max);
    let cutoff = max * 1e-10;
    let rank = svd.singular_values.iter().filter(|v| **v > cutoff).count();
    if rank < x.ncols() {
        return Err("Regression design is rank deficient; remove redundant predictors".into());
    }
    Ok((svd.solve(y, cutoff).map_err(|e| e.to_string())?, rank))
}
#[derive(Clone)]
pub struct SparseDesign {
    pub rows: Vec<Vec<(usize, f64)>>,
    pub columns: usize,
}
impl SparseDesign {
    fn mv(&self, x: &DVector<f64>) -> DVector<f64> {
        DVector::from_iterator(
            self.rows.len(),
            self.rows
                .iter()
                .map(|r| r.iter().map(|&(j, v)| x[j] * v).sum()),
        )
    }
    fn tmv(&self, x: &DVector<f64>) -> DVector<f64> {
        let mut out = DVector::zeros(self.columns);
        for (i, row) in self.rows.iter().enumerate() {
            for &(j, v) in row {
                out[j] += v * x[i];
            }
        }
        out
    }
}
#[derive(Serialize)]
pub struct LsqrResult {
    pub coefficients: Vec<f64>,
    pub iterations: usize,
    pub residual_norm: f64,
    pub normal_residual_norm: f64,
    pub converged: bool,
}
/// Paige-Saunders LSQR, sparse matvecs; no dense time-expanded design allocation.
pub fn lsqr(
    a: &SparseDesign,
    y: &[f64],
    tolerance: f64,
    max_iter: usize,
) -> Result<LsqrResult, String> {
    if y.len() != a.rows.len()
        || a.columns == 0
        || max_iter == 0
        || tolerance <= 0.
        || a.rows
            .iter()
            .flatten()
            .any(|&(j, v)| j >= a.columns || !v.is_finite())
        || y.iter().any(|v| !v.is_finite())
    {
        return Err("Invalid LSQR design or response".into());
    }
    let mut x = DVector::zeros(a.columns);
    let mut u = DVector::from_column_slice(y);
    let norm_b = u.norm();
    let mut beta = norm_b;
    if beta > 0. {
        u /= beta;
    }
    let mut v = a.tmv(&u);
    let mut alpha = v.norm();
    if alpha > 0. {
        v /= alpha;
    }
    let mut w = v.clone();
    let mut phi_bar = beta;
    let mut rho_bar = alpha;
    let mut iterations = 0;
    let mut converged = alpha == 0. || beta == 0.;
    let mut norm_a = 0_f64;
    for it in 0..max_iter {
        if converged {
            break;
        }
        u = a.mv(&v) - u * alpha;
        beta = u.norm();
        if beta > 0. {
            u /= beta;
        }
        norm_a = (norm_a * norm_a + alpha * alpha + beta * beta).sqrt();
        v = a.tmv(&u) - v * beta;
        alpha = v.norm();
        if alpha > 0. {
            v /= alpha;
        }
        let rho = rho_bar.hypot(beta);
        if rho == 0. {
            break;
        }
        let c = rho_bar / rho;
        let s = beta / rho;
        let theta = s * alpha;
        rho_bar = -c * alpha;
        let phi = c * phi_bar;
        phi_bar *= s;
        x += w.clone() * (phi / rho);
        w = v.clone() - w * (theta / rho);
        iterations = it + 1;
        let residual = a.mv(&x) - DVector::from_column_slice(y);
        let nr = residual.norm();
        let gradient = a.tmv(&residual).norm();
        converged = nr <= tolerance * (norm_b + norm_a * x.norm())
            || gradient <= tolerance * norm_a * nr.max(1e-30);
    }
    let residual = a.mv(&x) - DVector::from_column_slice(y);
    Ok(LsqrResult {
        coefficients: x.iter().copied().collect(),
        iterations,
        residual_norm: residual.norm(),
        normal_residual_norm: a.tmv(&residual).norm(),
        converged,
    })
}
/// Shrinkage LDA, train-fold centering/scaling only. Equal class priors.
pub fn lda_scores(
    train: &DMatrix<f64>,
    labels: &[usize],
    test: &DMatrix<f64>,
    shrinkage: f64,
) -> Result<Vec<f64>, String> {
    let n = train.nrows();
    let p = train.ncols();
    let counts = [
        labels.iter().filter(|&&v| v == 0).count(),
        labels.iter().filter(|&&v| v == 1).count(),
    ];
    if n != labels.len() || test.ncols() != p || counts.iter().any(|&n| n < 2) {
        return Err("Each decoding training class needs at least two trials".into());
    }
    let mean: Vec<_> = (0..p)
        .map(|j| (0..n).map(|i| train[(i, j)]).sum::<f64>() / n as f64)
        .collect();
    let sd: Vec<_> = (0..p)
        .map(|j| {
            ((0..n)
                .map(|i| (train[(i, j)] - mean[j]).powi(2))
                .sum::<f64>()
                / n as f64)
                .sqrt()
                .max(1e-12)
        })
        .collect();
    let z = DMatrix::from_fn(n, p, |i, j| (train[(i, j)] - mean[j]) / sd[j]);
    let means: Vec<DVector<f64>> = (0..2)
        .map(|k| {
            DVector::from_iterator(
                p,
                (0..p).map(|j| {
                    (0..n)
                        .filter(|&i| labels[i] == k)
                        .map(|i| z[(i, j)])
                        .sum::<f64>()
                        / counts[k] as f64
                }),
            )
        })
        .collect();
    let residual = DMatrix::from_fn(n, p, |i, j| z[(i, j)] - means[labels[i]][j]);
    let mut cov = residual.transpose() * residual / (n - 2) as f64;
    let scale = cov.trace() / p as f64;
    cov *= 1. - shrinkage;
    cov += DMatrix::identity(p, p) * (shrinkage * scale + 1e-12);
    let delta = &means[1] - &means[0];
    let weights = cov
        .lu()
        .solve(&delta)
        .ok_or("LDA covariance solve failed")?;
    let intercept = -0.5 * (&means[1] + &means[0]).dot(&weights);
    Ok((0..test.nrows())
        .map(|i| {
            intercept
                + (0..p)
                    .map(|j| (test[(i, j)] - mean[j]) / sd[j] * weights[j])
                    .sum::<f64>()
        })
        .collect())
}
pub fn auc(labels: &[usize], scores: &[f64]) -> Option<f64> {
    let a: Vec<_> = scores
        .iter()
        .zip(labels)
        .filter(|(_, l)| **l == 1)
        .map(|(s, _)| *s)
        .collect();
    let b: Vec<_> = scores
        .iter()
        .zip(labels)
        .filter(|(_, l)| **l == 0)
        .map(|(s, _)| *s)
        .collect();
    if a.is_empty() || b.is_empty() {
        return None;
    }
    Some(
        a.iter()
            .map(|x| {
                b.iter()
                    .map(|y| {
                        if x > y {
                            1.
                        } else if x == y {
                            0.5
                        } else {
                            0.
                        }
                    })
                    .sum::<f64>()
            })
            .sum::<f64>()
            / (a.len() * b.len()) as f64,
    )
}
/// Paired sign-flip max-|t| family correction, subjects × flattened nodes.
pub fn max_t(differences: &[Vec<f64>], signs: &[Vec<f64>]) -> (Vec<f64>, Vec<f64>) {
    let n = differences.len();
    if n < 2 {
        return (Vec::new(), Vec::new());
    }
    let p = differences[0].len();
    let observed: Vec<_> = (0..p)
        .map(|j| t_stat(&differences.iter().map(|r| r[j]).collect::<Vec<_>>()))
        .collect();
    let null: Vec<_> = signs
        .iter()
        .map(|s| {
            (0..p)
                .map(|j| {
                    t_stat(&(0..n).map(|i| differences[i][j] * s[i]).collect::<Vec<_>>()).abs()
                })
                .fold(0., f64::max)
        })
        .collect();
    let pv = observed
        .iter()
        .map(|t| null.iter().filter(|v| **v >= t.abs() - 1e-10).count() as f64 / null.len() as f64)
        .collect();
    (observed, pv)
}
