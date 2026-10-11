//! Command-line plumbing shared by the `ccs_ica` binary (case-directory based, used by the validation harness).

use crate::io::*;
use crate::linalg::Mat;
use crate::iclabel::{extract_features, iclabel, run_network, ChanLoc, Eeg};
use crate::pipeline::*;
use crate::pop_runica::pop_runica;
use crate::resample::resample_to;
use crate::rng::{NativeRng, ReplayRng, Rng};
use crate::runica::{RunicaOpts, Sphering};
use serde_json::{json, Value};
use std::path::Path;

pub fn jf(v: &Value, k: &str) -> Option<f64> {
    v.get(k).and_then(|x| x.as_f64())
}
pub fn ji(v: &Value, k: &str) -> Option<i64> {
    v.get(k).and_then(|x| x.as_f64()).map(|x| x as i64)
}
pub fn js<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(|x| x.as_str())
}

pub fn runica_opts_from_json(o: &Value) -> RunicaOpts {
    let mut r = RunicaOpts::default();
    if let Some(v) = jf(o, "lrate") {
        r.lrate = Some(v);
    }
    if let Some(v) = ji(o, "block") {
        r.block = Some(v as usize);
    }
    if let Some(v) = ji(o, "maxsteps") {
        r.maxsteps = v as usize;
    }
    if let Some(v) = jf(o, "stop") {
        r.stop = Some(v);
    }
    if let Some(v) = ji(o, "extended") {
        r.extended = v;
    }
    if let Some(v) = ji(o, "pca") {
        r.pca = Some(v);
    }
    if let Some(s) = js(o, "sphering") {
        r.sphering = match s {
            "on" => Sphering::On,
            "off" => Sphering::Off,
            _ => Sphering::None,
        };
    }
    if let Some(s) = js(o, "bias") {
        r.bias = s == "on";
    }
    if let Some(v) = jf(o, "momentum") {
        r.momentum = v;
    }
    r
}

/// Build the RNG described in `meta["rng"]` (`replay` of logged MATLAB draws, or seeded Mersenne Twister).
pub fn rng_from_case(dir: &Path, meta: &Value) -> Result<Box<dyn Rng>, String> {
    let mode = meta.get("rng").and_then(|r| js(r, "mode")).unwrap_or("clock");
    match mode {
        "replay" => {
            let perms = read_i32(&dir.join("perms.i32"))?;
            let rands = if dir.join("rands.f64").exists() { read_f64(&dir.join("rands.f64"))? } else { vec![] };
            Ok(Box::new(ReplayRng::new(perms, rands)))
        }
        "seed" => {
            let s = meta.get("rng").and_then(|r| ji(r, "seed")).unwrap_or(0) as u32;
            Ok(Box::new(NativeRng::new(s)))
        }
        _ => Ok(Box::new(NativeRng::from_clock())),
    }
}

pub fn cmd_pop_runica(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    let nchan = ji(&meta, "nchan").ok_or("meta.nchan missing")? as usize;
    let pnts = ji(&meta, "pnts").ok_or("meta.pnts missing")? as usize;
    let data = read_mat(&indir.join("data.f64"), nchan, pnts)?;
    let opts = runica_opts_from_json(meta.get("options").unwrap_or(&json!({})));
    let chanind: Option<Vec<usize>> = meta
        .get("chanind")
        .and_then(|c| c.as_array())
        .map(|a| a.iter().map(|x| x.as_f64().unwrap() as usize - 1).collect());
    let mut rng = rng_from_case(indir, &meta)?;
    let t0 = std::time::Instant::now();
    let r = pop_runica(&data, chanind.as_deref(), &opts, rng.as_mut())?;
    let dt = t0.elapsed().as_secs_f64();
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_mat(&outdir.join("icaweights.f64"), &r.icaweights)?;
    write_mat(&outdir.join("icasphere.f64"), &r.icasphere)?;
    write_mat(&outdir.join("icawinv.f64"), &r.icawinv)?;
    let info = json!({
        "ncomps": r.icaweights.nrows(), "nchan_ica": r.icaweights.ncols(), "rank": r.rank,
        "used_pca": r.used_pca, "laststep": r.laststep, "final_lrate": r.final_lrate, "seconds": dt,
        "icachansind": r.icachansind.iter().map(|x| x + 1).collect::<Vec<_>>()
    });
    std::fs::write(outdir.join("info.json"), info.to_string()).map_err(|e| e.to_string())?;
    Ok(())
}


