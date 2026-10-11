//! Port of MATLAB Signal Processing Toolbox `yulewalk` (+ `polystab`, `filter`) — used by ASR for the spectral
//! shaping IIR filter designed in `asr_calibrate`.

use nalgebra::{Complex, DMatrix, DVector};
use rustfft::FftPlanner;

type C64 = Complex<f64>;

/// MATLAB `filter(b, a, x, zi)` (direct form II transposed). Returns `(y, zf)`; `zi`/`zf` have `max(len(a),len(b))-1` entries.
pub fn filter(b: &[f64], a: &[f64], x: &[f64], zi: Option<&[f64]>) -> (Vec<f64>, Vec<f64>) {
    let n = a.len().max(b.len());
    let a0 = a[0];
    let mut bb = vec![0.0; n];
    let mut aa = vec![0.0; n];
    for i in 0..b.len() {
        bb[i] = b[i] / a0;
    }
    for i in 0..a.len() {
        aa[i] = a[i] / a0;
    }
    let mut z = vec![0.0; n.saturating_sub(1)];
    if let Some(zi) = zi {
        z.copy_from_slice(&zi[..n - 1]);
    }
    let mut y = Vec::with_capacity(x.len());
    for &xv in x {
        let yv = if n > 1 { bb[0] * xv + z[0] } else { bb[0] * xv };
        for i in 0..n.saturating_sub(2) {
            z[i] = z[i + 1] + bb[i + 1] * xv - aa[i + 1] * yv;
        }
        if n > 1 {
            z[n - 2] = bb[n - 1] * xv - aa[n - 1] * yv;
        }
        y.push(yv);
    }
    (y, z)
}

fn ls_solve(a: &DMatrix<f64>, rhs: &DVector<f64>) -> DVector<f64> {
    // least-squares / minimum-norm solution (MATLAB mldivide for the full-rank overdetermined systems used here)
    let svd = a.clone().svd(true, true);
    svd.solve(rhs, 1e-14).expect("svd solve")
}

/// `[1, Rhs/Rm']`
fn denf(r: &[f64], na: usize) -> Vec<f64> {
    let nr = r.len();
    // Rm = toeplitz(R(na+1:nr-1), R(na+1:-1:2))  (1-based) ; rows nr-1-na, cols na
    let col: Vec<f64> = (na + 1..=nr - 1).map(|i| r[i - 1]).collect();
    let row: Vec<f64> = (2..=na + 1).rev().map(|i| r[i - 1]).collect();
    let rows = col.len();
    let rm = DMatrix::from_fn(rows, na, |i, j| if i >= j { col[i - j] } else { row[j - i] });
    let rhs: Vec<f64> = (na + 2..=nr).map(|i| -r[i - 1]).collect();
    // x * Rm' = rhs  <=>  Rm * x' = rhs'
    let x = ls_solve(&rm, &DVector::from_vec(rhs));
    let mut a = vec![1.0];
    a.extend(x.iter());
    a
}

/// `b = h / toeplitz(impr, [1 zeros(1,nb)])'`
fn numf(h: &[f64], a: &[f64], nb: usize) -> Vec<f64> {
    let nh = h.len();
    let mut imp = vec![0.0; nh];
    imp[0] = 1.0;
    let (impr, _) = filter(&[1.0], a, &imp, None);
    let t = DMatrix::from_fn(nh, nb + 1, |i, j| if i >= j { impr[i - j] } else { 0.0 });
    ls_solve(&t, &DVector::from_vec(h.to_vec())).iter().cloned().collect()
}

/// `poly(roots)` for complex roots, real part.
fn poly_from_roots(v: &[C64]) -> Vec<C64> {
    let mut p = vec![C64::new(1.0, 0.0)];
    for r in v {
        let mut q = vec![C64::new(0.0, 0.0); p.len() + 1];
        for (i, c) in p.iter().enumerate() {
            q[i] += *c;
            q[i + 1] -= *c * *r;
        }
        p = q;
    }
    p
}

/// MATLAB `roots`.
fn roots(a: &[f64]) -> Vec<C64> {
    // strip leading/trailing zeros
    let first = a.iter().position(|&v| v != 0.0);
    let last = a.iter().rposition(|&v| v != 0.0);
    let (f, l) = match (first, last) {
        (Some(f), Some(l)) => (f, l),
        _ => return vec![],
    };
    let nz_trailing = a.len() - 1 - l;
    let c = &a[f..=l];
    let n = c.len() - 1;
    let mut out = vec![];
    if n >= 1 {
        let comp = DMatrix::from_fn(n, n, |i, j| if i == 0 { -c[j + 1] / c[0] } else if i == j + 1 { 1.0 } else { 0.0 });
        out.extend(comp.complex_eigenvalues().iter().cloned());
    }
    out.extend(std::iter::repeat(C64::new(0.0, 0.0)).take(nz_trailing));
    out
}

