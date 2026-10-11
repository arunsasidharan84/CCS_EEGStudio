//! Port of the `picard` Python package (Ablin, Cardoso, Gramfort 2018; v0.8) — `picard()` + `core_picard()`
//! with the `tanh` density. Supports standard Picard and Picard-O (`ortho`), `extended`, PCA-whitening and
//! `w_init`, mirroring the reference line by line. Also `pop_picard`, which mirrors EEGLAB
//! `pop_runica(...,'icatype','picard')` / eegprep `eeg_picard` (sphere = I, weights = W*K).

use crate::linalg::*;
use crate::pop_runica::IcaResult;

#[derive(Clone, Debug)]
pub struct PicardOpts {
    pub ortho: bool,
    /// `None` -> same as `ortho` (as in the reference).
    pub extended: Option<bool>,
    pub n_components: Option<usize>,
    pub whiten: bool,
    pub centering: bool,
    pub max_iter: usize,
    pub tol: f64,
    pub m: usize,
    pub ls_tries: usize,
    pub lambda_min: f64,
    pub w_init: Option<Mat>,
    pub verbose: bool,
}

impl Default for PicardOpts {
    /// Reference-package defaults (`ortho=True`, `max_iter=500`, `m=7`).
    fn default() -> Self {
        PicardOpts { ortho: true, extended: None, n_components: None, whiten: true, centering: true,
            max_iter: 500, tol: 1e-7, m: 7, ls_tries: 10, lambda_min: 0.01, w_init: None, verbose: false }
    }
}

impl PicardOpts {
    /// Parameters used by eegprep `eeg_picard` (standard Picard, identity start, 512 iters, m=10).
    pub fn eegprep() -> Self {
        PicardOpts { ortho: false, m: 10, max_iter: 512, w_init: None, ..Default::default() }
    }
}

#[derive(Debug)]
pub struct PicardResult {
    /// Whitening matrix `K` (n_components x n_features), `None` if `whiten=false`.
    pub k: Option<Mat>,
    /// Unmixing matrix `W` (n_components x n_components) such that `Y = W K (X - mean)`.
    pub w: Mat,
    pub y: Mat,
    pub x_mean: Vec<f64>,
    pub n_iter: usize,
    pub converged: bool,
    pub gradient_norm: f64,
}

fn logcosh_like(y: f64) -> f64 {
    let a = y.abs();
    a + (-2.0 * a).exp().ln_1p()
}

fn loss(y: &Mat, w: &Mat, signs: &[f64], ortho: bool, extended: bool) -> f64 {
    let t = y.ncols() as f64;
    let mut l = if ortho { 0.0 } else { -w.clone().lu().determinant().abs().ln() };
    // slogdet uses log|det|; LU determinant of well-conditioned W is fine for these sizes
    for i in 0..y.nrows() {
        let mut s = 0.0;
        let mut s2 = 0.0;
        for j in 0..y.ncols() {
            let v = y[(i, j)];
            s += logcosh_like(v);
            s2 += v * v;
        }
        l += signs[i] * s / t;
        if extended && !ortho {
            l += 0.5 * s2 / t;
        }
    }
    l
}

/// Scaling-and-squaring Taylor matrix exponential (used for the antisymmetric Picard-O steps).
pub fn expm(a: &Mat) -> Mat {
    let n = a.nrows();
    let nrm = a.iter().fold(0.0f64, |m, v| m.max(v.abs())) * n as f64;
    let s = if nrm > 0.5 { (nrm / 0.5).log2().ceil().max(0.0) as i32 } else { 0 };
    let a2 = a / 2f64.powi(s);
    let mut term = eye(n);
    let mut sum = eye(n);
    for k in 1..=24 {
        term = &term * &a2 / k as f64;
        sum += &term;
    }
    for _ in 0..s {
        sum = &sum * &sum;
    }
    sum
}