pub fn picard_opts_from_json(o: &Value) -> crate::picard::PicardOpts {
    use crate::picard::PicardOpts;
    let mut r = if o.get("eegprep").and_then(|x| x.as_bool()).unwrap_or(false) { PicardOpts::eegprep() } else { PicardOpts::default() };
    if let Some(b) = o.get("ortho").and_then(|x| x.as_bool()) { r.ortho = b; }
    if let Some(b) = o.get("extended").and_then(|x| x.as_bool()) { r.extended = Some(b); }
    if let Some(v) = ji(o, "n_components") { r.n_components = Some(v as usize); }
    if let Some(v) = ji(o, "max_iter") { r.max_iter = v as usize; }
    if let Some(v) = ji(o, "m") { r.m = v as usize; }
    if let Some(v) = ji(o, "ls_tries") { r.ls_tries = v as usize; }
    if let Some(v) = jf(o, "tol") { r.tol = v; }
    if let Some(v) = jf(o, "lambda_min") { r.lambda_min = v; }
    if let Some(b) = o.get("verbose").and_then(|x| x.as_bool()) { r.verbose = b; }
    r
}

/// `picard`: case dir with `meta.json` (nchan,pnts,options,chanind) + `data.f64`; writes ICA matrices like `pop_runica`.
pub fn cmd_picard(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    let nchan = ji(&meta, "nchan").ok_or("meta.nchan missing")? as usize;
    let pnts = ji(&meta, "pnts").ok_or("meta.pnts missing")? as usize;
    let data = read_mat(&indir.join("data.f64"), nchan, pnts)?;
    let opts = picard_opts_from_json(meta.get("options").unwrap_or(&json!({})));
    let chanind: Option<Vec<usize>> = meta.get("chanind").and_then(|c| c.as_array())
        .map(|a| a.iter().map(|x| x.as_f64().unwrap() as usize - 1).collect());
    let t0 = std::time::Instant::now();
    let r = crate::picard::pop_picard(&data, chanind.as_deref(), &opts)?;
    let dt = t0.elapsed().as_secs_f64();
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_mat(&outdir.join("icaweights.f64"), &r.icaweights)?;
    write_mat(&outdir.join("icasphere.f64"), &r.icasphere)?;
    write_mat(&outdir.join("icawinv.f64"), &r.icawinv)?;
    let info = json!({"ncomps": r.icaweights.nrows(), "iterations": r.laststep, "seconds": dt});
    std::fs::write(outdir.join("info.json"), info.to_string()).map_err(|e| e.to_string())?;
    Ok(())
}


