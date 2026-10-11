//! ICLabel (Pion-Tonachini, Kreutz-Delgado & Makeig 2019) — port of the EEGLAB ICLabel plugin 1.6
//! (`iclabel.m`, `ICL_feature_extractor.m`, `eeg_rpsd.m`, `eeg_autocorr*.m`, `topoplotFast.m`, `run_ICL.m`) for the
//! default network (`netICL`).  The network itself runs in single precision like MatConvNet.

use crate::linalg::*;
use crate::resample::resample_to;
use rustfft::{num_complex::Complex, FftPlanner};

pub const CLASSES: [&str; 7] = ["Brain", "Muscle", "Eye", "Heart", "Line Noise", "Channel Noise", "Other"];

static NET_BYTES: &[u8] = include_bytes!("../data/netICL.bin");

#[derive(Clone, Debug)]
pub struct ChanLoc {
    pub label: String,
    /// EEGLAB `theta` (degrees, 0 = nose, positive to the right) — `None` when the channel has no location.
    pub theta: Option<f64>,
    /// EEGLAB `radius` (arc length, 0.5 = head rim).
    pub radius: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct Eeg {
    /// `nbchan x (pnts*trials)`, epochs concatenated in time.
    pub data: Mat,
    pub pnts: usize,
    pub trials: usize,
    pub srate: f64,
    pub chanlocs: Vec<ChanLoc>,
    pub icaweights: Mat,
    pub icasphere: Mat,
    pub icawinv: Mat,
    /// 0-based indices of the channels ICA was run on.
    pub icachansind: Vec<usize>,
    /// EEGLAB `EEG.ref` ("common", "average", ...).
    pub reference: String,
}

// ---------------------------------------------------------------------------------------------------------
// pop_reref(EEG, [], 'exclude', setdiff(1:nbchan, icachansind)) restricted to what ICLabel needs
// ---------------------------------------------------------------------------------------------------------

/// Average-reference the data and the ICA mixing matrix over the channels used for ICA (as
/// `ICL_feature_extractor` does when `EEG.ref` is not `average`/`averef`).
pub fn reref_average_ica(eeg: &mut Eeg) {
    let ch = eeg.icachansind.clone();
    let n = ch.len() as f64;
    // data
    for j in 0..eeg.data.ncols() {
        let mut m = 0.0;
        for &c in &ch {
            m += eeg.data[(c, j)];
        }
        m /= n;
        for &c in &ch {
            eeg.data[(c, j)] -= m;
        }
    }
    // mixing matrix: refmatrix * winv  (refmatrix = I - 11'/n)
    let mut w = eeg.icawinv.clone();
    for k in 0..w.ncols() {
        let mut m = 0.0;
        for i in 0..w.nrows() {
            m += w[(i, k)];
        }
        m /= n;
        for i in 0..w.nrows() {
            w[(i, k)] -= m;
        }
    }
    eeg.icaweights = pinv(&w);
    eeg.icasphere = eye(eeg.icaweights.ncols());
    eeg.icawinv = w;
    // pop_reref -> eeg_checkset: components are re-scaled to RMS microvolt (changes the activations used for the PSD)
    let (w_s, wi_s) = scale_rms(&eeg.icaweights, &eeg.icasphere, &eeg.icawinv);
    eeg.icaweights = w_s;
    eeg.icawinv = wi_s;
    eeg.reference = "average".to_string();
}

/// `eeg_getica`: `(icaweights*icasphere) * data(icachansind,:)`.
pub fn get_ica_act(eeg: &Eeg) -> Mat {
    let mut x = Mat::zeros(eeg.icachansind.len(), eeg.data.ncols());
    for (k, &c) in eeg.icachansind.iter().enumerate() {
        x.set_row(k, &eeg.data.row(c));
    }
    (&eeg.icaweights * &eeg.icasphere) * x
}

// ---------------------------------------------------------------------------------------------------------
// topoplotFast(..., 'noplot','on')  -> 32x32 interpolated scalp map (griddata 'v4' biharmonic spline)
// ---------------------------------------------------------------------------------------------------------

/// Returns the 32x32 map (row-major `[r*32 + c]`) exactly as `Zi` of topoplotFast, with outside-head NaN.
pub fn topoplot_fast_grid(values: &[f64], theta_deg: &[f64], radius: &[f64]) -> Vec<f64> {
    let rmax = 0.5;
    let grid_scale = 32usize;
    let n = values.len();
    // plotchans: finite values only
    let keep: Vec<usize> = (0..n).filter(|&i| values[i].is_finite()).collect();
    let th: Vec<f64> = keep.iter().map(|&i| theta_deg[i] * std::f64::consts::PI / 180.0).collect();
    let rd: Vec<f64> = keep.iter().map(|&i| radius[i]).collect();
    let vals: Vec<f64> = keep.iter().map(|&i| values[i]).collect();
    let x: Vec<f64> = th.iter().zip(&rd).map(|(t, r)| r * t.cos()).collect();
    let y: Vec<f64> = th.iter().zip(&rd).map(|(t, r)| r * t.sin()).collect();
    let maxrd = rd.iter().cloned().fold(f64::MIN, f64::max);
    let mut plotrad = (1.0f64).min(maxrd * 1.02);
    plotrad = plotrad.max(0.5);
    let intrad = (1.0f64).min(maxrd * 1.02);
    // intsquare = 'on'
    let intchans: Vec<usize> = (0..x.len()).filter(|&i| x[i] <= intrad && y[i] <= intrad).collect();
    let squeezefac = rmax / plotrad;
    let intx: Vec<f64> = intchans.iter().map(|&i| x[i] * squeezefac).collect();
    let inty: Vec<f64> = intchans.iter().map(|&i| y[i] * squeezefac).collect();
    let intv: Vec<f64> = intchans.iter().map(|&i| vals[i]).collect();

    let xmin = (-rmax).min(intx.iter().cloned().fold(f64::MAX, f64::min));
    let xmax = rmax.max(intx.iter().cloned().fold(f64::MIN, f64::max));
    let ymin = (-rmax).min(inty.iter().cloned().fold(f64::MAX, f64::min));
    let ymax = rmax.max(inty.iter().cloned().fold(f64::MIN, f64::max));
    let linspace = |a: f64, b: f64, m: usize| -> Vec<f64> {
        (0..m).map(|k| if k == m - 1 { b } else { a + (b - a) * k as f64 / (m - 1) as f64 }).collect()
    };
    let xi = linspace(xmin, xmax, grid_scale);
    let yi = linspace(ymin, ymax, grid_scale);

    // griddata(inty, intx, intv, yi_grid, xi_grid, 'v4'): data sites (px,py) = (inty, intx); query (qx,qy) = (yi[c], xi[r])
    let m = intchans.len();
    let g = |d: f64| -> f64 {
        if d == 0.0 {
            0.0
        } else {
            d * d * (d.ln() - 1.0)
        }
    };
    let mut gm = Mat::zeros(m, m);
    for a in 0..m {
        for b in 0..m {
            let d = ((inty[a] - inty[b]).powi(2) + (intx[a] - intx[b]).powi(2)).sqrt();
            gm[(a, b)] = g(d);
        }
    }
    let rhs = nalgebra::DVector::from_vec(intv.clone());
    let w = gm.lu().solve(&rhs).unwrap_or_else(|| nalgebra::DVector::zeros(m));
    let mut zi = vec![f64::NAN; grid_scale * grid_scale];
    for r in 0..grid_scale {
        for c in 0..grid_scale {
            let qx = yi[c];
            let qy = xi[r];
            let mut z = 0.0;
            for a in 0..m {
                let d = ((qx - inty[a]).powi(2) + (qy - intx[a]).powi(2)).sqrt();
                z += g(d) * w[a];
            }
            // mask: sqrt(Xi.^2+Yi.^2) <= rmax  with Xi = yi grid value, Yi = xi grid value
            if (qx * qx + qy * qy).sqrt() <= rmax {
                zi[r * grid_scale + c] = z;
            }
        }
    }
    zi
}

/// 32x32 normalised topography per component (`[comp][r*32+c]`, row-major, r = first MATLAB dimension).
pub fn topo_features(eeg: &Eeg) -> Result<Vec<Vec<f32>>, String> {
    let ncomp = eeg.icawinv.ncols();
    let mut theta = Vec::new();
    let mut radius = Vec::new();
    for &c in &eeg.icachansind {
        let cl = &eeg.chanlocs[c];
        match (cl.theta, cl.radius) {
            (Some(t), Some(r)) => {
                theta.push(t);
                radius.push(r);
            }
            _ => return Err(format!("channel {} has no location (theta/radius) — ICLabel needs channel locations", cl.label)),
        }
    }
    let mut out = Vec::with_capacity(ncomp);
    for k in 0..ncomp {
        let col: Vec<f64> = (0..eeg.icawinv.nrows()).map(|i| eeg.icawinv[(i, k)]).collect();
        let mut zi = topoplot_fast_grid(&col, &theta, &radius);
        for v in zi.iter_mut() {
            if v.is_nan() {
                *v = 0.0;
            }
        }
        let mx = zi.iter().fold(0.0f64, |a, &v| a.max(v.abs()));
        out.push(zi.iter().map(|&v| (v / mx) as f32).collect());
    }
    Ok(out)
}

// ---------------------------------------------------------------------------------------------------------
// eeg_rpsd
// ---------------------------------------------------------------------------------------------------------

fn hamming_win(m: usize) -> Vec<f64> {
    // windows('hamming', m): a - (1-a) cos(2*pi*x), x = (0:m-1)/(m-1) (mirrored half)
    if m == 1 {
        return vec![1.0];
    }
    (0..m).map(|k| 0.54 - 0.46 * (2.0 * std::f64::consts::PI * k as f64 / (m - 1) as f64).cos()).collect()
}

/// Segment starts (0-based) for 50%-overlapping windows: `ceil(0:n/2:cutoff-n)`.
fn segment_starts(n_points: usize, cutoff: usize) -> Vec<usize> {
    let mut v = Vec::new();
    let step = n_points as f64 / 2.0;
    let lim = cutoff as f64 - n_points as f64;
    let mut k = 0.0f64;
    while k * step <= lim + 1e-9 {
        v.push((k * step).ceil() as usize);
        k += 1.0;
    }
    v
}

fn median(v: &mut Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        0.5 * (v[n / 2 - 1] + v[n / 2])
    }
}