fn regularize_hessian(h: &mut Mat, h_off: &[f64], lambda_min: f64) {
    let n = h.nrows();
    let hc = h.clone();
    for i in 0..n {
        for j in 0..n {
            if i == j {
                continue;
            }
            let discr = ((hc[(i, j)] - hc[(j, i)]).powi(2) + 4.0 * h_off[i] * h_off[j]).sqrt();
            let ev = 0.5 * (hc[(i, j)] + hc[(j, i)] - discr);
            if ev < lambda_min {
                h[(i, j)] += lambda_min - ev;
            }
        }
    }
}

fn solve_hessian(h: &Mat, h_off: &[f64], g: &Mat) -> Mat {
    let n = h.nrows();
    Mat::from_fn(n, n, |i, j| {
        let det = h[(i, j)] * h[(j, i)] - h_off[i] * h_off[j];
        (h[(j, i)] * g[(i, j)] - h_off[i] * g[(j, i)]) / det
    })
}

fn dot_sum(a: &Mat, b: &Mat) -> f64 {
    a.iter().zip(b.iter()).map(|(x, y)| x * y).sum()
}

fn l_bfgs_direction(g: &Mat, h: &Mat, h_off: &[f64], s_list: &[Mat], y_list: &[Mat], r_list: &[f64], ortho: bool) -> Mat {
    let mut q = g.clone();
    let mut a_list = Vec::new();
    for k in (0..s_list.len()).rev() {
        let alpha = r_list[k] * dot_sum(&s_list[k], &q);
        a_list.push(alpha);
        q -= &y_list[k] * alpha;
    }
    let mut z = if ortho {
        let z0 = q.component_div(h);
        (&z0 - z0.transpose()) * 0.5
    } else {
        solve_hessian(h, h_off, &q)
    };
    for k in 0..s_list.len() {
        let alpha = a_list[s_list.len() - 1 - k];
        let beta = r_list[k] * dot_sum(&y_list[k], &z);
        z += &s_list[k] * (alpha - beta);
    }
    -z
}

/// Returns (converged, Y_new, W_new, new_loss, alpha*direction)
fn line_search(y: &Mat, w: &Mat, direction: &Mat, signs: &[f64], current_loss: Option<f64>, ls_tries: usize,
               verbose: bool, ortho: bool, extended: bool) -> (bool, Mat, Mat, f64, Mat) {
    let n = w.nrows();
    let mut alpha = 1.0;
    let cl = current_loss.unwrap_or_else(|| loss(y, w, signs, ortho, extended));
    let mut last = (y.clone(), w.clone(), f64::NAN, direction.clone());
    for _ in 0..ls_tries {
        let transform = if ortho { expm(&(direction * alpha)) } else { eye(n) + direction * alpha };
        let y_new = &transform * y;
        let w_new = &transform * w;
        let nl = loss(&y_new, &w_new, signs, ortho, extended);
        if nl.is_finite() && nl < cl {
            return (true, y_new, w_new, nl, direction * alpha);
        }
        last = (y_new, w_new, nl, direction * alpha);
        alpha /= 2.0;
    }
    if verbose {
        println!("line search failed, falling back to gradient");
    }
    (false, last.0, last.1, last.2, last.3)
}

pub struct Core {
    pub y: Mat,
    pub w: Mat,
    pub converged: bool,
    pub gradient_norm: f64,
    pub n_iterations: usize,
}

