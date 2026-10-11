//! Port of the numeric part of EEGLAB `pop_runica.m` for `icatype='runica'`:
//! rank detection (`getrank`), PCA fallback for rank-deficient data, the call to `runica` with
//! `'lrate',0.001` first, and the post-hoc variance re-ordering with `icawinv = pinv(W*S)`.

use crate::linalg::*;
use crate::rng::Rng;
use crate::runica::{runica, RunicaOpts};

#[derive(Debug)]
pub struct IcaResult {
    pub icaweights: Mat,
    pub icasphere: Mat,
    pub icawinv: Mat,
    pub icachansind: Vec<usize>,
    /// Rank detected by `getrank` on the first 3000 samples.
    pub rank: usize,
    pub used_pca: bool,
    pub laststep: usize,
    pub final_lrate: f64,
}

/// `getrank(tmpdata, pca_opt)` from pop_runica.m.
pub fn getrank(x: &Mat, pca_opt: bool) -> usize {
    let r1 = rank(x);
    let c = cov_rows(x, 0); // cov(tmpdata',1)
    let (vals, _) = sym_eig_sorted_asc(&c);
    let r2 = vals.iter().filter(|&&v| v > 1e-7).count();
    let _ = pca_opt;
    if r1 != r2 {
        r1.min(r2)
    } else {
        r2
    }
}

/// `data` is `nbchan x (pnts*trials)`; `chanind` are the 0-based channels fed to ICA (None = all).
pub fn pop_runica(
    data: &Mat,
    chanind: Option<&[usize]>,
    options: &RunicaOpts,
    rng: &mut dyn Rng,
) -> Result<IcaResult, String> {
    let chanind: Vec<usize> = match chanind {
        Some(c) => c.to_vec(),
        None => (0..data.nrows()).collect(),
    };
    let nch = chanind.len();
    let npts = data.ncols();
    let mut tmpdata = Mat::zeros(nch, npts);
    for (k, &c) in chanind.iter().enumerate() {
        tmpdata.set_row(k, &data.row(c));
    }
    let pca_opt = options.pca.is_some();
    let ncols_rank = npts.min(3000);
    let tmprank = getrank(&tmpdata.columns(0, ncols_rank).into_owned(), pca_opt);
    let means = row_means(&tmpdata);
    let mut centred = tmpdata.clone();
    for j in 0..npts {
        for i in 0..nch {
            centred[(i, j)] -= means[i];
        }
    }
    let mut opts = options.clone();
    if opts.lrate.is_none() {
        opts.lrate = Some(0.001); // pop_runica passes 'lrate',0.001 before the user options
    }
    let mut used_pca = pca_opt;
    if !(tmprank == nch || pca_opt) {
        opts.pca = Some(tmprank as i64);
        used_pca = true;
    }
    let res = runica(&centred, &opts, rng)?;
    let icaweights = res.weights;
    let icasphere = res.sphere;

    // post-processing in pop_runica: re-order by projected variance of the *original* data
    let ws = &icaweights * &icasphere;
    let icawinv0 = pinv(&ws);
    let proj = &ws * &tmpdata; // (comps x pnts)
    let ncomp = icaweights.nrows();
    let mut meanvar = vec![0.0f64; ncomp];
    for k in 0..ncomp {
        let a: f64 = icawinv0.column(k).iter().map(|v| v * v).sum();
        let b: f64 = proj.row(k).iter().map(|v| v * v).sum();
        meanvar[k] = a * b / ((nch * npts) as f64 - 1.0);
    }
    let mut windex: Vec<usize> = (0..ncomp).collect();
    windex.sort_by(|&i, &j| meanvar[i].partial_cmp(&meanvar[j]).unwrap_or(std::cmp::Ordering::Equal));
    windex.reverse();
    let mut w2 = Mat::zeros(ncomp, icaweights.ncols());
    for (k, &i) in windex.iter().enumerate() {
        w2.set_row(k, &icaweights.row(i));
    }
    let winv = pinv(&(&w2 * &icasphere));
    // eeg_checkset (called at the end of pop_runica) scales the components to RMS microvolt
    let (w2, winv) = scale_rms(&w2, &icasphere, &winv);
    Ok(IcaResult {
        icaweights: w2,
        icasphere,
        icawinv: winv,
        icachansind: chanind,
        rank: tmprank,
        used_pca,
        laststep: res.laststep,
        final_lrate: res.final_lrate,
    })
}