/// `eeg_rpsd(EEG, nfreqs)` with 100% of the data. `icaact` is `ncomp x (pnts*trials)`.
pub fn rpsd(icaact: &Mat, pnts: usize, trials: usize, srate: f64, nfreqs_req: usize) -> Mat {
    let nyquist = (srate / 2.0).floor() as usize;
    let nfreqs = if nfreqs_req > nyquist { nyquist } else { nfreqs_req };
    let ncomp = icaact.nrows();
    let n_points = (pnts as f64).min(srate).floor() as usize;
    let window = hamming_win(n_points);
    let cutoff = (pnts / n_points) * n_points;
    let starts = segment_starts(n_points, cutoff);
    let wsum2: f64 = window.iter().map(|w| w * w).sum();
    let mut planner = FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(n_points);
    let mut out = Mat::zeros(ncomp, nfreqs);
    for it in 0..ncomp {
        // power per segment per frequency
        let nseg = starts.len() * trials;
        let mut pw = vec![vec![0.0f64; nseg]; nfreqs];
        let mut s = 0;
        for t in 0..trials {
            for &st in &starts {
                let mut buf: Vec<Complex<f64>> = (0..n_points)
                    .map(|k| Complex::new(icaact[(it, t * pnts + st + k)] * window[k], 0.0))
                    .collect();
                fft.process(&mut buf);
                for f in 0..nfreqs {
                    let c = buf[f + 1];
                    let mut p = (c.re * c.re + c.im * c.im) * 2.0 / (srate * wsum2);
                    if nfreqs == nyquist && f == nfreqs - 1 {
                        p /= 2.0;
                    }
                    pw[f][s] = p;
                }
                s += 1;
            }
        }
        for f in 0..nfreqs {
            let med = median(&mut pw[f]);
            out[(it, f)] = 20.0 * med.log10();
        }
    }
    out
}