/// `asr`: case dir with `meta.json` {nchan,pnts,srate,cutoff,mode:"correct"|"reject",artifacts:bool} + `data.f64` (nchan x pnts).
pub fn cmd_asr(indir: &Path, outdir: &Path) -> Result<(), String> {
    use crate::asr::*;
    let meta = read_json(&indir.join("meta.json"))?;
    let nchan = ji(&meta, "nchan").ok_or("meta.nchan missing")? as usize;
    let pnts = ji(&meta, "pnts").ok_or("meta.pnts missing")? as usize;
    let srate = jf(&meta, "srate").ok_or("meta.srate missing")?;
    let cutoff = jf(&meta, "cutoff").unwrap_or(5.0);
    let data = read_mat(&indir.join("data.f64"), nchan, pnts)?;
    let chans: Vec<Vec<f64>> = (0..nchan).map(|i| data.row(i).iter().cloned().collect()).collect();
    let mut p = if meta.get("artifacts").and_then(|x| x.as_bool()).unwrap_or(true) { AsrParams::clean_artifacts(cutoff) } else { AsrParams::clean_asr(cutoff) };
    if let Some(m) = jf(&meta, "max_mem") { p.max_mem = m; }
    if meta.get("riemannian").and_then(|x| x.as_bool()).unwrap_or(false) { p.riemannian = true; }
    if let Some(b) = jf(&meta, "rasr_block_seconds") { p.rasr_block_seconds = Some(b); }
    if std::env::var("ASR_DUMP_REF").is_ok() {
        let (r, _) = clean_windows(&chans, srate, p.ref_max_bad_channels, p.ref_tolerances, p.ref_wnd_len);
        std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
        write_f64(&outdir.join("ref_section.f64"), &r.iter().flat_map(|x| x.iter().cloned()).collect::<Vec<_>>())?;
    }
    let t0 = std::time::Instant::now();
    let (rep, st) = clean_asr(&chans, srate, &p)?;
    let dt = t0.elapsed().as_secs_f64();
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    let flat = |v: &Vec<Vec<f64>>| -> Vec<f64> { v.iter().flat_map(|r| r.iter().cloned()).collect() };
    write_f64(&outdir.join("repaired.f64"), &flat(&rep))?;
    let mut info = json!({"seconds": dt, "B": st.b, "A": st.a, "M": mat_to_vec2(&st.m), "T": mat_to_vec2(&st.t)});
    if js(&meta, "mode") == Some("reject") {
        let r = burst_rejection(&chans, &rep);
        write_f64(&outdir.join("rejected_data.f64"), &flat(&r.data))?;
        write_f64(&outdir.join("sample_mask.f64"), &r.sample_mask.iter().map(|&b| if b { 1.0 } else { 0.0 }).collect::<Vec<_>>())?;
        let (cw, cm) = clean_windows(&r.data, srate, 0.25, [f64::NEG_INFINITY, 7.0], 1.0);
        write_f64(&outdir.join("window_clean_data.f64"), &flat(&cw))?;
        write_f64(&outdir.join("window_mask.f64"), &cm.iter().map(|&b| if b { 1.0 } else { 0.0 }).collect::<Vec<_>>())?;
        info["kept_after_burst"] = json!(r.data[0].len());
    }
    std::fs::write(outdir.join("info.json"), info.to_string()).map_err(|e| e.to_string())
}

pub fn mat_to_vec2(m: &Mat) -> Vec<Vec<f64>> {
    (0..m.nrows()).map(|i| (0..m.ncols()).map(|j| m[(i, j)]).collect()).collect()
}

/// Read an EEG case: `meta.json` + `data.f64` (+ optional ICA matrices).
pub fn read_eeg_case(dir: &Path, meta: &Value) -> Result<Eeg, String> {
    let nbchan = ji(meta, "nbchan").ok_or("meta.nbchan missing")? as usize;
    let pnts = ji(meta, "pnts").ok_or("meta.pnts missing")? as usize;
    let trials = ji(meta, "trials").unwrap_or(1) as usize;
    let srate = jf(meta, "srate").ok_or("meta.srate missing")?;
    let data = read_mat(&dir.join("data.f64"), nbchan, pnts * trials)?;
    let chanlocs: Vec<ChanLoc> = meta
        .get("chanlocs")
        .and_then(|c| c.as_array())
        .map(|a| {
            a.iter()
                .map(|c| ChanLoc {
                    label: js(c, "label").unwrap_or("").to_string(),
                    theta: jf(c, "theta"),
                    radius: jf(c, "radius"),
                })
                .collect()
        })
        .unwrap_or_default();
    let icachansind: Vec<usize> = meta
        .get("icachansind")
        .and_then(|c| c.as_array())
        .map(|a| a.iter().map(|x| x.as_f64().unwrap() as usize - 1).collect())
        .unwrap_or_else(|| (0..nbchan).collect());
    let nica = icachansind.len();
    let ncomp = ji(meta, "ncomp").unwrap_or(nica as i64) as usize;
    let (w, s, v) = if dir.join("icaweights.f64").exists() {
        (
            read_mat(&dir.join("icaweights.f64"), ncomp, nica)?,
            read_mat(&dir.join("icasphere.f64"), nica, nica)?,
            read_mat(&dir.join("icawinv.f64"), nica, ncomp)?,
        )
    } else {
        (Mat::zeros(0, 0), Mat::zeros(0, 0), Mat::zeros(0, 0))
    };
    Ok(Eeg {
        data,
        pnts,
        trials,
        srate,
        chanlocs,
        icaweights: w,
        icasphere: s,
        icawinv: v,
        icachansind,
        reference: js(meta, "reference").unwrap_or("common").to_string(),
    })
}

