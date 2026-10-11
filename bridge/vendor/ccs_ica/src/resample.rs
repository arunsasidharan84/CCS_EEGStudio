//! MATLAB `resample(x,p,q)` (Signal Processing Toolbox) for the default Kaiser-windowed
//! least-squares anti-aliasing filter (`n = 10`, `beta = 5`), as used by ICLabel's autocorrelation
//! features (`resample(ac', 100, srate)`).

use crate::linalg::Mat;

fn gcd(a: u64, b: u64) -> u64 {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
}

/// MATLAB `rat(x)` style rational approximation with relative tolerance 1e-6 (`rat` default tol = 1e-6*norm(x,1)).
pub fn rat(x: f64) -> (u64, u64) {
    let tol = 1e-6 * x.abs();
    let mut y = x;
    let mut a = y.round();
    let (mut n0, mut d0) = (1.0f64, 0.0f64);
    let (mut n1, mut d1) = (a, 1.0f64);
    let mut frac = y - a;
    while (x - n1 / d1).abs() >= tol && frac != 0.0 {
        y = 1.0 / frac;
        a = y.round();
        frac = y - a;
        let n2 = n1 * a + n0;
        let d2 = d1 * a + d0;
        n0 = n1;
        d0 = d1;
        n1 = n2;
        d1 = d2;
    }
    let (mut n, mut d) = (n1, d1);
    if d < 0.0 {
        n = -n;
        d = -d;
    }
    let (n, d) = (n as u64, d as u64);
    let g = gcd(n, d).max(1);
    (n / g, d / g)
}

fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let q = x * x / 4.0;
    let mut k = 1.0;
    loop {
        term *= q / (k * k);
        sum += term;
        if term < sum * 1e-17 {
            break;
        }
        k += 1.0;
    }
    sum
}

/// Kaiser window of length `l` (MATLAB `kaiser(l,beta)`), symmetric.
fn kaiser(l: usize, beta: f64) -> Vec<f64> {
    if l == 1 {
        return vec![1.0];
    }
    let m = (l - 1) as f64;
    let i0b = bessel_i0(beta);
    (0..l)
        .map(|n| {
            let r = 2.0 * n as f64 / m - 1.0;
            bessel_i0(beta * (1.0 - r * r).max(0.0).sqrt()) / i0b
        })
        .collect()
}

/// The FIR filter designed by MATLAB's resample: `firls(L-1,[0 1/pqmax 1/pqmax 1],[1 1 0 0]) .* kaiser(L,5)`,
/// scaled to `p*h/sum(h)`.  The two-band least-squares problem covers [0,1] with unit weights, which reduces
/// to the truncated ideal low-pass (closed form).
pub fn resample_filter(p: u64, q: u64) -> Vec<f64> {
    let pqmax = p.max(q) as usize;
    let n = 10usize;
    let l = 2 * n * pqmax + 1;
    let m = (l - 1) / 2;
    let wc = std::f64::consts::PI / pqmax as f64;
    let mut h = vec![0.0f64; l];
    h[m] = wc / std::f64::consts::PI;
    for k in 1..=m {
        let a = (k as f64 * wc).sin() / (k as f64 * std::f64::consts::PI);
        h[m + k] = a;
        h[m - k] = a;
    }
    let w = kaiser(l, 5.0);
    let mut s = 0.0;
    for i in 0..l {
        h[i] *= w[i];
        s += h[i];
    }
    for v in h.iter_mut() {
        *v = *v * p as f64 / s;
    }
    h
}

/// Resample each column of `x` (`len x ncols`) by `p/q`.
pub fn resample_cols(x: &Mat, p: u64, q: u64) -> Mat {
    let h0 = resample_filter(p, q);
    let l = h0.len();
    let mut lhalf = (l - 1) / 2;
    let nz = (q as usize) - (lhalf % q as usize);
    let nz = nz.min(q as usize); // floor(q - mod(Lhalf,q)) (mod < q so nz in 1..=q)
    let mut h = vec![0.0f64; nz];
    h.extend_from_slice(&h0);
    lhalf += nz;
    let delay = lhalf / q as usize; // floor(ceil(Lhalf)/q)
    let lx = x.nrows();
    let ly = (lx * p as usize + q as usize - 1) / q as usize; // ceil(Lx*p/q)
    let mut nz1 = 0usize;
    while ((lx - 1) * p as usize + h.len() + nz1 + q as usize - 1) / q as usize - delay < ly {
        nz1 += 1;
    }
    h.extend(std::iter::repeat(0.0).take(nz1));
    let lh = h.len();
    let full_len = ((lx - 1) * p as usize + lh + q as usize - 1) / q as usize;
    let mut out = Mat::zeros(ly, x.ncols());
    for c in 0..x.ncols() {
        // y_full[m] = sum_j x[j] * h[m*q - j*p]
        for m_out in 0..ly {
            let m = m_out + delay;
            if m >= full_len {
                break;
            }
            let k = m * q as usize;
            // j range: 0 <= k - j*p < lh  ->  j <= k/p, j > (k-lh)/p
            let jmax = (k / p as usize).min(lx - 1);
            let jmin = if k + 1 > lh { (k + 1 - lh + p as usize - 1) / p as usize } else { 0 };
            let mut acc = 0.0;
            let mut j = jmin;
            while j <= jmax {
                acc += x[(j, c)] * h[k - j * p as usize];
                j += 1;
            }
            out[(m_out, c)] = acc;
        }
    }
    out
}

/// `resample(x, 100, srate)` helper: reduces 100/srate to lowest terms first (MATLAB `rat`).
pub fn resample_to(x: &Mat, target: f64, srate: f64) -> Mat {
    let (p, q) = rat(target / srate);
    resample_cols(x, p, q)
}