pub fn core_picard(x: &Mat, ortho: bool, extended: bool, m: usize, max_iter: usize, tol: f64,
                   lambda_min: f64, ls_tries: usize, verbose: bool, covariance: Option<&Mat>) -> Core {
    let (n, t) = (x.nrows(), x.ncols() as f64);
    let mut w = eye(n);
    let mut y = x.clone();
    let mut s_list: Vec<Mat> = vec![];
    let mut y_list: Vec<Mat> = vec![];
    let mut r_list: Vec<f64> = vec![];
    let mut signs = vec![1.0; n];
    let mut old_signs = signs.clone();
    let mut current_loss = Some(loss(&y, &w, &signs, ortho, extended));
    let mut requested = false;
    let mut sign_change = false;
    let mut gradient_norm = 1.0;
    let mut c = covariance.cloned();
    if extended && c.is_none() {
        c = Some(x * x.transpose() / t);
    }
    let mut direction = Mat::zeros(n, n);
    let mut g_old = Mat::zeros(n, n);
    let mut n_done = 0;
    for it in 0..max_iter {
        n_done = it;
        let psi_y = y.map(|v| v.tanh());
        let mut psid_y = psi_y.map(|p| 1.0 - p * p);
        let mut g = &psi_y * y.transpose() / t; // inner(psiY, Y)/T
        let y_square = y.map(|v| v * v);
        if extended {
            let cc = c.as_ref().unwrap();
            let mut k = vec![0.0; n];
            for i in 0..n {
                let mean_psid: f64 = psid_y.row(i).sum() / t;
                k[i] = mean_psid * cc[(i, i)] - g[(i, i)];
                signs[i] = if k[i] > 0.0 { 1.0 } else if k[i] < 0.0 { -1.0 } else { 0.0 };
            }
            if it > 0 {
                sign_change = signs.iter().zip(old_signs.iter()).any(|(a, b)| a != b);
            }
            old_signs = signs.clone();
            for i in 0..n {
                for j in 0..n {
                    g[(i, j)] *= signs[i];
                }
                for j in 0..psid_y.ncols() {
                    psid_y[(i, j)] *= signs[i];
                }
            }
            if !ortho {
                g += cc;
                psid_y.iter_mut().for_each(|v| *v += 1.0);
            }
        }
        drop(psi_y);
        let h_off: Vec<f64> = if ortho { (0..n).map(|i| g[(i, i)]).collect() } else { vec![1.0; n] };
        let mut h;
        if ortho {
            let pm: Vec<f64> = (0..n).map(|i| psid_y.row(i).sum() / t).collect();
            h = Mat::from_fn(n, n, |i, j| 0.5 * (pm[i] + pm[j] - h_off[i] - h_off[j]));
            h.iter_mut().for_each(|v| if *v < lambda_min { *v = lambda_min });
        } else {
            h = &psid_y * y_square.transpose() / t;
            regularize_hessian(&mut h, &h_off, lambda_min);
        }
        if ortho {
            g = (&g - g.transpose()) * 0.5;
        } else {
            g -= eye(n);
        }
        gradient_norm = g.iter().fold(0.0f64, |m, v| m.max(v.abs()));
        if gradient_norm < tol {
            requested = true;
            break;
        }
        if it > 0 {
            s_list.push(direction.clone());
            let yy = &g - &g_old;
            r_list.push(1.0 / dot_sum(&direction, &yy));
            y_list.push(yy);
            if s_list.len() > m {
                s_list.remove(0);
                y_list.remove(0);
                r_list.remove(0);
            }
        }
        g_old = g.clone();
        if extended && sign_change {
            current_loss = None;
            s_list.clear();
            y_list.clear();
            r_list.clear();
        }
        direction = l_bfgs_direction(&g, &h, &h_off, &s_list, &y_list, &r_list, ortho);
        let (conv, ny, nw, nl, nd) = line_search(&y, &w, &direction, &signs, current_loss, ls_tries, verbose, ortho, extended);
        let (ny, nw, nl, nd) = if !conv {
            let d2 = -&g;
            s_list.clear();
            y_list.clear();
            r_list.clear();
            let (_, ny, nw, nl, nd) = line_search(&y, &w, &d2, &signs, current_loss, 10, false, ortho, extended);
            (ny, nw, nl, nd)
        } else {
            (ny, nw, nl, nd)
        };
        direction = nd;
        y = ny;
        w = nw;
        if let Some(cov) = covariance {
            c = Some(&w * cov * w.transpose());
        }
        current_loss = Some(nl);
        if verbose {
            println!("iteration {}, gradient norm = {:.4e}, loss = {:.4e}", it + 1, gradient_norm, nl);
        }
    }
    Core { y, w, converged: requested, gradient_norm, n_iterations: n_done }
}