fn flat32(v: &[Vec<f32>]) -> Vec<f64> {
    v.iter().flat_map(|r| r.iter().map(|&x| x as f64)).collect()
}

pub fn cmd_iclabel(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    let eeg = read_eeg_case(indir, &meta)?;
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    let t0 = std::time::Instant::now();
    let f = extract_features(&eeg)?;
    let t1 = t0.elapsed().as_secs_f64();
    write_f64(&outdir.join("topo.f64"), &flat32(&f.topo))?;
    write_f64(&outdir.join("psd.f64"), &flat32(&f.psd))?;
    write_f64(&outdir.join("autocorr.f64"), &flat32(&f.autocorr))?;
    let lab = iclabel(&eeg)?;
    write_mat(&outdir.join("classifications.f64"), &lab)?;
    let info = json!({"ncomp": lab.nrows(), "feature_seconds": t1, "total_seconds": t0.elapsed().as_secs_f64()});
    std::fs::write(outdir.join("info.json"), info.to_string()).map_err(|e| e.to_string())?;
    Ok(())
}

/// Network only: features (already 0.99-scaled) in, probabilities out.
pub fn cmd_net(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    let ncomp = ji(&meta, "ncomp").ok_or("meta.ncomp missing")? as usize;
    let rd = |name: &str, len: usize| -> Result<Vec<Vec<f32>>, String> {
        let v = read_f64(&indir.join(name))?;
        if v.len() != ncomp * len {
            return Err(format!("{}: expected {} values", name, ncomp * len));
        }
        Ok(v.chunks(len).map(|c| c.iter().map(|&x| x as f32).collect()).collect())
    };
    let lab = run_network(&rd("topo.f64", 1024)?, &rd("psd.f64", 100)?, &rd("autocorr.f64", 100)?);
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_mat(&outdir.join("classifications.f64"), &lab)
}

pub fn cmd_resample(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    let n = ji(&meta, "n").ok_or("meta.n")? as usize;
    let c = ji(&meta, "ncols").ok_or("meta.ncols")? as usize;
    let x = read_mat(&indir.join("x.f64"), n, c)?;
    let y = resample_to(&x, jf(&meta, "target").ok_or("meta.target")?, jf(&meta, "srate").ok_or("meta.srate")?);
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_mat(&outdir.join("y.f64"), &y)
}

fn stage_outputs(outdir: &Path, r: &StageResult) -> Result<(), String> {
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_mat(&outdir.join("icaweights.f64"), &r.ica.icaweights)?;
    write_mat(&outdir.join("icasphere.f64"), &r.ica.icasphere)?;
    write_mat(&outdir.join("icawinv.f64"), &r.ica.icawinv)?;
    write_mat(&outdir.join("classifications.f64"), &r.classifications)?;
    write_mat(&outdir.join("clean.f64"), &r.clean)?;
    let info = json!({
        "ncomps": r.ica.icaweights.nrows(), "rank": r.ica.rank, "laststep": r.ica.laststep,
        "comp2remove": r.selection.comp2remove, "ncompremoved": r.selection.ncompremoved,
        "signalslost": r.selection.signalslost, "final_threshold": r.selection.final_threshold,
        "iterations": r.selection.iterations
    });
    std::fs::write(outdir.join("info.json"), info.to_string()).map_err(|e| e.to_string())
}

