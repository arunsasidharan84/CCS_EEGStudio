//! scipy-compatible Butterworth design (`scipy.signal.butter(..., output='sos')`) and zero-phase `sosfiltfilt`.

use rustfft::num_complex::Complex64 as C;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BType {
    Lowpass(f64),
    Highpass(f64),
    Bandpass(f64, f64),
    Bandstop(f64, f64),
}

pub type Sos = Vec<[f64; 6]>;

fn poly_prod(v: &[C]) -> C {
    v.iter().fold(C::new(1.0, 0.0), |a, b| a * b)
}

/// zpk of the analogue Butterworth prototype transformed and digitised by the bilinear transform at fs.
fn butter_zpk(n: usize, bt: BType, fs: f64) -> (Vec<C>, Vec<C>, f64) {
    let two = 2.0;
    let warp = |f: f64| 4.0 * (std::f64::consts::PI * (f / (fs / 2.0)) / two).tan();
    // prototype (scipy buttap)
    let mut p: Vec<C> = (0..n)
        .map(|i| {
            let m = -(n as f64) + 1.0 + 2.0 * i as f64;
            -(C::new(0.0, std::f64::consts::PI * m / (2.0 * n as f64))).exp()
        })
        .collect();
    let mut z: Vec<C> = vec![];
    let mut k = 1.0f64;
    let degree = |z: &Vec<C>, p: &Vec<C>| p.len() as i32 - z.len() as i32;
    match bt {
        BType::Lowpass(f) => {
            let wo = warp(f);
            let d = degree(&z, &p);
            z = z.iter().map(|v| v * wo).collect();
            p = p.iter().map(|v| v * wo).collect();
            k *= wo.powi(d);
        }
        BType::Highpass(f) => {
            let wo = warp(f);
            let d = degree(&z, &p);
            let zh: Vec<C> = z.iter().map(|v| C::new(wo, 0.0) / v).collect();
            let ph: Vec<C> = p.iter().map(|v| C::new(wo, 0.0) / v).collect();
            let ratio = (poly_prod(&z.iter().map(|v| -v).collect::<Vec<_>>()) / poly_prod(&p.iter().map(|v| -v).collect::<Vec<_>>())).re;
            k *= ratio;
            z = zh;
            z.extend(std::iter::repeat(C::new(0.0, 0.0)).take(d as usize));
            p = ph;
        }
        BType::Bandpass(f1, f2) => {
            let (w1, w2) = (warp(f1), warp(f2));
            let (wo, bw) = ((w1 * w2).sqrt(), w2 - w1);
            let d = degree(&z, &p);
            let zl: Vec<C> = z.iter().map(|v| v * (bw / 2.0)).collect();
            let pl: Vec<C> = p.iter().map(|v| v * (bw / 2.0)).collect();
            let sq = |v: &C| (v * v - wo * wo).sqrt();
            let mut zb: Vec<C> = zl.iter().map(|v| v + sq(v)).collect();
            zb.extend(zl.iter().map(|v| v - sq(v)));
            let mut pb: Vec<C> = pl.iter().map(|v| v + sq(v)).collect();
            pb.extend(pl.iter().map(|v| v - sq(v)));
            zb.extend(std::iter::repeat(C::new(0.0, 0.0)).take(d as usize));
            k *= bw.powi(d);
            z = zb;
            p = pb;
        }
        BType::Bandstop(f1, f2) => {
            let (w1, w2) = (warp(f1), warp(f2));
            let (wo, bw) = ((w1 * w2).sqrt(), w2 - w1);
            let d = degree(&z, &p);
            let ratio = (poly_prod(&z.iter().map(|v| -v).collect::<Vec<_>>()) / poly_prod(&p.iter().map(|v| -v).collect::<Vec<_>>())).re;
            let zh: Vec<C> = z.iter().map(|v| C::new(bw / 2.0, 0.0) / v).collect();
            let ph: Vec<C> = p.iter().map(|v| C::new(bw / 2.0, 0.0) / v).collect();
            let sq = |v: &C| (v * v - wo * wo).sqrt();
            let mut zb: Vec<C> = zh.iter().map(|v| v + sq(v)).collect();
            zb.extend(zh.iter().map(|v| v - sq(v)));
            let mut pb: Vec<C> = ph.iter().map(|v| v + sq(v)).collect();
            pb.extend(ph.iter().map(|v| v - sq(v)));
            for _ in 0..d {
                zb.push(C::new(0.0, wo));
                zb.push(C::new(0.0, -wo));
            }
            k *= ratio;
            z = zb;
            p = pb;
        }
    }
    // bilinear
    let fs2 = 2.0 * 2.0; // scipy designs at fs = 2 -> fs2 = 4
    let d = p.len() as i32 - z.len() as i32;
    let kz = k * (poly_prod(&z.iter().map(|v| C::new(fs2, 0.0) - v).collect::<Vec<_>>()) / poly_prod(&p.iter().map(|v| C::new(fs2, 0.0) - v).collect::<Vec<_>>())).re;
    let mut zz: Vec<C> = z.iter().map(|v| (C::new(fs2, 0.0) + v) / (C::new(fs2, 0.0) - v)).collect();
    let pz: Vec<C> = p.iter().map(|v| (C::new(fs2, 0.0) + v) / (C::new(fs2, 0.0) - v)).collect();
    zz.extend(std::iter::repeat(C::new(-1.0, 0.0)).take(d.max(0) as usize));
    (zz, pz, kz)
}

