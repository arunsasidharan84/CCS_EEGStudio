//! Small dense linear-algebra helpers mirroring the MATLAB primitives used by
//! EEGLAB's `runica`/`pop_runica` (`cov`, `sqrtm`, `inv`, `pinv`, `rank`, `eig`).

use nalgebra::{DMatrix, DVector};

pub type Mat = DMatrix<f64>;

/// MATLAB `eps(x)` for a double (spacing of floating point numbers at |x|).
pub fn eps_of(x: f64) -> f64 {
    let x = x.abs();
    if !x.is_finite() {
        return f64::NAN;
    }
    let exp = ((x.to_bits() >> 52) & 0x7ff) as i32;
    if exp == 0 {
        return 4.940_656_458_412_465e-324;
    }
    2f64.powi(exp - 1023 - 52)
}

/// Row means of a (variables x observations) matrix.
pub fn row_means(x: &Mat) -> DVector<f64> {
    let n = x.ncols() as f64;
    DVector::from_fn(x.nrows(), |i, _| x.row(i).sum() / n)
}

/// `cov(x')` : covariance (variables are rows). `ddof` = 1 gives the MATLAB default (N-1), 0 gives `cov(x',1)`.
pub fn cov_rows(x: &Mat, ddof: usize) -> Mat {
    let n = x.ncols();
    let m = row_means(x);
    let mut xc = x.clone();
    for j in 0..n {
        for i in 0..x.nrows() {
            xc[(i, j)] -= m[i];
        }
    }
    let denom = (n - ddof) as f64;
    (&xc * xc.transpose()) / denom
}

/// Symmetric eigen-decomposition returning (eigenvalues ascending, eigenvectors columns).
pub fn sym_eig_sorted_asc(a: &Mat) -> (Vec<f64>, Mat) {
    // symmetrise to remove round-off asymmetry (MATLAB eig on a symmetric input uses the symmetric solver)
    let s = (a + a.transpose()) * 0.5;
    let e = nalgebra::SymmetricEigen::new(s);
    let n = e.eigenvalues.len();
    let mut idx: Vec<usize> = (0..n).collect();
    idx.sort_by(|&i, &j| e.eigenvalues[i].partial_cmp(&e.eigenvalues[j]).unwrap());
    let vals: Vec<f64> = idx.iter().map(|&i| e.eigenvalues[i]).collect();
    let mut vecs = Mat::zeros(n, n);
    for (k, &i) in idx.iter().enumerate() {
        vecs.set_column(k, &e.eigenvectors.column(i));
    }
    (vals, vecs)
}

/// Principal matrix square root of a symmetric positive (semi-)definite matrix.
pub fn sqrtm_spd(a: &Mat) -> Mat {
    let (vals, vecs) = sym_eig_sorted_asc(a);
    let n = vals.len();
    let mut d = Mat::zeros(n, n);
    for i in 0..n {
        d[(i, i)] = vals[i].max(0.0).sqrt();
    }
    &vecs * d * vecs.transpose()
}

pub fn inv(a: &Mat) -> Result<Mat, String> {
    a.clone().try_inverse().ok_or_else(|| "matrix is singular to working precision".to_string())
}

/// Singular values (unsorted) of a general matrix.
pub fn singular_values(a: &Mat) -> Vec<f64> {
    let m = if a.nrows() < a.ncols() { a.transpose() } else { a.clone() };
    let sv = m.svd(false, false).singular_values;
    sv.iter().cloned().collect()
}

/// MATLAB `rank(A)`: tol = max(size(A)) * eps(norm(A)).
pub fn rank(a: &Mat) -> usize {
    let sv = singular_values(a);
    let smax = sv.iter().cloned().fold(0.0, f64::max);
    let tol = a.nrows().max(a.ncols()) as f64 * eps_of(smax);
    sv.iter().filter(|&&s| s > tol).count()
}

/// MATLAB `pinv(A)`.
pub fn pinv(a: &Mat) -> Mat {
    let transposed = a.nrows() < a.ncols();
    let m = if transposed { a.transpose() } else { a.clone() };
    let svd = m.svd(true, true);
    let u = svd.u.unwrap();
    let vt = svd.v_t.unwrap();
    let s = svd.singular_values;
    let smax = s.iter().cloned().fold(0.0, f64::max);
    let tol = a.nrows().max(a.ncols()) as f64 * eps_of(smax);
    // pinv(m) = V * diag(1/s) * U'
    let k = s.len();
    let mut vs = vt.transpose(); // n x k
    for j in 0..k {
        let inv_s = if s[j] > tol { 1.0 / s[j] } else { 0.0 };
        for i in 0..vs.nrows() {
            vs[(i, j)] *= inv_s;
        }
    }
    let p = vs * u.transpose();
    if transposed {
        p.transpose()
    } else {
        p
    }
}

pub fn eye(n: usize) -> Mat {
    Mat::identity(n, n)
}

pub fn eye_rect(r: usize, c: usize) -> Mat {
    let mut m = Mat::zeros(r, c);
    for i in 0..r.min(c) {
        m[(i, i)] = 1.0;
    }
    m
}

/// `eeg_checkset` "Scaling components to RMS microvolt": scales each weight row by the RMS of the matching
/// `icawinv` column and recomputes `icawinv = pinv(W*S)`. Applied (when `pinv(W*S) ~ icawinv`) after ICA.
pub fn scale_rms(weights: &Mat, sphere: &Mat, winv: &Mat) -> (Mat, Mat) {
    let mut w = weights.clone();
    for k in 0..w.nrows() {
        let ms: f64 = winv.column(k).iter().map(|v| v * v).sum::<f64>() / winv.nrows() as f64;
        let s = ms.sqrt();
        for j in 0..w.ncols() {
            w[(k, j)] *= s;
        }
    }
    let nw = pinv(&(&w * sphere));
    (w, nw)
}