/// PSD features as produced by ICL_feature_extractor: `ncomp x 100`, padded, line-noise repaired, max-normalised.
pub fn psd_features(eeg: &Eeg, icaact: &Mat) -> Mat {
    let psd0 = rpsd(icaact, eeg.pnts, eeg.trials, eeg.srate, 100);
    let ncomp = psd0.nrows();
    let nfreq = psd0.ncols();
    let mut psd = Mat::zeros(ncomp, 100);
    for i in 0..ncomp {
        for f in 0..100 {
            psd[(i, f)] = if f < nfreq { psd0[(i, f)] } else { psd0[(i, nfreq - 1)] };
        }
    }
    for &ln in &[50usize, 60usize] {
        // 1-based columns ln-1, ln, ln+1
        let (a, b, c) = (ln - 2, ln - 1, ln);
        for i in 0..ncomp {
            let d1 = psd[(i, a)] - psd[(i, b)];
            let d2 = psd[(i, c)] - psd[(i, b)];
            if d1 > 5.0 && d2 > 5.0 {
                psd[(i, b)] = 0.5 * (psd[(i, a)] + psd[(i, c)]);
            }
        }
    }
    for i in 0..ncomp {
        let mx = psd.row(i).iter().fold(0.0f64, |a, &v| a.max(v.abs()));
        for f in 0..100 {
            psd[(i, f)] /= mx;
        }
    }
    psd
}