/// MATLAB `polystab`: reflect roots outside the unit circle.
pub fn polystab(a: &[f64]) -> Vec<f64> {
    if a.len() <= 1 {
        return a.to_vec();
    }
    let mut v = roots(a);
    for r in v.iter_mut() {
        if *r != C64::new(0.0, 0.0) && r.norm() > 1.0 {
            // vs = 1 -> 1/conj(v)
            *r = C64::new(1.0, 0.0) / r.conj();
        }
    }
    let lead = a.iter().cloned().find(|&x| x != 0.0).unwrap();
    poly_from_roots(&v).iter().map(|c| c.re * lead).collect()
}

/// `[B,A] = yulewalk(na, ff, aa)` with MATLAB's defaults `npt = 512`, `lap = fix(npt/25)`.
pub fn yulewalk(na: usize, ff: &[f64], aa: &[f64]) -> Result<(Vec<f64>, Vec<f64>), String> {
    let npt0 = 512usize;
    let lap = (npt0 / 25) as f64;
    let nbrk = ff.len();
    if aa.len() != nbrk {
        return Err("yulewalk: F and M must have the same length".into());
    }
    if ff[0].abs() > f64::EPSILON || (ff[nbrk - 1] - 1.0).abs() > f64::EPSILON {
        return Err("yulewalk: frequency vector must start at 0 and end at 1".into());
    }
    let npt = (npt0 + 1) as f64;
    let mut ht = vec![0.0f64; npt0 + 1];
    ht[0] = aa[0];
    let mut nb = 1.0f64;
    for i in 0..nbrk - 1 {
        let df = ff[i + 1] - ff[i];
        if df < 0.0 {
            return Err("yulewalk: frequencies must be monotonic".into());
        }
        let ne;
        if df == 0.0 {
            nb -= lap / 2.0;
            ne = nb + lap;
        } else {
            ne = (ff[i + 1] * npt).trunc();
        }
        if nb < 0.0 || ne > npt {
            return Err("yulewalk: signal error".into());
        }
        let (nbi, nei) = (nb as usize, ne as usize);
        for j in nbi..=nei {
            let inc = if nei == nbi { 0.0 } else { (j - nbi) as f64 / (nei - nbi) as f64 };
            ht[j - 1] = inc * aa[i + 1] + (1.0 - inc) * aa[i];
        }
        nb = ne + 1.0;
    }
    let mut full = ht.clone();
    for k in (2..=npt0).rev() {
        // Ht(npt-1:-1:2)
        full.push(ht[k - 1]);
    }
    let n = full.len();
    let n2 = (n + 1) / 2;
    let nr = 4 * na;
    let mut planner = FftPlanner::<f64>::new();
    let ifft = planner.plan_fft_inverse(n);
    let fft = planner.plan_fft_forward(n);
    // R = real(ifft(Ht.*Ht))
    let mut buf: Vec<C64> = full.iter().map(|&h| C64::new(h * h, 0.0)).collect();
    ifft.process(&mut buf);
    let mut r: Vec<f64> = buf.iter().take(nr).map(|c| c.re / n as f64).collect();
    for (t, v) in r.iter_mut().enumerate() {
        *v *= 0.54 + 0.46 * (std::f64::consts::PI * t as f64 / (nr as f64 - 1.0)).cos();
    }
    let mut rwin = vec![0.0; n];
    rwin[0] = 0.5;
    for k in 1..n2 {
        rwin[k] = 1.0;
    }
    let a = polystab(&denf(&r, na));
    let mut h0 = r.clone();
    h0[0] = r[0] / 2.0;
    let qh = numf(&h0, &a, na);
    // Ss = 2*real(freqz(Qh, A, n, 'whole'))
    let mut qb: Vec<C64> = (0..n).map(|k| if k < qh.len() { C64::new(qh[k], 0.0) } else { C64::new(0.0, 0.0) }).collect();
    let mut ab: Vec<C64> = (0..n).map(|k| if k < a.len() { C64::new(a[k], 0.0) } else { C64::new(0.0, 0.0) }).collect();
    fft.process(&mut qb);
    fft.process(&mut ab);
    let ss: Vec<f64> = qb.iter().zip(ab.iter()).map(|(q, a)| 2.0 * (q / a).re).collect();
    // hh = ifft(exp(fft(Rwindow.*ifft(log(Ss)))))
    let mut x: Vec<C64> = ss.iter().map(|&s| C64::new(s.ln(), 0.0)).collect();
    ifft.process(&mut x);
    for v in x.iter_mut() {
        *v /= n as f64;
    }
    for (v, w) in x.iter_mut().zip(rwin.iter()) {
        *v *= *w;
    }
    fft.process(&mut x);
    let mut y: Vec<C64> = x.iter().map(|c| c.exp()).collect();
    ifft.process(&mut y);
    let hh: Vec<f64> = y.iter().take(nr).map(|c| c.re / n as f64).collect(); // real part of the (complex) LS solution
    let b = numf(&hh, &a, na);
    Ok((b, a))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn filter_matches_manual() {
        let (y, _) = filter(&[1.0, 1.0], &[1.0, -0.5], &[1.0, 0.0, 0.0], None);
        assert!((y[0] - 1.0).abs() < 1e-15 && (y[1] - 1.5).abs() < 1e-15 && (y[2] - 0.75).abs() < 1e-15);
    }
}
