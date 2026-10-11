//! Port of EEGLAB `runica.m` (Infomax / extended-Infomax ICA, Bell & Sejnowski 1995; Lee, Girolami &
//! Sejnowski 1999) as shipped in EEGLAB 2024.2.1 (`functions/sigprocfunc/runica.m`).
//!
//! The training loops follow the MATLAB source statement by statement (including its quirks, e.g. `step =
//! maxsteps` to stop, accumulation of `olddelta` only on annealing, restart with a lower learning rate on
//! weight blow-up, kurtosis-subset resampling through `rand`).  Only the four `biasflag × extended` loop
//! variants are merged into a single loop controlled by flags; spectrogram ICA (`specgram`) is not ported.

use crate::linalg::*;
use crate::rng::Rng;
use nalgebra::DVector;

const MAX_WEIGHT: f64 = 1e8;
const DEFAULT_STOP: f64 = 0.000001;
const DEFAULT_ANNEALDEG: f64 = 60.0;
const DEFAULT_ANNEALSTEP: f64 = 0.90;
const DEFAULT_EXTANNEAL: f64 = 0.98;
const DEFAULT_MAXSTEPS: usize = 512;
const DEFAULT_BLOWUP: f64 = 1_000_000_000.0;
const DEFAULT_BLOWUP_FAC: f64 = 0.8;
const DEFAULT_RESTART_FAC: f64 = 0.9;
const MIN_LRATE: f64 = 0.000001;
const MAX_LRATE: f64 = 0.1;
const MAX_KURTSIZE: usize = 6000;
const SIGNCOUNT_THRESHOLD: usize = 25;
const SIGNCOUNT_STEP: i64 = 2;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Sphering {
    On,
    Off,
    None,
}

#[derive(Clone, Debug)]
pub struct RunicaOpts {
    /// `'lrate'` (None -> `0.00065/log(chans)`).
    pub lrate: Option<f64>,
    /// `'block'` (None -> `ceil(min(5*log(frames), 0.3*frames))`).
    pub block: Option<usize>,
    /// `'maxsteps'`
    pub maxsteps: usize,
    /// `'stop'` / nochange (None -> 1e-6, or 1e-7 for >32 components).
    pub stop: Option<f64>,
    /// `'extended'` value: 0 = off (logistic Infomax), >0 = blocks per kurtosis estimate, <0 = fixed -N sub-Gaussians.
    pub extended: i64,
    /// `'pca'` value (number of principal components to keep, negative = drop).
    pub pca: Option<i64>,
    pub sphering: Sphering,
    /// `'bias'` on/off
    pub bias: bool,
    pub momentum: f64,
    pub anneal_step: Option<f64>,
    pub anneal_deg: Option<f64>,
    /// `'posact'` (positive activations) — only affects returned `weights` sign convention.
    pub posact: bool,
    pub signsbias: f64,
    pub extmomentum: f64,
    /// Starting weights (`'weights'`), `ncomps x chans`.
    pub weights: Option<Mat>,
    pub verbose: bool,
}

impl Default for RunicaOpts {
    fn default() -> Self {
        RunicaOpts {
            lrate: None,
            block: None,
            maxsteps: DEFAULT_MAXSTEPS,
            stop: None,
            extended: 0,
            pca: None,
            sphering: Sphering::On,
            bias: true,
            momentum: 0.0,
            anneal_step: None,
            anneal_deg: None,
            posact: false,
            signsbias: 0.02,
            extmomentum: 0.5,
            weights: None,
            verbose: false,
        }
    }
}

#[derive(Debug)]
pub struct RunicaResult {
    pub weights: Mat,
    pub sphere: Mat,
    pub bias: DVector<f64>,
    pub signs: Vec<f64>,
    pub lrates: Vec<f64>,
    pub changes: Vec<f64>,
    pub laststep: usize,
    pub ncomps: usize,
    /// Permutation applied by runica's own variance sort (0-based).
    pub windex: Vec<usize>,
    pub meanvar: Vec<f64>,
    pub final_lrate: f64,
}

