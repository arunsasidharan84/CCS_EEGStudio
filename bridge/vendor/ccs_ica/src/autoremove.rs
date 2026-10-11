//! Component selection / removal logic of the CCS pipeline:
//! `accs_autoICAremoval.m` (ICA step 2), the dynamic-threshold loop of `accs_eyeblinkremoval.m` (ICA step 1)
//! and EEGLAB `pop_subcomp.m`.  The selection loops intentionally reproduce the MATLAB behaviour literally
//! (threshold lowered by 0.0005 per iteration, `signalslost` accumulated on every increase, the component
//! list being the one from the *last executed* iteration).

use crate::iclabel::CLASSES;
use crate::linalg::*;

#[derive(Debug, Clone)]
pub struct Selection {
    /// 1-based component indices in MATLAB order (class by class, ascending within a class).
    pub comp2remove: Vec<usize>,
    pub ncompremoved: usize,
    pub signalslost: f64,
    pub final_threshold: f64,
    pub iterations: usize,
}

/// `accs_autoICAremoval` selection (two-element threshold `[high low]`).
/// `complist` entries are matched by `contains(classes, complist)` (substring match).
pub fn auto_ica_selection(
    classif: &Mat,
    nbchan: usize,
    threshold: &[f64],
    complist: &[String],
    maxcomp2rem: f64,
    maxsig2rem: f64,
) -> Result<Selection, String> {
    if threshold.len() != 2 {
        // In the MATLAB source the scalar-threshold branch references `ncompremoved` before it is assigned and
        // therefore errors ("Unrecognized function or variable 'ncompremoved'"); the pipeline's try/catch then
        // skips the step. Keep that behaviour.
        return Err("accs_autoICAremoval: scalar threshold is not supported (MATLAB errors: 'ncompremoved' undefined)".into());
    }
    let compindx: Vec<usize> = CLASSES
        .iter()
        .enumerate()
        .filter(|(_, c)| complist.iter().any(|p| c.contains(p.as_str())))
        .map(|(i, _)| i)
        .collect();
    let mut ncompremoved = 0usize;
    let mut signalslost = 0.0f64;
    let mut threshold1 = threshold[0];
    let threshold2 = threshold[1];
    let mut comp2remove: Option<Vec<usize>> = None;
    let mut it = 0;
    while (ncompremoved as f64) < maxcomp2rem * nbchan as f64 && signalslost < maxsig2rem && threshold1 > threshold2 {
        let mut c2r: Vec<usize> = Vec::new();
        for &ci in &compindx {
            for k in 0..classif.nrows() {
                if classif[(k, ci)] >= threshold1 {
                    c2r.push(k + 1);
                }
            }
        }
        threshold1 -= 0.0005;
        if c2r.len() > ncompremoved {
            ncompremoved = c2r.len();
            signalslost += c2r.iter().map(|&k| classif[(k - 1, 0)]).sum::<f64>();
        }
        comp2remove = Some(c2r);
        it += 1;
    }
    let comp2remove = comp2remove.ok_or_else(|| "accs_autoICAremoval: selection loop never ran (comp2remove undefined)".to_string())?;
    Ok(Selection { comp2remove, ncompremoved, signalslost, final_threshold: threshold1, iterations: it })
}

/// Dynamic threshold of `accs_eyeblinkremoval` (ICA step 1): Eye (column 3) and optionally Heart (column 4).
pub fn eyeblink_selection(
    classif: &Mat,
    nchan: usize,
    threshold: &[f64],
    removeecg: bool,
) -> Result<Selection, String> {
    let pick = |thr: f64| -> Vec<usize> {
        (0..classif.nrows())
            .filter(|&k| classif[(k, 2)] >= thr || (removeecg && classif[(k, 3)] >= thr))
            .map(|k| k + 1)
            .collect()
    };
    if threshold.len() == 2 {
        let mut ncompremoved = 0usize;
        let mut signalslost = 0.0f64;
        let mut t1 = threshold[0];
        let t2 = threshold[1];
        let mut comp: Option<Vec<usize>> = None;
        let mut it = 0;
        while (ncompremoved as f64) < 0.1 * nchan as f64 && signalslost < 0.4 && t1 > t2 {
            let c = pick(t1);
            t1 -= 0.0005;
            if c.len() > ncompremoved {
                ncompremoved = c.len();
                signalslost += c.iter().map(|&k| classif[(k - 1, 0)]).sum::<f64>();
            }
            comp = Some(c);
            it += 1;
        }
        let comp2remove = comp.ok_or_else(|| "eyeblink selection: loop never ran (comp2remove undefined)".to_string())?;
        Ok(Selection { comp2remove, ncompremoved, signalslost, final_threshold: t1, iterations: it })
    } else {
        let c = pick(threshold[0]);
        let n = c.len();
        let s: f64 = c.iter().map(|&k| classif[(k - 1, 0)]).sum();
        Ok(Selection { comp2remove: c, ncompremoved: n, signalslost: s, final_threshold: threshold[0], iterations: 0 })
    }
}

/// `pop_subcomp(EEG, comps, 0, 0)` numerics: project out components. `data` is `nbchan x npts` (all channels),
/// the ICA acts on rows `icachansind` (0-based). `comps` are 1-based. Returns the cleaned data and the pruned
/// `(icaweights, icawinv)` (components removed).
pub fn pop_subcomp(
    data: &Mat,
    icaweights: &Mat,
    icasphere: &Mat,
    icawinv: &Mat,
    icachansind: &[usize],
    comps: &[usize],
) -> Result<(Mat, Mat, Mat), String> {
    let ncomp = icaweights.nrows();
    if comps.is_empty() {
        return Ok((data.clone(), icaweights.clone(), icawinv.clone()));
    }
    if comps.iter().any(|&c| c < 1 || c > ncomp) {
        return Err("Component index out of range".into());
    }
    let keep: Vec<usize> = (1..=ncomp).filter(|c| !comps.contains(c)).collect();
    let mut x = Mat::zeros(icachansind.len(), data.ncols());
    for (k, &c) in icachansind.iter().enumerate() {
        x.set_row(k, &data.row(c));
    }
    let ws = icaweights * icasphere;
    let mut wk = Mat::zeros(keep.len(), ws.ncols());
    let mut vk = Mat::zeros(icawinv.nrows(), keep.len());
    for (i, &k) in keep.iter().enumerate() {
        wk.set_row(i, &ws.row(k - 1));
        vk.set_column(i, &icawinv.column(k - 1));
    }
    let proj = &vk * (&wk * &x);
    let mut out = data.clone();
    for (k, &c) in icachansind.iter().enumerate() {
        out.set_row(c, &proj.row(k));
    }
    let mut wnew = Mat::zeros(keep.len(), icaweights.ncols());
    for (i, &k) in keep.iter().enumerate() {
        wnew.set_row(i, &icaweights.row(k - 1));
    }
    Ok((out, wnew, vk))
}