/// ICA step 2 end to end. Case: `fit.f64` (nbchan x pnts, data for ICA), `data.f64` target, meta (+options).
pub fn cmd_ica2(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    // `data.f64` (the target EEG) may be longer than `fit.f64` (ASR removed samples before ICA): `ntarget` = its #samples
    let mut tmeta = meta.clone();
    if let Some(nt) = ji(&meta, "ntarget") {
        tmeta["pnts"] = json!(nt);
        tmeta["trials"] = json!(1);
    }
    let mut eeg = read_eeg_case(indir, &tmeta)?;
    eeg.icachansind = (0..eeg.data.nrows()).collect();
    let nbchan = eeg.data.nrows();
    let fit = read_mat(&indir.join("fit.f64"), nbchan, ji(&meta, "pnts").unwrap() as usize)?;
    let o = meta.get("options").cloned().unwrap_or(json!({}));
    let mut opts = Ica2Opts::default();
    if let Some(v) = ji(&o, "extended") {
        opts.extended = v;
    }
    if let Some(s) = js(&o, "sphering") {
        opts.sphering = match s {
            "on" => crate::runica::Sphering::On,
            "none" => crate::runica::Sphering::None,
            _ => crate::runica::Sphering::Off,
        };
    }
    if let Some(v) = ji(&o, "maxsteps") {
        opts.maxsteps = Some(v as usize);
    }
    if let Some(a) = o.get("threshold").and_then(|t| t.as_array()) {
        opts.threshold = a.iter().map(|x| x.as_f64().unwrap()).collect();
    }
    if let Some(a) = o.get("artefacts").and_then(|t| t.as_array()) {
        opts.artefacts = a.iter().map(|x| x.as_str().unwrap().to_string()).collect();
    }
    if let Some(v) = jf(&o, "maxcomp2rem") {
        opts.maxcomp2rem = v;
    }
    if let Some(v) = jf(&o, "maxsig2rem") {
        opts.maxsig2rem = v;
    }
    let mut rng = rng_from_case(indir, &meta)?;
    let r = ica2_other(&fit, &eeg, &opts, rng.as_mut())?;
    stage_outputs(outdir, &r)
}

/// ICA step 1 end to end. Case: `data.f64` = blink epochs (nbchan x pnts*trials), `target.f64` = EEGdata (nbchan x ntarget).
pub fn cmd_ica1(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    let eeg = read_eeg_case(indir, &meta)?;
    let nbchan = eeg.data.nrows();
    let ntarget = ji(&meta, "ntarget").ok_or("meta.ntarget")? as usize;
    let target = read_mat(&indir.join("target.f64"), nbchan, ntarget)?;
    let o = meta.get("options").cloned().unwrap_or(json!({}));
    let mut opts = Ica1Opts::default();
    if let Some(v) = ji(&o, "nsteps") {
        opts.nsteps = v as usize;
    }
    if let Some(a) = o.get("threshold").and_then(|t| t.as_array()) {
        opts.threshold = a.iter().map(|x| x.as_f64().unwrap()).collect();
    }
    if let Some(v) = ji(&o, "removeecg") {
        opts.removeecg = v != 0;
    }
    let mut rng = rng_from_case(indir, &meta)?;
    let r = ica1_blink_ecg(&eeg.data, eeg.pnts, eeg.trials, eeg.srate, &eeg.chanlocs, &target, &opts, rng.as_mut())?;
    stage_outputs(outdir, &r)
}

/// Selection only: classifications in -> components out (parity of the accs_* threshold loops).
pub fn cmd_select(indir: &Path, outdir: &Path) -> Result<(), String> {
    let meta = read_json(&indir.join("meta.json"))?;
    let ncomp = ji(&meta, "ncomp").ok_or("meta.ncomp")? as usize;
    let classif = read_mat(&indir.join("classifications.f64"), ncomp, 7)?;
    let nbchan = ji(&meta, "nbchan").ok_or("meta.nbchan")? as usize;
    let thr: Vec<f64> = meta.get("threshold").and_then(|t| t.as_array()).map(|a| a.iter().map(|x| x.as_f64().unwrap()).collect()).unwrap_or(vec![0.99, 0.6]);
    let sel = if js(&meta, "mode") == Some("eyeblink") {
        crate::autoremove::eyeblink_selection(&classif, nbchan, &thr, ji(&meta, "removeecg").unwrap_or(1) != 0)?
    } else {
        let comps: Vec<String> = meta.get("artefacts").and_then(|t| t.as_array()).map(|a| a.iter().map(|x| x.as_str().unwrap().to_string()).collect()).unwrap_or_default();
        crate::autoremove::auto_ica_selection(&classif, nbchan, &thr, &comps, jf(&meta, "maxcomp2rem").unwrap_or(0.1), jf(&meta, "maxsig2rem").unwrap_or(0.3))?
    };
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    let info = json!({"comp2remove": sel.comp2remove, "ncompremoved": sel.ncompremoved, "signalslost": sel.signalslost, "final_threshold": sel.final_threshold, "iterations": sel.iterations});
    std::fs::write(outdir.join("info.json"), info.to_string()).map_err(|e| e.to_string())
}