// ---------------------------------------------------------------------------------------------------------
// autocorrelation features
// ---------------------------------------------------------------------------------------------------------

fn nextpow2(n: usize) -> usize {
    let mut p = 1;
    while p < n {
        p *= 2;
    }
    p
}

/// Real autocorrelation from the (mean) power spectrum, `ifft` real part.
fn ifft_real(pow: &[f64]) -> Vec<f64> {
    let n = pow.len();
    let mut planner = FftPlanner::<f64>::new();
    let ifft = planner.plan_fft_inverse(n);
    let mut buf: Vec<Complex<f64>> = pow.iter().map(|&p| Complex::new(p, 0.0)).collect();
    ifft.process(&mut buf);
    buf.iter().map(|c| c.re / n as f64).collect()
}

fn fft_pow(x: &[f64], nfft: usize, planner: &mut FftPlanner<f64>) -> Vec<f64> {
    let fft = planner.plan_fft_forward(nfft);
    let mut buf: Vec<Complex<f64>> = (0..nfft).map(|k| Complex::new(if k < x.len() { x[k] } else { 0.0 }, 0.0)).collect();
    fft.process(&mut buf);
    buf.iter().map(|c| c.re * c.re + c.im * c.im).collect()
}

/// Which `eeg_autocorr*` variant ICL_feature_extractor selects.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AutocorrKind {
    Welch,
    Short,
    Epoched,
}

pub fn autocorr_kind(eeg: &Eeg) -> AutocorrKind {
    if eeg.trials == 1 {
        if eeg.pnts as f64 / eeg.srate > 5.0 {
            AutocorrKind::Welch
        } else {
            AutocorrKind::Short
        }
    } else {
        AutocorrKind::Epoched
    }
}