fn sign(x: f64) -> f64 {
    if x > 0.0 {
        1.0
    } else if x < 0.0 {
        -1.0
    } else {
        0.0
    }
}

fn log(v: bool, s: String) {
    if v {
        eprintln!("{}", s);
    }
}

/// Run EEGLAB-compatible `runica` on `data` (`chans x frames`).
pub fn runica(data_in: &Mat, o: &RunicaOpts, rng: &mut dyn Rng) -> Result<RunicaResult, String> {
    let mut data = data_in.clone();
    let (mut chans, frames) = data.shape();
    let urchans = chans;
    let datalength = frames;
    if chans < 2 {
        return Err(format!("runica() - data size ({},{}) too small.", chans, frames));
    }
    let verb = o.verbose;
    if o.posact {
        return Err("runica(): 'posact' is not supported by this port (EEGLAB default is off)".into());
    }

    let default_lrate = 0.00065 / (chans as f64).ln();
    let default_block = ((5.0 * (frames as f64).ln()).min(0.3 * frames as f64)).ceil() as usize;

    let mut ncomps = chans;
    let mut pcaflag = false;
    if let Some(p) = o.pca {
        let mut v = p;
        pcaflag = true;
        if v > chans as i64 || v < -1 {
            return Err(format!("runica(): pca value must be in range [{},{}]", -(chans as i64) + 1, chans));
        }
        if v < 0 {
            v += data.nrows() as i64;
        }
        ncomps = v as usize;
        chans = ncomps;
    }

    let mut lrate = match o.lrate {
        Some(l) => {
            if l > MAX_LRATE || l < 0.0 {
                return Err("runica(): lrate value is out of bounds".into());
            }
            if l == 0.0 {
                default_lrate
            } else {
                l
            }
        }
        None => default_lrate,
    };
    let block = match o.block {
        Some(b) if b != 0 => b,
        _ => default_block,
    };
    let maxsteps = if o.maxsteps == 0 { DEFAULT_MAXSTEPS } else { o.maxsteps };

    // extended-ICA options
    let mut extended = false;
    let mut extblocks: i64 = 1;
    let mut nsub: usize = 1;
    let mut kurtsize = MAX_KURTSIZE;
    if o.extended != 0 {
        extended = true;
        extblocks = o.extended;
        if extblocks < 0 {
            nsub = (-extblocks) as usize;
        } else if kurtsize > frames {
            kurtsize = frames;
        }
    }
    let mut annealstep = o.anneal_step.unwrap_or(0.0);
    if annealstep == 0.0 {
        annealstep = if !extended { DEFAULT_ANNEALSTEP } else { DEFAULT_EXTANNEAL };
    }
    let mut annealdeg = o.anneal_deg.unwrap_or(DEFAULT_ANNEALDEG);
    if annealdeg == 0.0 {
        annealdeg = DEFAULT_ANNEALDEG - o.momentum * 90.0;
        if annealdeg < 0.0 {
            annealdeg = 0.0;
        }
    }
    let nochange = match o.stop {
        Some(s) => s,
        None => {
            if ncomps > 32 {
                1e-7
            } else {
                DEFAULT_STOP
            }
        }
    };

    if ncomps > chans || ncomps < 1 {
        return Err(format!("runica(): number of components must be 1 to {}.", chans));
    }
    if frames < chans {
        return Err(format!("runica(): data length ({}) < data channels ({})!", frames, chans));
    }
    if block < 2 {
        return Err(format!("runica(): block size {} too small!", block));
    }
    if block > frames {
        return Err("runica(): block size exceeds data length!".into());
    }
    if nsub > ncomps {
        return Err(format!("runica(): there can be at most {} sub-Gaussian components!", ncomps));
    }

    let biasflag = o.bias;
    let momentum = o.momentum;

    // ---- remove overall row means
    let rowmeans = row_means(&data);
    for j in 0..frames {
        for i in 0..data.nrows() {
            data[(i, j)] -= rowmeans[i];
        }
    }

    // ---- PCA reduction
    let mut eigenvectors = Mat::zeros(0, 0);
    if pcaflag {
        let pcout = (&data * data.transpose()) / (frames as f64);
        let (_vals, vecs) = sym_eig_sorted_asc(&pcout);
        let n = vecs.ncols();
        // descending order
        let mut ev = Mat::zeros(vecs.nrows(), n);
        for k in 0..n {
            ev.set_column(k, &vecs.column(n - 1 - k));
        }
        let top = ev.columns(0, ncomps).into_owned();
        data = top.transpose() * &data;
        eigenvectors = ev;
    }

    // ---- sphering
    let sphere: Mat;
    let mut weights: Mat;
    let wts_passed = o.weights.is_some();
    match o.sphering {
        Sphering::On => {
            let sph = &inv(&sqrtm_spd(&cov_rows(&data, 1)))? * 2.0;
            weights = if wts_passed { o.weights.clone().unwrap() } else { eye_rect(ncomps, chans) };
            data = &sph * &data;
            sphere = sph;
        }
        Sphering::Off => {
            if !wts_passed {
                let sph = &inv(&sqrtm_spd(&cov_rows(&data, 1)))? * 2.0;
                weights = eye_rect(ncomps, chans) * sph;
            } else {
                weights = o.weights.clone().unwrap();
            }
            sphere = eye(chans);
        }
        Sphering::None => {
            sphere = eye(chans);
            weights = if wts_passed { o.weights.clone().unwrap() } else { eye_rect(ncomps, chans) };
        }
    }

    // ---- initialise training
    let lastt: usize = ((datalength as f64 / block as f64 - 1.0) * block as f64 + 1.0).trunc() as usize;
    let bi = Mat::identity(ncomps, ncomps) * (block as f64);
    let mut delta = DVector::<f64>::zeros(chans * ncomps);
    let mut changes: Vec<f64> = Vec::new();
    let degconst = 180.0 / std::f64::consts::PI;
    let startweights = weights.clone();
    let mut prevweights = startweights.clone();
    let mut oldweights = startweights.clone();
    let mut prevwtchange = Mat::zeros(chans, ncomps);
    let mut lrates = vec![0.0f64; maxsteps];
    let mut bias = DVector::<f64>::zeros(ncomps);
    let init_signs = |n: usize, nsub: usize| -> Vec<f64> {
        let mut s = vec![1.0; n];
        for k in 0..nsub.min(n) {
            s[k] = -1.0;
        }
        s
    };
    let mut signs = init_signs(ncomps, nsub);
    let mut oldsigns = vec![0.0f64; ncomps];
    let mut signcount: usize = 0;
    let urextblocks = extblocks;
    let mut old_kk = vec![0.0f64; ncomps];

    let mut step: usize = 0;
    let mut laststep: usize = 0;
    let mut blockno: i64 = 1;
    let mut wts_blowup = false;
    let mut change = 0.0f64;
    let mut oldchange = 0.0f64;
    let mut angledelta = 0.0f64;
    let mut olddelta = DVector::<f64>::zeros(chans * ncomps);

    let mut xblk = Mat::zeros(chans, block);

    while step < maxsteps {
        let timeperm = rng.randperm(datalength);
        let mut t = 1usize;
        while t <= lastt {
            // gather block of data columns (MATLAB: data(:, timeperm(t:t+block-1)))
            for b in 0..block {
                let col = timeperm[t - 1 + b];
                xblk.set_column(b, &data.column(col));
            }
            let mut u = &weights * &xblk;
            if biasflag {
                for b in 0..block {
                    for i in 0..ncomps {
                        u[(i, b)] += bias[i];
                    }
                }
            }
            if !extended {
                // y = 1./(1+exp(-u)); weights = weights + lrate*(BI+(1-2*y)*u')*weights
                let y2 = u.map(|v| 1.0 - 2.0 * (1.0 / (1.0 + (-v).exp())));
                let m = (&bi + &y2 * u.transpose()) * lrate;
                weights = &weights + m * &weights;
                if biasflag {
                    for i in 0..ncomps {
                        bias[i] += lrate * y2.row(i).sum();
                    }
                }
            } else {
                let y = u.map(|v| v.tanh());
                // signs*y
                let mut sy = y.clone();
                for i in 0..ncomps {
                    for b in 0..block {
                        sy[(i, b)] *= signs[i];
                    }
                }
                let m = (&bi - &sy * u.transpose() - &u * u.transpose()) * lrate;
                weights = &weights + m * &weights;
                if biasflag {
                    for i in 0..ncomps {
                        bias[i] += lrate * (-2.0 * y.row(i).sum());
                    }
                }
            }
            if momentum > 0.0 {
                weights = &weights + &prevwtchange * momentum;
                prevwtchange = &weights - &prevweights;
                prevweights = weights.clone();
            }
            if weights.iter().fold(0.0f64, |a, &v| a.max(v.abs())) > MAX_WEIGHT {
                wts_blowup = true;
            }
            if extended && !wts_blowup && extblocks > 0 && blockno % extblocks == 0 {
                let partact: Mat;
                if kurtsize < frames {
                    let mut rp: Vec<usize> = rng.rand(kurtsize).iter().map(|&r| (r * datalength as f64).trunc() as usize).collect();
                    loop {
                        let ou: Vec<usize> = rp.iter().enumerate().filter(|(_, &v)| v == 0).map(|(i, _)| i).collect();
                        if ou.is_empty() {
                            break;
                        }
                        let rr = rng.rand(ou.len());
                        for (k, &i) in ou.iter().enumerate() {
                            rp[i] = (rr[k] * datalength as f64).trunc() as usize;
                        }
                    }
                    let mut sel = Mat::zeros(chans, kurtsize);
                    for (k, &idx) in rp.iter().enumerate() {
                        sel.set_column(k, &data.column(idx - 1));
                    }
                    partact = &weights * &sel;
                } else {
                    partact = &weights * &data;
                }
                let n = partact.ncols() as f64;
                let mut kk = vec![0.0f64; ncomps];
                for i in 0..ncomps {
                    let mut s2 = 0.0;
                    let mut s4 = 0.0;
                    for j in 0..partact.ncols() {
                        let v = partact[(i, j)];
                        let v2 = v * v;
                        s2 += v2;
                        s4 += v2 * v2;
                    }
                    let m2 = (s2 / n).powi(2);
                    let m4 = s4 / n;
                    kk[i] = (m4 / m2) - 3.0;
                }
                if o.extmomentum != 0.0 {
                    for i in 0..ncomps {
                        kk[i] = o.extmomentum * old_kk[i] + (1.0 - o.extmomentum) * kk[i];
                    }
                    old_kk = kk.clone();
                }
                signs = kk.iter().map(|&k| sign(k + o.signsbias)).collect();
                if signs == oldsigns {
                    signcount += 1;
                } else {
                    signcount = 0;
                }
                oldsigns = signs.clone();
                if signcount >= SIGNCOUNT_THRESHOLD {
                    extblocks = ((extblocks * SIGNCOUNT_STEP) as f64).trunc() as i64;
                    signcount = 0;
                }
            }
            blockno += 1;
            if wts_blowup {
                break;
            }
            t += block;
        }

        if !wts_blowup {
            let oldwtchange = &weights - &oldweights;
            step += 1;
            lrates[step - 1] = lrate;
            angledelta = 0.0;
            // delta = reshape(oldwtchange,1,chans*ncomps) (column-major)
            delta = DVector::from_iterator(chans * ncomps, oldwtchange.iter().cloned());
            change = delta.dot(&delta);
        }

        if wts_blowup || change.is_nan() || change.is_infinite() {
            step = 0;
            wts_blowup = false;
            blockno = 1;
            lrate *= DEFAULT_RESTART_FAC;
            weights = startweights.clone();
            oldweights = startweights.clone();
            change = nochange;
            delta = DVector::zeros(chans * ncomps);
            olddelta = delta.clone();
            extblocks = urextblocks;
            prevweights = startweights.clone();
            prevwtchange = Mat::zeros(chans, ncomps);
            lrates = vec![0.0; maxsteps];
            bias = DVector::zeros(ncomps);
            if extended {
                signs = init_signs(ncomps, nsub);
                oldsigns = vec![0.0; ncomps];
            }
            if lrate > MIN_LRATE {
                let r = rank(&data);
                if r < ncomps {
                    return Err(format!("Data has rank {}. Cannot compute {} components.", r, ncomps));
                } else {
                    log(verb, format!("Lowering learning rate to {} and starting again.", lrate));
                }
            } else {
                return Err("runica(): QUITTING - weight matrix may not be invertible!".into());
            }
        } else {
            if step > 2 {
                let c = delta.dot(&olddelta) / (change * oldchange).sqrt();
                angledelta = c.acos();
            }
            log(
                verb && (step % 10 == 0 || step < 5),
                format!("step {} - lrate {:5.6}, wchange {:8.8}, angledelta {:4.1} deg", step, lrate, change, degconst * angledelta),
            );
            changes.push(change);
            oldweights = weights.clone();
            if degconst * angledelta > annealdeg {
                lrate *= annealstep;
                olddelta = delta.clone();
                oldchange = change;
            } else if step == 1 {
                olddelta = delta.clone();
                oldchange = change;
            }
            if step > 2 && change < nochange {
                laststep = step;
                step = maxsteps;
            } else if change > DEFAULT_BLOWUP {
                lrate *= DEFAULT_BLOWUP_FAC;
            }
        }
    }

    if laststep == 0 {
        laststep = step;
    }
    lrates.truncate(laststep);

    let mut weights = weights;
    let mut sphere = sphere;
    if pcaflag {
        let top = eigenvectors.columns(0, ncomps).into_owned();
        weights = &weights * &sphere * top.transpose();
        sphere = eye(urchans);
    }
    // sort components by mean projected variance
    let ws = &weights * &sphere;
    let winv = if ncomps == urchans { inv(&ws)? } else { pinv(&ws) };
    let mut meanvar = vec![0.0f64; ncomps];
    for k in 0..ncomps {
        let a: f64 = winv.column(k).iter().map(|v| v * v).sum();
        // sum((data').^2) is the row-wise sum of squares of `data`; MATLAB multiplies element-wise
        let b: f64 = if k < data.nrows() { data.row(k).iter().map(|v| v * v).sum() } else { 0.0 };
        meanvar[k] = a * b / ((chans * frames) as f64 - 1.0);
    }
    let mut windex: Vec<usize> = (0..ncomps).collect();
    windex.sort_by(|&i, &j| meanvar[i].partial_cmp(&meanvar[j]).unwrap_or(std::cmp::Ordering::Equal));
    windex.reverse();
    let meanvar_sorted: Vec<f64> = windex.iter().map(|&i| meanvar[i]).collect();

    let mut w_sorted = Mat::zeros(ncomps, weights.ncols());
    for (k, &i) in windex.iter().enumerate() {
        w_sorted.set_row(k, &weights.row(i));
    }
    let bias_sorted = DVector::from_iterator(ncomps, windex.iter().map(|&i| bias[i]));
    let signs_sorted: Vec<f64> = windex.iter().map(|&i| signs[i]).collect();

    Ok(RunicaResult {
        weights: w_sorted,
        sphere,
        bias: bias_sorted,
        signs: signs_sorted,
        lrates,
        changes,
        laststep,
        ncomps,
        windex,
        meanvar: meanvar_sorted,
        final_lrate: lrate,
    })
}