/// `blink`: `meta.json {pnts, srate}` + `data.f64` (one row).  Writes `events.json` (1-based, grouped),
/// `filtered.f64` (eegfilt 1.5-15 Hz) and `firls.f64` (taps).
pub fn cmd_blink(indir: &Path, outdir: &Path) -> Result<(), String> {
    use crate::blink::*;
    let meta = read_json(&indir.join("meta.json"))?;
    let pnts = ji(&meta, "pnts").ok_or("meta.pnts missing")? as usize;
    let srate = jf(&meta, "srate").ok_or("meta.srate missing")?;
    let data = read_mat(&indir.join("data.f64"), 1, pnts)?;
    let x: Vec<f64> = data.row(0).iter().cloned().collect();
    let ev = eyeblink_detection(&x, srate)?;
    let filt = eegfilt(&x, srate, 1.5, 15.0)?;
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_f64(&outdir.join("filtered.f64"), &filt)?;
    let nyq = srate / 2.0;
    let order = 3 * (srate / 1.5).trunc() as usize;
    let w = firls(order, &[0.0, 0.85 * 1.5 / nyq, 1.5 / nyq, 15.0 / nyq, 1.15 * 15.0 / nyq, 1.0], &[0.0, 0.0, 1.0, 1.0, 0.0, 0.0])?;
    write_f64(&outdir.join("firls.f64"), &w)?;
    std::fs::write(outdir.join("events.json"), json!({ "events": ev }).to_string()).map_err(|e| e.to_string())
}

/// `studio`: end-to-end `studio::clean_ica` on one case: `meta.json {nchan,pnts,srate,method,fit_asr,seed,chanlocs:[{label,theta,radius}]}`
/// + `data.f64` (target) [+ `hp.f64`].  Writes `clean.f64` and `report.json`.
pub fn cmd_studio(indir: &Path, outdir: &Path) -> Result<(), String> {
    use crate::studio::*;
    let meta = read_json(&indir.join("meta.json"))?;
    let nchan = ji(&meta, "nchan").ok_or("meta.nchan missing")? as usize;
    let pnts = ji(&meta, "pnts").ok_or("meta.pnts missing")? as usize;
    let srate = jf(&meta, "srate").ok_or("meta.srate missing")?;
    let data = read_mat(&indir.join("data.f64"), nchan, pnts)?;
    let hp = if indir.join("hp.f64").exists() { read_mat(&indir.join("hp.f64"), nchan, pnts)? } else { data.clone() };
    let rows = |m: &Mat| -> Vec<Vec<f64>> { (0..m.nrows()).map(|i| m.row(i).iter().cloned().collect()).collect() };
    let locs: Vec<ChanLoc> = meta.get("chanlocs").and_then(|c| c.as_array()).ok_or("meta.chanlocs missing")?
        .iter().map(|c| ChanLoc { label: js(c, "label").unwrap_or("").to_string(), theta: jf(c, "theta"), radius: jf(c, "radius") }).collect();
    let mut o = StudioIcaOpts::default();
    if js(&meta, "method") == Some("picard") { o.method = crate::pipeline::IcaMethod::Picard; }
    o.fit_asr_cutoff = jf(&meta, "fit_asr");
    if let Some(s) = ji(&meta, "seed") { o.seed = s as u32; }
    let t0 = std::time::Instant::now();
    let (clean, rep) = clean_ica(&rows(&data), &rows(&hp), &locs, srate, &o)?;
    let dt = t0.elapsed().as_secs_f64();
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_f64(&outdir.join("clean.f64"), &clean.iter().flat_map(|r| r.iter().cloned()).collect::<Vec<_>>())?;
    let st = |s: &StageReport| json!({"ran": s.ran, "components": s.components, "removed": s.removed, "classes": s.removed_class, "signals_lost": s.signals_lost, "note": s.note});
    let info = json!({"seconds": dt, "blink_events": rep.blink_events, "epochs": rep.blink_epochs_used, "eye": rep.eye_chan, "stage1": st(&rep.stage1), "stage2": st(&rep.stage2), "notes": rep.notes});
    std::fs::write(outdir.join("report.json"), info.to_string()).map_err(|e| e.to_string())
}