/// `picard(X, ...)` with the tanh density. `x` is features x samples.
pub fn picard(x: &Mat, o: &PicardOpts) -> Result<PicardResult, String> {
    let (n, p) = (x.nrows(), x.ncols());
    let extended = o.extended.unwrap_or(o.ortho);
    let nc = if !o.whiten { n } else { o.n_components.unwrap_or(n.min(p)) };
    let mut x1 = x.clone();
    let mut x_mean = vec![0.0; n];
    if o.centering {
        let mu = row_means(&x1);
        for i in 0..n {
            x_mean[i] = mu[i];
            for j in 0..p {
                x1[(i, j)] -= mu[i];
            }
        }
    }
    let (k, cov) = if o.whiten {
        // K = (u/d).T[:nc] * sqrt(p), with u,d from the SVD of X1 -> eigen-decomposition of X1 X1'
        let c = &x1 * x1.transpose();
        let (vals, vecs) = sym_eig_sorted_asc(&c); // ascending
        let mut k = Mat::zeros(nc, n);
        for r in 0..nc {
            let idx = n - 1 - r; // descending
            let d = vals[idx].max(0.0).sqrt();
            for cidx in 0..n {
                k[(r, cidx)] = vecs[(cidx, idx)] / d * (p as f64).sqrt();
            }
            // fixed-sign convention: largest-|.| entry positive
            let mut jmax = 0;
            for cidx in 0..n {
                if k[(r, cidx)].abs() > k[(r, jmax)].abs() {
                    jmax = cidx;
                }
            }
            if k[(r, jmax)] < 0.0 {
                for cidx in 0..n {
                    k[(r, cidx)] = -k[(r, cidx)];
                }
            }
        }
        x1 = &k * &x1;
        (Some(k), Some(eye(nc)))
    } else {
        (None, None)
    };
    let w_init = match &o.w_init {
        Some(w) => {
            if w.nrows() != nc || w.ncols() != nc {
                return Err(format!("w_init has invalid shape -- should be ({nc}, {nc})"));
            }
            w.clone()
        }
        None => return Err("w_init is required in this port (the reference draws it from a RandomState); pass identity as eegprep does".into()),
    };
    x1 = &w_init * &x1;
    let cov_ref = if extended { cov.as_ref() } else { None };
    let core = core_picard(&x1, o.ortho, extended, o.m, o.max_iter, o.tol, o.lambda_min, o.ls_tries, o.verbose, cov_ref);
    let w = &core.w * &w_init;
    Ok(PicardResult { k, w, y: core.y, x_mean, n_iter: core.n_iterations, converged: core.converged, gradient_norm: core.gradient_norm })
}

/// eegprep `eeg_picard` / EEGLAB picard path of `pop_runica`: `icaweights = W*K`, `icasphere = I`,
/// `icawinv = pinv(icaweights)`.
pub fn pop_picard(data: &Mat, chanind: Option<&[usize]>, o: &PicardOpts) -> Result<IcaResult, String> {
    let chanind: Vec<usize> = chanind.map(|c| c.to_vec()).unwrap_or_else(|| (0..data.nrows()).collect());
    let nch = chanind.len();
    let mut tmp = Mat::zeros(nch, data.ncols());
    for (k, &c) in chanind.iter().enumerate() {
        tmp.set_row(k, &data.row(c));
    }
    let mut oo = o.clone();
    if oo.w_init.is_none() {
        oo.w_init = Some(eye(oo.n_components.unwrap_or(nch)));
    }
    let r = picard(&tmp, &oo)?;
    let weights = &r.w * r.k.as_ref().ok_or("whitening required")?;
    let sphere = eye(nch);
    let winv0 = pinv(&weights);
    let (weights, winv) = scale_rms(&weights, &sphere, &winv0); // eeg_checkset RMS scaling
    Ok(IcaResult { icaweights: weights, icasphere: sphere, icawinv: winv, icachansind: chanind,
        rank: nch, used_pca: oo.n_components.map_or(false, |c| c < nch), laststep: r.n_iter, final_lrate: 0.0 })
}
