//! Special functions needed by the ASR distribution fit (MATLAB `gamma`, `gammaincinv`).

/// Natural log of the gamma function (Lanczos, g = 7, n = 9; ~1e-15 relative accuracy for x > 0).
pub fn lgamma(x: f64) -> f64 {
    const G: f64 = 7.0;
    const C: [f64; 9] = [
        0.999_999_999_999_809_9,
        676.520_368_121_885_1,
        -1_259.139_216_722_402_8,
        771.323_428_777_653_1,
        -176.615_029_162_140_6,
        12.507_343_278_686_905,
        -0.138_571_095_265_720_12,
        9.984_369_578_019_572e-6,
        1.505_632_735_149_311_6e-7,
    ];
    if x < 0.5 {
        // reflection
        let pi = std::f64::consts::PI;
        return (pi / (pi * x).sin().abs()).ln() - lgamma(1.0 - x);
    }
    let x = x - 1.0;
    let mut a = C[0];
    let t = x + G + 0.5;
    for (i, c) in C.iter().enumerate().skip(1) {
        a += c / (x + i as f64);
    }
    0.5 * (2.0 * std::f64::consts::PI).ln() + (x + 0.5) * t.ln() - t + a.ln()
}

pub fn gamma(x: f64) -> f64 {
    lgamma(x).exp()
}

/// Regularised lower incomplete gamma `P(a, x)` (MATLAB `gammainc(x, a)`).
pub fn gammainc_lower(x: f64, a: f64) -> f64 {
    if x <= 0.0 {
        return 0.0;
    }
    if x < a + 1.0 {
        // series
        let mut ap = a;
        let mut sum = 1.0 / a;
        let mut del = sum;
        for _ in 0..1000 {
            ap += 1.0;
            del *= x / ap;
            sum += del;
            if del.abs() < sum.abs() * 1e-17 {
                break;
            }
        }
        sum * (-x + a * x.ln() - lgamma(a)).exp()
    } else {
        // continued fraction for Q (modified Lentz)
        let tiny = 1e-300;
        let mut b = x + 1.0 - a;
        let mut c = 1.0 / tiny;
        let mut d = 1.0 / b;
        let mut h = d;
        for i in 1..1000 {
            let an = -(i as f64) * (i as f64 - a);
            b += 2.0;
            d = an * d + b;
            if d.abs() < tiny {
                d = tiny;
            }
            c = b + an / c;
            if c.abs() < tiny {
                c = tiny;
            }
            d = 1.0 / d;
            let del = d * c;
            h *= del;
            if (del - 1.0).abs() < 1e-16 {
                break;
            }
        }
        1.0 - (-x + a * x.ln() - lgamma(a)).exp() * h
    }
}

/// `gammaincinv(y, a)`: the `x` with `P(a, x) = y` (bracketing + Newton polish).
pub fn gammaincinv(y: f64, a: f64) -> f64 {
    if y <= 0.0 {
        return 0.0;
    }
    if y >= 1.0 {
        return f64::INFINITY;
    }
    // bracket
    let mut lo = 0.0f64;
    let mut hi = a.max(1.0);
    while gammainc_lower(hi, a) < y {
        lo = hi;
        hi *= 2.0;
        if hi > 1e300 {
            return f64::INFINITY;
        }
    }
    let mut x = 0.5 * (lo + hi);
    for _ in 0..200 {
        let f = gammainc_lower(x, a) - y;
        if f > 0.0 {
            hi = x;
        } else {
            lo = x;
        }
        // Newton step with the exact derivative x^(a-1) e^-x / Gamma(a)
        let dens = ((a - 1.0) * x.ln() - x - lgamma(a)).exp();
        let mut xn = x - f / dens;
        if !(xn > lo && xn < hi) || !xn.is_finite() {
            xn = 0.5 * (lo + hi);
        }
        if (xn - x).abs() <= 1e-16 * xn.abs().max(1e-300) {
            x = xn;
            break;
        }
        x = xn;
    }
    x
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gamma_values() {
        assert!((gamma(0.5) - 1.772_453_850_905_516).abs() < 1e-13);
        assert!((gamma(5.0) - 24.0).abs() < 1e-12);
        assert!((gamma(1.0 / 3.0) - 2.678_938_534_707_747_6).abs() < 1e-13);
    }
    #[test]
    fn inc_roundtrip() {
        for &a in &[0.3, 1.0, 2.5, 10.0] {
            for &y in &[0.01, 0.2, 0.6, 0.956] {
                let x = gammaincinv(y, a);
                assert!((gammainc_lower(x, a) - y).abs() < 1e-12, "a={a} y={y}");
            }
        }
    }
}