/// `variant <indir> <outdir>`: run one of the ASR variants / alternative cleaners (meta.json `method`) on `data.f64`.
pub fn cmd_variant(indir: &Path, outdir: &Path) -> Result<(), String> {
    use crate::asr::AsrParams;
    use crate::variants::*;
    let meta = read_json(&indir.join("meta.json"))?;
    let nchan = ji(&meta, "nchan").ok_or("meta.nchan missing")? as usize;
    let pnts = ji(&meta, "pnts").ok_or("meta.pnts missing")? as usize;
    let srate = jf(&meta, "srate").ok_or("meta.srate missing")?;
    let method = js(&meta, "method").ok_or("meta.method missing")?.to_string();
    let data = read_mat(&indir.join("data.f64"), nchan, pnts)?;
    let chans: Vec<Vec<f64>> = (0..nchan).map(|i| data.row(i).iter().cloned().collect()).collect();
    let cutoff = jf(&meta, "cutoff").unwrap_or(15.0);
    let mut p = AsrParams::clean_artifacts(cutoff);
    if let Some(m) = jf(&meta, "max_mem") { p.max_mem = m; }
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    let flat = |v: &Vec<Vec<f64>>| -> Vec<f64> { v.iter().flat_map(|r| r.iter().cloned()).collect() };
    let t0 = std::time::Instant::now();
    let mut info = json!({"method": method});
    let out: Vec<Vec<f64>> = match method.as_str() {
        "bss_cca" => {
            let o = BssCcaOpts { lag: ji(&meta, "lag").unwrap_or(1) as usize, n_remove: ji(&meta, "n_remove").map(|v| v as usize), rho_threshold: jf(&meta, "rho_threshold") };
            let (y, rep) = bss_cca(&chans, &o)?;
            info["rho"] = json!(rep.rho);
            info["removed"] = json!(rep.removed);
            write_f64(&outdir.join("sources.f64"), &rep.sources.transpose().iter().cloned().collect::<Vec<_>>())?; // row-major k x T
            y
        }
        "icanclean" => {
            let mut o = ICanCleanOpts::default();
            if let Some(v) = jf(&meta, "segment_len") { o.segment_len = v; }
            if let Some(v) = jf(&meta, "overlap") { o.overlap = v; }
            if let Some(v) = jf(&meta, "threshold") { o.threshold = v; }
            if let Some(v) = jf(&meta, "max_reject_fraction") { o.max_reject_fraction = v; }
            if let (Some(a), Some(b)) = (jf(&meta, "stop_lo"), jf(&meta, "stop_hi")) { o.ref_stop_band = (a, b); }
            let (y, rep) = icanclean_pseudo(&chans, srate, &o)?;
            info["removed_per_window"] = json!(rep.removed_per_window);
            y
        }
        "adaptive" => {
            let o = AdaptiveAsrOpts { alpha: jf(&meta, "alpha").unwrap_or(0.05), block_seconds: jf(&meta, "block_seconds").unwrap_or(2.0) };
            let (y, n) = adaptive_asr(&chans, srate, &p, &o)?;
            info["updates"] = json!(n);
            y
        }
        "easr" => easr(&chans, srate, ji(&meta, "dim").unwrap_or(8) as usize, ji(&meta, "tau").unwrap_or(2) as usize, &p)?,
        "vmd" => {
            let v = crate::decomp::VmdOpts { k: ji(&meta, "k").unwrap_or(5) as usize, alpha: jf(&meta, "alpha").unwrap_or(2000.0), ..Default::default() };
            vmd_asr(&chans, srate, &v, &p)?
        }
        "vmd_modes" => {
            // decomposition only (first channel) for comparison with MATLAB vmd
            let v = crate::decomp::VmdOpts { k: ji(&meta, "k").unwrap_or(5) as usize, alpha: jf(&meta, "alpha").unwrap_or(2000.0), ..Default::default() };
            let (m, cf, it) = crate::decomp::vmd(&chans[0], srate, &v);
            info["center_freqs"] = json!(cf);
            info["iterations"] = json!(it);
            m
        }
        "emd_modes" => {
            let (imfs, res) = crate::decomp::emd(&chans[0], 12, 0.2, 50);
            info["n_imfs"] = json!(imfs.len());
            let mut v = imfs;
            v.push(res);
            v
        }
        "emd" => emd_asr(&chans, srate, ji(&meta, "k").unwrap_or(5) as usize, &p)?,
        "wica_w" => {
            let w = read_mat(&indir.join("W.f64"), nchan, nchan)?;
            wica_with_unmixing(&chans, &w, &WicaOpts { levels: ji(&meta, "levels").unwrap_or(5) as usize, threshold_mult: jf(&meta, "threshold_mult").unwrap_or(1.0), seed: 1 })?
        }
        "wica" => wica(&chans, &WicaOpts { levels: ji(&meta, "levels").unwrap_or(5) as usize, threshold_mult: jf(&meta, "threshold_mult").unwrap_or(1.0), seed: ji(&meta, "seed").unwrap_or(1) as u32 })?,
        "juggler_dbscan" | "juggler_gev" => {
            let st = if method == "juggler_gev" { Juggler::Gev } else { Juggler::Dbscan };
            let (y, sel) = juggler_asr(&chans, srate, st, ji(&meta, "top_k").unwrap_or(5) as usize, &p)?;
            info["detail"] = json!(sel.detail);
            write_f64(&outdir.join("ref_mask.f64"), &sel.mask.iter().map(|&b| if b { 1.0 } else { 0.0 }).collect::<Vec<_>>())?;
            y
        }
        "gev_fit" => {
            let (k, s, m) = gev_fit(&chans[0]);
            info["k"] = json!(k);
            info["sigma"] = json!(s);
            info["mu"] = json!(m);
            vec![vec![0.0]]
        }
        "cca" => {
            // first half of the channels = X, second half = Y
            let h = nchan / 2;
            let x = data.rows(0, h).into_owned();
            let y = data.rows(h, nchan - h).into_owned();
            let c = cca(&x, &y)?;
            info["r"] = json!(c.r);
            vec![vec![0.0]]
        }
        other => return Err(format!("unknown variant method {other}")),
    };
    info["seconds"] = json!(t0.elapsed().as_secs_f64());
    write_f64(&outdir.join("out.f64"), &flat(&out))?;
    std::fs::write(outdir.join("info.json"), info.to_string()).map_err(|e| e.to_string())
}