fn pair_roots(r: &[C]) -> Vec<(C, C)> {
    // conjugate pairs first, then real roots paired up
    let mut cplx: Vec<C> = r.iter().cloned().filter(|v| v.im > 1e-9).collect();
    cplx.sort_by(|a, b| a.re.partial_cmp(&b.re).unwrap());
    let mut out: Vec<(C, C)> = cplx.iter().map(|v| (*v, v.conj())).collect();
    let mut reals: Vec<f64> = r.iter().filter(|v| v.im.abs() <= 1e-9).map(|v| v.re).collect();
    reals.sort_by(|a, b| a.partial_cmp(b).unwrap());
    while reals.len() >= 2 {
        let a = reals.remove(0);
        let b = reals.remove(0);
        out.push((C::new(a, 0.0), C::new(b, 0.0)));
    }
    if let Some(a) = reals.pop() {
        out.push((C::new(a, 0.0), C::new(0.0, 0.0)));
    }
    out
}

/// scipy.signal.butter(order, freqs, btype, fs=fs, output='sos')
pub fn butter_sos(order: usize, bt: BType, fs: f64) -> Sos {
    let (z, p, k) = butter_zpk(order, bt, fs);
    let mut pp = pair_roots(&p);
    let mut zp = pair_roots(&z);
    pp.sort_by(|a, b| b.0.norm().partial_cmp(&a.0.norm()).unwrap()); // most unit-circle-near first
    let mut sos: Sos = vec![];
    for (p1, p2) in pp {
        // nearest zero pair
        let mut best = 0usize;
        let mut bd = f64::INFINITY;
        for (i, (z1, _)) in zp.iter().enumerate() {
            let d = (z1 - p1).norm();
            if d < bd {
                bd = d;
                best = i;
            }
        }
        let (z1, z2) = if zp.is_empty() { (C::new(0.0, 0.0), C::new(0.0, 0.0)) } else { zp.remove(best) };
        sos.push([1.0, -(z1 + z2).re, (z1 * z2).re, 1.0, -(p1 + p2).re, (p1 * p2).re]);
    }
    for v in sos[0].iter_mut().take(3) {
        *v *= k;
    }
    sos
}

fn sosfilt(sos: &Sos, x: &[f64], zi: &[[f64; 2]]) -> Vec<f64> {
    let mut y = x.to_vec();
    for (s, sec) in sos.iter().enumerate() {
        let (mut z0, mut z1) = (zi[s][0], zi[s][1]);
        for v in y.iter_mut() {
            let xi = *v;
            let yo = sec[0] * xi + z0;
            z0 = sec[1] * xi - sec[4] * yo + z1;
            z1 = sec[2] * xi - sec[5] * yo;
            *v = yo;
        }
    }
    y
}

/// scipy.signal.sosfilt_zi
fn sosfilt_zi(sos: &Sos) -> Vec<[f64; 2]> {
    let mut zi = vec![];
    let mut scale = 1.0;
    for s in sos {
        let (b, a) = ([s[0], s[1], s[2]], [s[3], s[4], s[5]]);
        // lfilter_zi: zi = (I - companion(a)^T)^-1 (b[1:] - a[1:] b[0]) for a[0]=1
        let rhs = [b[1] - a[1] * b[0], b[2] - a[2] * b[0]];
        // I - A^T with A = [[-a1, -a2],[1, 0]] => A^T = [[-a1, 1],[-a2, 0]]
        let m = [[1.0 + a[1], -1.0], [a[2], 1.0]];
        let det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        let z0 = (rhs[0] * m[1][1] - m[0][1] * rhs[1]) / det;
        let z1 = (m[0][0] * rhs[1] - m[1][0] * rhs[0]) / det;
        zi.push([scale * z0, scale * z1]);
        scale *= (b[0] + b[1] + b[2]) / (a[0] + a[1] + a[2]);
    }
    zi
}

/// scipy.signal.sosfiltfilt(sos, x) (default odd padding, padlen from the number of sections).
pub fn sosfiltfilt(sos: &Sos, x: &[f64]) -> Result<Vec<f64>, String> {
    let n_sec = sos.len();
    let ntrail = sos.iter().filter(|s| s[2] == 0.0).count().min(sos.iter().filter(|s| s[5] == 0.0).count());
    let padlen = 3 * (2 * n_sec + 1 - ntrail);
    let n = x.len();
    if n <= padlen {
        return Err("sosfiltfilt: signal shorter than the padding".into());
    }
    let mut ext = Vec::with_capacity(n + 2 * padlen);
    for i in (1..=padlen).rev() {
        ext.push(2.0 * x[0] - x[i]);
    }
    ext.extend_from_slice(x);
    for i in 1..=padlen {
        ext.push(2.0 * x[n - 1] - x[n - 1 - i]);
    }
    let zi = sosfilt_zi(sos);
    let scaled = |v: f64| -> Vec<[f64; 2]> { zi.iter().map(|z| [z[0] * v, z[1] * v]).collect() };
    let y = sosfilt(sos, &ext, &scaled(ext[0]));
    let mut yr: Vec<f64> = y.into_iter().rev().collect();
    let y0 = yr[0];
    let z = sosfilt(sos, &yr, &scaled(y0));
    yr = z.into_iter().rev().collect();
    Ok(yr[padlen..padlen + n].to_vec())
}