/// Autocorrelation features (`ncomp x 100`).
pub fn autocorr_features(eeg: &Eeg, icaact: &Mat) -> Mat {
    let ncomp = icaact.nrows();
    let srate = eeg.srate.round() as usize; // EEG.srate used as integer lag count
    let pnts = eeg.pnts;
    let kind = autocorr_kind(eeg);
    let mut planner = FftPlanner::<f64>::new();
    // ac: ncomp x (srate+1) before resampling
    let mut ac = Mat::zeros(ncomp, srate + 1);
    for it in 0..ncomp {
        match kind {
            AutocorrKind::Short | AutocorrKind::Epoched => {
                let nfft = nextpow2(2 * pnts - 1);
                let mut acc = vec![0.0f64; nfft];
                for t in 0..eeg.trials {
                    let seg: Vec<f64> = (0..pnts).map(|k| icaact[(it, t * pnts + k)]).collect();
                    let p = fft_pow(&seg, nfft, &mut planner);
                    for k in 0..nfft {
                        acc[k] += p[k];
                    }
                }
                for k in 0..nfft {
                    acc[k] /= eeg.trials as f64;
                }
                let c = ifft_real(&acc);
                let mut row = vec![0.0f64; srate + 1];
                if pnts < srate {
                    for k in 0..pnts {
                        row[k] = c[k];
                    }
                } else {
                    for k in 0..=srate {
                        row[k] = c[k];
                    }
                }
                let c0 = row[0];
                for k in 0..=srate {
                    ac[(it, k)] = row[k] / c0;
                }
            }
            AutocorrKind::Welch => {
                let n_points = pnts.min(srate * 3);
                let nfft = nextpow2(n_points * 2 - 1);
                let cutoff = (pnts / n_points) * n_points;
                let starts = segment_starts(n_points, cutoff);
                let mut acc = vec![0.0f64; nfft];
                for &st in &starts {
                    let seg: Vec<f64> = (0..n_points).map(|k| icaact[(it, st + k)]).collect();
                    let p = fft_pow(&seg, nfft, &mut planner);
                    for k in 0..nfft {
                        acc[k] += p[k];
                    }
                }
                for k in 0..nfft {
                    acc[k] /= starts.len() as f64;
                }
                let c = ifft_real(&acc);
                let c0 = c[0];
                if pnts < srate {
                    for k in 0..pnts.min(srate + 1) {
                        // ac(:,1:pnts) ./ (ac(:,1) * (n_points:-1:1)/n_points)
                        ac[(it, k)] = c[k] / (c0 * (n_points - k) as f64 / n_points as f64);
                    }
                } else {
                    for k in 0..=srate {
                        let norm = if k < srate { (n_points - k) as f64 } else { (1.0f64).max(n_points as f64 - srate as f64) };
                        ac[(it, k)] = c[k] / (c0 * norm / n_points as f64);
                    }
                }
            }
        }
    }
    // resample(ac', 100, srate)' then drop first sample (Welch: columns 2..101)
    let rs = resample_to(&ac.transpose(), 100.0, eeg.srate); // (len x ncomp)
    let mut out = Mat::zeros(ncomp, 100);
    for it in 0..ncomp {
        for k in 0..100 {
            out[(it, k)] = rs[(k + 1, it)];
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------------------
// network
// ---------------------------------------------------------------------------------------------------------

struct Conv {
    w: Vec<f32>, // [out][in][kh][kw]
    b: Vec<f32>,
    out: usize,
    inn: usize,
    kh: usize,
    kw: usize,
}

struct Net {
    layers: Vec<Conv>,
}

fn load_net() -> Net {
    let shapes: [(usize, usize, usize, usize); 10] = [
        (128, 1, 4, 4),
        (256, 128, 4, 4),
        (512, 256, 4, 4),
        (128, 1, 1, 3),
        (256, 128, 1, 3),
        (1, 256, 1, 3),
        (128, 1, 1, 3),
        (256, 128, 1, 3),
        (1, 256, 1, 3),
        (7, 712, 4, 4),
    ];
    let floats: Vec<f32> = NET_BYTES.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect();
    let mut pos = 0;
    let mut layers = Vec::new();
    for &(o, i, kh, kw) in shapes.iter() {
        let nw = o * i * kh * kw;
        let w = floats[pos..pos + nw].to_vec();
        pos += nw;
        let b = floats[pos..pos + o].to_vec();
        pos += o;
        layers.push(Conv { w, b, out: o, inn: i, kh, kw });
    }
    assert_eq!(pos, floats.len());
    Net { layers }
}

/// x: `[c][h][w]` flattened; returns `[out][oh][ow]`.
fn conv2d(x: &[f32], c: usize, h: usize, w: usize, l: &Conv, stride: (usize, usize), pad: (usize, usize)) -> (Vec<f32>, usize, usize) {
    assert_eq!(c, l.inn);
    let oh = (h + 2 * pad.0 - l.kh) / stride.0 + 1;
    let ow = (w + 2 * pad.1 - l.kw) / stride.1 + 1;
    let klen = c * l.kh * l.kw;
    // im2col: [pos][klen]
    let mut col = vec![0.0f32; oh * ow * klen];
    for oy in 0..oh {
        for ox in 0..ow {
            let base = (oy * ow + ox) * klen;
            for ci in 0..c {
                for ky in 0..l.kh {
                    let iy = (oy * stride.0 + ky) as isize - pad.0 as isize;
                    for kx in 0..l.kw {
                        let ix = (ox * stride.1 + kx) as isize - pad.1 as isize;
                        let v = if iy >= 0 && (iy as usize) < h && ix >= 0 && (ix as usize) < w {
                            x[(ci * h + iy as usize) * w + ix as usize]
                        } else {
                            0.0
                        };
                        col[base + (ci * l.kh + ky) * l.kw + kx] = v;
                    }
                }
            }
        }
    }
    let mut out = vec![0.0f32; l.out * oh * ow];
    for o in 0..l.out {
        let wrow = &l.w[o * klen..(o + 1) * klen];
        for p in 0..oh * ow {
            let crow = &col[p * klen..(p + 1) * klen];
            let mut acc = 0.0f32;
            for k in 0..klen {
                acc += wrow[k] * crow[k];
            }
            out[o * oh * ow + p] = acc + l.b[o];
        }
    }
    (out, oh, ow)
}

fn leaky(v: &mut [f32]) {
    for x in v.iter_mut() {
        if *x < 0.0 {
            *x *= 0.2;
        }
    }
}

/// Run one branch (psd/autocorr): input `[100]` -> 3 convs (1x3, pad 1 along width) -> `[100]`.
fn run_1d_branch(net: &Net, first: usize, input: &[f32]) -> Vec<f32> {
    let (mut x, mut h, mut w, mut c) = (input.to_vec(), 1usize, 100usize, 1usize);
    for li in first..first + 3 {
        let (mut y, oh, ow) = conv2d(&x, c, h, w, &net.layers[li], (1, 1), (0, 1));
        leaky(&mut y);
        c = net.layers[li].out;
        h = oh;
        w = ow;
        x = y;
    }
    x // c == 1, 1x100
}

/// Evaluate the ICLabel network on already-extracted features. `topo`: `[comp][32*32]` (row-major, first MATLAB dim = rows),
/// `psd`, `ac`: `[comp][100]` — all already multiplied by the 0.99 scale. Returns `ncomp x 7` probabilities.
pub fn run_network(topo: &[Vec<f32>], psd: &[Vec<f32>], ac: &[Vec<f32>]) -> Mat {
    let net = load_net();
    let ncomp = topo.len();
    let mut out = Mat::zeros(ncomp, 7);
    for k in 0..ncomp {
        let p = run_1d_branch(&net, 3, &psd[k]);
        let a = run_1d_branch(&net, 6, &ac[k]);
        let mut acc = [0.0f64; 7];
        for variant in 0..4 {
            // images = cat(4, img, -img, img(:,end:-1:1), -img(:,end:-1:1))
            let mut img = vec![0.0f32; 32 * 32];
            for r in 0..32 {
                for c in 0..32 {
                    let src = if variant >= 2 { 31 - c } else { c };
                    let v = topo[k][r * 32 + src];
                    img[r * 32 + c] = if variant % 2 == 1 { -v } else { v };
                }
            }
            let (mut x, mut h, mut w, mut c) = (img, 32usize, 32usize, 1usize);
            for li in 0..3 {
                let (mut y, oh, ow) = conv2d(&x, c, h, w, &net.layers[li], (2, 2), (1, 1));
                leaky(&mut y);
                c = net.layers[li].out;
                h = oh;
                w = ow;
                x = y;
            }
            // x: [512][4][4]; concat with psd (100) and autocorr (100) tiled over 4x4
            let mut cat = vec![0.0f32; 712 * 16];
            cat[..512 * 16].copy_from_slice(&x);
            for f in 0..100 {
                for pos in 0..16 {
                    cat[(512 + f) * 16 + pos] = p[f];
                    cat[(612 + f) * 16 + pos] = a[f];
                }
            }
            let (z, _, _) = conv2d(&cat, 712, 4, 4, &net.layers[9], (1, 1), (0, 0));
            // softmax over 7 channels (1x1 spatial)
            let mx = z.iter().cloned().fold(f32::MIN, f32::max);
            let ex: Vec<f32> = z.iter().map(|&v| (v - mx).exp()).collect();
            let s: f32 = ex.iter().sum();
            for i in 0..7 {
                acc[i] += (ex[i] / s) as f64 / 4.0;
            }
        }
        for i in 0..7 {
            out[(k, i)] = acc[i];
        }
    }
    out
}

/// Features exactly as `ICL_feature_extractor(EEG, true)` returns them (already scaled by 0.99).
pub struct IclFeatures {
    pub topo: Vec<Vec<f32>>,
    pub psd: Vec<Vec<f32>>,
    pub autocorr: Vec<Vec<f32>>,
}

pub fn extract_features(eeg_in: &Eeg) -> Result<IclFeatures, String> {
    let mut eeg = eeg_in.clone();
    if eeg.reference != "average" && eeg.reference != "averef" {
        reref_average_ica(&mut eeg);
    }
    let icaact = get_ica_act(&eeg);
    let topo = topo_features(&eeg)?;
    let psd = psd_features(&eeg, &icaact);
    let ac = autocorr_features(&eeg, &icaact);
    let to32 = |m: &Mat| -> Vec<Vec<f32>> {
        (0..m.nrows()).map(|i| (0..m.ncols()).map(|j| (0.99 * (m[(i, j)] as f32 as f64)) as f32).collect()).collect()
    };
    Ok(IclFeatures {
        topo: topo.iter().map(|t| t.iter().map(|&v| (0.99 * v as f64) as f32).collect()).collect(),
        psd: to32(&psd),
        autocorr: to32(&ac),
    })
}

/// `iclabel(EEG, 'default')` — returns `ncomp x 7` class probabilities (Brain, Muscle, Eye, Heart, Line Noise,
/// Channel Noise, Other).
pub fn iclabel(eeg: &Eeg) -> Result<Mat, String> {
    if eeg.srate < 100.0 {
        return Err("ICLabel requires a sampling frequency of at least 100 Hz".into());
    }
    if eeg.icawinv.ncols() == 0 {
        return Err("You must have an ICA decomposition to use ICLabel".into());
    }
    let f = extract_features(eeg)?;
    Ok(run_network(&f.topo, &f.psd, &f.autocorr))
}