/// `butter <indir> <outdir>`: meta {btype, f1, f2?, order, fs}; filters data.f64 (row-major `nchan x pnts`) with sosfiltfilt.
pub fn cmd_butter(indir: &Path, outdir: &Path) -> Result<(), String> {
    use crate::butter::*;
    let meta = read_json(&indir.join("meta.json"))?;
    let nchan = ji(&meta, "nchan").ok_or("nchan")? as usize;
    let pnts = ji(&meta, "pnts").ok_or("pnts")? as usize;
    let fs = jf(&meta, "fs").ok_or("fs")?;
    let order = ji(&meta, "order").unwrap_or(4) as usize;
    let f1 = jf(&meta, "f1").ok_or("f1")?;
    let f2 = jf(&meta, "f2").unwrap_or(0.0);
    let bt = match js(&meta, "btype").ok_or("btype")? {
        "lowpass" => BType::Lowpass(f1),
        "highpass" => BType::Highpass(f1),
        "bandpass" => BType::Bandpass(f1, f2),
        "bandstop" => BType::Bandstop(f1, f2),
        o => return Err(format!("btype {o}")),
    };
    let data = read_mat(&indir.join("data.f64"), nchan, pnts)?;
    let sos = butter_sos(order, bt, fs);
    let mut out = vec![];
    for i in 0..nchan {
        let row: Vec<f64> = data.row(i).iter().cloned().collect();
        out.extend(sosfiltfilt(&sos, &row)?);
    }
    std::fs::create_dir_all(outdir).map_err(|e| e.to_string())?;
    write_f64(&outdir.join("out.f64"), &out)?;
    write_f64(&outdir.join("sos.f64"), &sos.iter().flat_map(|s| s.iter().cloned()).collect::<Vec<_>>())
}
