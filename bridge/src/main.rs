use ccs_eeg_engine::*;
use rayon::prelude::*;
use serde::Deserialize;
use std::{env, fs, io::Write, path::Path};


#[derive(Deserialize)]
struct Job {
    #[serde(default = "default_extract_job")]
    job_type: String,
    input: String,
    output: String,
    format: String,
    data_path: Option<String>,
    sample_rate: Option<f64>,
    labels: Option<Vec<String>>,
    sample_count: Option<usize>,
    epoch_count: Option<usize>,
    points_per_epoch: Option<usize>,
    epoch_seconds: f64,
    options: Options,
    preprocessing: Option<preprocessing::PreprocessOptions>,
    selected_channels: Option<Vec<String>>,
    accepted_intervals: Option<Vec<[f64; 2]>>,
    rejected_intervals: Option<Vec<[f64; 2]>>,
}

fn main() -> Result<(), String> {
    let job_path = env::args()
        .nth(1)
        .ok_or("usage: ccs-eeg-engine <job.json>")?;
    let job: Job = serde_json::from_slice(&fs::read(&job_path).map_err(err)?).map_err(err)?;
    eprintln!("PROGRESS 0 Loading {}", job.input);
    
    if job.job_type == "inspect_set" {
        let mat = set_loader::load_set(Path::new(&job.input))?;
        let srate = mat.fields.get("srate").and_then(|v| v.first()).and_then(|v| v.numeric.first().copied()).unwrap_or(0.0);
        let trials = mat.fields.get("trials").and_then(|v| v.first()).and_then(|v| v.numeric.first().copied()).unwrap_or(1.0) as usize;
        
        let data = mat.fields.get("data").and_then(|v| v.first());
        let data_dims = data.map(|d| d.dims.clone()).unwrap_or_default();
        let channel_count = mat.fields.get("nbchan").and_then(|v| v.first()).and_then(|v| v.numeric.first().copied()).unwrap_or(if !data_dims.is_empty() { data_dims[0] as f64 } else { 1.0 }) as usize;
        let points_per_epoch = mat.fields.get("pnts").and_then(|v| v.first()).and_then(|v| v.numeric.first().copied()).unwrap_or(if data_dims.len() > 1 { data_dims[1] as f64 } else { 0.0 }) as usize;
        
        let mut labels = Vec::new();
        if let Some(chanlocs_vec) = mat.fields.get("chanlocs") {
            if let Some(chanlocs) = chanlocs_vec.first() {
                if let Some(label_fields) = chanlocs.fields.get("labels") {
                    for l in label_fields {
                        if !l.text.is_empty() {
                            labels.push(l.text.clone());
                        }
                    }
                }
            }
        }
        while labels.len() < channel_count {
            labels.push(format!("Ch {}", labels.len() + 1));
        }
        labels.truncate(channel_count);
        
        let mut markers = Vec::new();
        if let Some(events_vec) = mat.fields.get("event") {
            for ev in events_vec {
                let event_type = ev.fields.get("type")
                    .and_then(|v| v.first())
                    .map(|v| if !v.text.is_empty() { v.text.clone() } else if let Some(n) = v.numeric.first() { format!("{}", n) } else { "Event".to_string() })
                    .unwrap_or_else(|| "Event".to_string());
                let latency = ev.fields.get("latency")
                    .and_then(|v| v.first())
                    .and_then(|v| v.numeric.first().copied())
                    .unwrap_or(1.0);
                let duration = ev.fields.get("duration")
                    .and_then(|v| v.first())
                    .and_then(|v| v.numeric.first().copied())
                    .unwrap_or(0.0);

                let start_seconds = if srate > 0.0 { (latency - 1.0) / srate } else { 0.0 };
                let duration_seconds = if srate > 0.0 { duration / srate } else { 0.0 };

                markers.push(serde_json::json!({
                    "type": "Event",
                    "description": event_type,
                    "start_seconds": start_seconds.max(0.0),
                    "duration_seconds": duration_seconds.max(0.0),
                }));
            }
        }

        let datfile = data.map(|d| d.text.clone()).unwrap_or_default();
        let json = serde_json::json!({
            "sample_rate": srate,
            "labels": labels,
            "sample_count": points_per_epoch * trials,
            "epoch_count": trials,
            "points_per_epoch": points_per_epoch,
            "datfile": datfile,
            "format": "set",
            "markers": markers,
        });
        println!("{}", serde_json::to_string_pretty(&json).map_err(err)?);
        return Ok(());
    }
    if job.job_type == "inspect_fif" {
        let rec = fif_loader::load_fif(Path::new(&job.input))?;
        let total_samples = rec.channels.first().map(Vec::len).unwrap_or(0);
        let points_per_epoch = rec.source_epoch_samples.unwrap_or(total_samples);
        let epoch_count = if points_per_epoch > 0 {
            total_samples / points_per_epoch
        } else {
            1
        };
        let stride = if epoch_count > 1 {
            1
        } else {
            (total_samples / 50_000).max(1)
        };
        let preview: Vec<Vec<f32>> = rec
            .channels
            .iter()
            .map(|ch| ch.iter().step_by(stride).copied().collect())
            .collect();
        let json = serde_json::json!({
            "sample_rate": rec.rate,
            "labels": rec.labels,
            "sample_count": total_samples,
            "epoch_count": epoch_count,
            "points_per_epoch": points_per_epoch,
            "epoch_labels": rec.epoch_labels,
            "preview": preview,
            "format": "fif"
        });
        println!("{}", serde_json::to_string_pretty(&json).map_err(err)?);
        return Ok(());
    }

    let mut recording = if job.format == "set" {
        load_fdt(&job)?
    } else if job.format == "fif" || job.input.to_lowercase().ends_with(".fif") {
        fif_loader::load_fif(Path::new(&job.input))?
    } else if job.format == "vhdr" || job.input.to_lowercase().ends_with(".vhdr") {
        vhdr_loader::load_vhdr(Path::new(&job.input))?
    } else if job.format == "ccseeg" || job.input.ends_with(".ccseeg.json") {
        preprocessing::load_portable(Path::new(&job.input))?
    } else {
        load_edf(Path::new(&job.input))?
    };
    if recording.channels.is_empty() {
        return Err("recording has no channels".into());
    }
    apply_channel_selection(&mut recording, job.selected_channels.as_deref());
    apply_interval_selection(
        &mut recording,
        job.accepted_intervals.as_deref(),
        job.rejected_intervals.as_deref(),
    );
    if job.job_type == "preprocess" {
        let summary = preprocessing::run(
            &mut recording,
            &job.input,
            &job.output,
            &job.preprocessing.clone().unwrap_or_else(default_preprocessing),
        )?;
        println!("{}", serde_json::to_string_pretty(&summary).map_err(err)?);
        eprintln!("PROGRESS 100 Preprocessing complete");
        return Ok(());
    }

    if job.options.remove_non_eeg {
        remove_non_eeg_and_reference(&mut recording, &job.options.non_eeg_channels);
    }
    let epoch_samples = recording
        .source_epoch_samples
        .filter(|_| job.epoch_count.unwrap_or(1) > 1)
        .unwrap_or_else(|| (job.epoch_seconds * recording.rate).round() as usize)
        .max(4);
    let total_epochs = recording.channels[0].len() / epoch_samples;
    if total_epochs == 0 {
        return Err("recording is shorter than one analysis epoch".into());
    }
    let groups = groups(
        &job.options,
        total_epochs,
        epoch_samples as f64 / recording.rate,
    )?;
    let columns = columns(&job.options);
    let basename = Path::new(&job.input)
        .file_stem()
        .and_then(|x| x.to_str())
        .unwrap_or("recording");
    let parts: Vec<&str> = basename.split('_').collect();
    let mut all = Vec::new();
    for (gi, (first, last, start, end)) in groups.iter().copied().enumerate() {
        eprintln!(
            "PROGRESS {} Extracting bin {}",
            5 + gi * 90 / groups.len(),
            gi + 1
        );
        let channels = &recording.channels;
        let labels = &recording.labels;
        let rate = recording.rate;
        let epoch_labels = &recording.epoch_labels;
        let rows: Vec<Row> = (first..last)
            .into_par_iter()
            .flat_map_iter(|epoch| {
                let a = epoch * epoch_samples;
                let b = a + epoch_samples;
                let options = &job.options;
                let connectivity =
                    connectivity::compute_epoch(channels, labels, a, b, rate, options);
                let el = epoch_labels
                    .as_ref()
                    .and_then(|v| v.get(epoch))
                    .cloned();
                (0..channels.len()).map(move |channel| {
                    let signal = &channels[channel];
                    let slice = &signal[a..b];
                    let mut values = features(slice, rate, options);
                    values.extend_from_slice(&connectivity[channel]);
                    Row {
                        values,
                        channel: labels[channel].clone(),
                        epoch: epoch + 1,
                        bin: gi,
                        start,
                        end,
                        epoch_label: el.clone(),
                    }
                })
            })
            .collect();
        all.extend(rows);
    }
    write_csv(
        &job.output,
        &columns,
        &all,
        basename,
        parts.get(0).copied().unwrap_or("NA"),
        parts.get(1).copied().unwrap_or("NA"),
        parts.get(2).copied().unwrap_or("NA"),
        &job.options.mode,
    )?;
    eprintln!("PROGRESS 100 Complete");
    Ok(())
}

fn groups(o: &Options, n: usize, len: f64) -> Result<Vec<(usize, usize, f64, f64)>, String> {
    let total = n as f64 * len;
    match o.mode.as_str() {
        "interval" => {
            let a = (o.start_seconds.max(0.0) / len).floor() as usize;
            let b = (o.end_seconds.min(total) / len).ceil() as usize;
            if a >= b || a >= n {
                Err("invalid interval".into())
            } else {
                Ok(vec![(a, b.min(n), a as f64 * len, b.min(n) as f64 * len)])
            }
        }
        "bins" => {
            let per = (o.bin_seconds / len).floor() as usize;
            if per == 0 {
                return Err("bin is shorter than an epoch".into());
            };
            let count = n / per;
            if count == 0 {
                return Err("recording is shorter than one bin".into());
            };
            Ok((0..count)
                .map(|i| {
                    let a = i * per;
                    let b = a + per;
                    (a, b, a as f64 * len, b as f64 * len)
                })
                .collect())
        }
        "middleTwoMinutes" => {
            let take = n.min((120.0 / len).round() as usize);
            let a = (n - take) / 2;
            Ok(vec![(a, a + take, a as f64 * len, (a + take) as f64 * len)])
        }
        _ => Ok(vec![(0, n, 0.0, total)]),
    }
}

fn features(x: &[f32], rate: f64, o: &Options) -> Vec<f64> {
    let signal: Vec<f64> = x.iter().map(|value| *value as f64).collect();
    let mut out = Vec::new();
    if o.psd {
        let values = features::bandpowers(&signal, rate);
        out.extend(BANDS.iter().map(|band| values[&format!("{}_PSD", band.2)]));
    }
    if o.fooof {
        let values = spectral::fooof_features(&signal, rate);
        out.extend(
            BANDS
                .iter()
                .map(|band| values[&format!("{}_FOOOF", band.2)]),
        );
        out.extend([
            values["offset_FOOOF"],
            values["exponent_FOOOF"],
            values["cf_0_FOOOF"],
            values["pw_0_FOOOF"],
            values["bw_0_FOOOF"],
            values["cf_1_FOOOF"],
            values["pw_1_FOOOF"],
            values["bw_1_FOOOF"],
            values["error_FOOOF"],
            values["r_squared_FOOOF"],
            values["auc_FOOOF"],
            values["oscspectraledge_FOOOF"],
        ]);
    }
    if o.irasa {
        let values = spectral::irasa_features(&signal, rate);
        out.extend(
            BANDS
                .iter()
                .map(|band| values[&format!("{}_Irasa", band.2)]),
        );
        out.extend([
            values["intercept_Irasa"],
            values["slope_Irasa"],
            values["rsquared_Irasa"],
            values["auc_Irasa"],
            values["oscspectraledge_Irasa"],
        ]);
    }
    if o.nonlinear {
        let values = nonlinear::all(&signal);
        out.extend([
            values["perm_entropy_nonlinear"],
            values["svd_entropy_nonlinear"],
            values["sample_entropy_nonlinear"],
            values["dfa_nonlinear"],
            values["petrosian_nonlinear"],
            values["katz_nonlinear"],
            values["higuchi_nonlinear"],
            values["lziv_nonlinear"],
        ]);
    }
    if o.acw {
        out.push(features::acw50(&signal, rate));
    }
    out
}

fn columns(o: &Options) -> Vec<String> {
    let mut c = Vec::new();
    if o.psd {
        c.extend(BANDS.iter().map(|b| format!("{}_PSD", b.2)));
    }
    if o.fooof {
        c.extend(BANDS.iter().map(|b| format!("{}_FOOOF", b.2)));
        c.extend(
            [
                "offset_FOOOF",
                "exponent_FOOOF",
                "cf_0_FOOOF",
                "pw_0_FOOOF",
                "bw_0_FOOOF",
                "cf_1_FOOOF",
                "pw_1_FOOOF",
                "bw_1_FOOOF",
                "error_FOOOF",
                "r_squared_FOOOF",
                "auc_FOOOF",
                "oscspectraledge_FOOOF",
            ]
            .map(str::to_string),
        );
    }
    if o.irasa {
        c.extend(BANDS.iter().map(|b| format!("{}_Irasa", b.2)));
        c.extend(
            [
                "intercept_Irasa",
                "slope_Irasa",
                "rsquared_Irasa",
                "auc_Irasa",
                "oscspectraledge_Irasa",
            ]
            .map(str::to_string),
        );
    }
    if o.nonlinear {
        c.extend(
            [
                "perm_entropy_nonlinear",
                "svd_entropy_nonlinear",
                "sample_entropy_nonlinear",
                "dfa_nonlinear",
                "petrosian_nonlinear",
                "katz_nonlinear",
                "higuchi_nonlinear",
                "lziv_nonlinear",
            ]
            .map(str::to_string),
        );
    }
    if o.acw {
        c.push("ACW".into());
    }
    if o.connectivity {
        c.extend(connectivity::column_names(o));
    }
    c
}

fn default_extract_job() -> String {
    "extract".into()
}
fn default_preprocessing() -> preprocessing::PreprocessOptions {
    serde_json::from_value(serde_json::json!({})).expect("default preprocessing")
}



/// Drops auxiliary channels and re-references the remainder to the common
/// average.
///
/// When `non_eeg` is non-empty it is treated as authoritative: the UI has
/// already auto-detected and (possibly) had the user override the channel
/// types, so the engine drops exactly those labels.  Only when the list is
/// empty — e.g. a job authored outside the GUI — do we fall back to the
/// built-in name heuristics.
///
/// Note the ordering: channels are removed *before* the average is computed,
/// so ECG/EOG/GSR never leak into the reference.
fn remove_non_eeg_and_reference(recording: &mut Recording, non_eeg: &[String]) {
    let keep: Vec<usize> = if non_eeg.is_empty() {
        const EXCLUDED: [&str; 8] = [
            "GSR", "ECG", "EOG", "EMG", "RESP", "X_DIR", "Y_DIR", "Z_DIR",
        ];
        recording
            .labels
            .iter()
            .enumerate()
            .filter(|(_, label)| {
                let upper = label.to_uppercase();
                !EXCLUDED.iter().any(|name| upper.contains(name))
            })
            .map(|(index, _)| index)
            .collect()
    } else {
        let drop: std::collections::HashSet<String> =
            non_eeg.iter().map(|l| l.trim().to_uppercase()).collect();
        recording
            .labels
            .iter()
            .enumerate()
            .filter(|(_, label)| !drop.contains(&label.trim().to_uppercase()))
            .map(|(index, _)| index)
            .collect()
    };
    if !keep.is_empty() && keep.len() != recording.channels.len() {
        recording.labels = keep.iter().map(|i| recording.labels[*i].clone()).collect();
        recording.channels = keep
            .iter()
            .map(|i| recording.channels[*i].clone())
            .collect();
    }
    if recording.channels.len() < 2 {
        return;
    }
    for sample in 0..recording.channels[0].len() {
        let mean = recording
            .channels
            .iter()
            .map(|channel| channel[sample] as f64)
            .sum::<f64>()
            / recording.channels.len() as f64;
        for channel in &mut recording.channels {
            channel[sample] -= mean as f32;
        }
    }
}

fn apply_channel_selection(recording: &mut Recording, selected: Option<&[String]>) {
    let Some(selected) = selected else {
        return;
    };
    if selected.is_empty() {
        return;
    }
    let keep: Vec<usize> = recording
        .labels
        .iter()
        .enumerate()
        .filter(|(_, label)| selected.iter().any(|s| s == *label))
        .map(|(i, _)| i)
        .collect();
    if keep.is_empty() {
        return;
    }
    recording.labels = keep.iter().map(|i| recording.labels[*i].clone()).collect();
    recording.channels = keep.iter().map(|i| recording.channels[*i].clone()).collect();
}

fn apply_interval_selection(
    recording: &mut Recording,
    accepted: Option<&[[f64; 2]]>,
    rejected: Option<&[[f64; 2]]>,
) {
    let n = recording.channels.first().map(Vec::len).unwrap_or(0);
    if n == 0 {
        return;
    }
    let mut mask = vec![accepted.map(|x| !x.is_empty()).unwrap_or(false) == false; n];
    if let Some(accepted) = accepted {
        if !accepted.is_empty() {
            mask.fill(false);
            for interval in accepted {
                mark_interval(&mut mask, recording.rate, interval, true);
            }
        }
    }
    if let Some(rejected) = rejected {
        for interval in rejected {
            mark_interval(&mut mask, recording.rate, interval, false);
        }
    }
    if mask.iter().all(|x| *x) {
        return;
    }
    let kept = mask.iter().filter(|x| **x).count();
    if kept < 4 {
        return;
    }
    for ch in &mut recording.channels {
        let mut out = Vec::with_capacity(kept);
        for (sample, keep) in ch.iter().zip(&mask) {
            if *keep {
                out.push(*sample);
            }
        }
        *ch = out;
    }
    recording.source_epoch_samples = None;
}

fn mark_interval(mask: &mut [bool], rate: f64, interval: &[f64; 2], value: bool) {
    let a = (interval[0].min(interval[1]).max(0.0) * rate).floor() as usize;
    let b = (interval[0].max(interval[1]).max(0.0) * rate).ceil() as usize;
    let len = mask.len();
    for item in mask.iter_mut().take(b.min(len)).skip(a.min(len)) {
        *item = value;
    }
}
fn load_fdt(j: &Job) -> Result<Recording, String> {
    let rate = j.sample_rate.ok_or("SET sample rate missing")?;
    let labels = j.labels.clone().ok_or("SET labels missing")?;
    let n = j.sample_count.ok_or("SET sample count missing")?;
    let path = j.data_path.as_ref().ok_or("SET data path missing")?;
    let bytes = fs::read(path).map_err(err)?;
    let need = n * labels.len() * 4;
    if bytes.len() < need {
        return Err(format!("FDT truncated: {} < {}", bytes.len(), need));
    }
    let mut ch = vec![vec![0.0; n]; labels.len()];
    for s in 0..n {
        for c in 0..labels.len() {
            let i = (s * labels.len() + c) * 4;
            ch[c][s] = f32::from_le_bytes(bytes[i..i + 4].try_into().unwrap())
        }
    }
    Ok(Recording {
        rate,
        labels,
        channels: ch,
        source_epoch_samples: j.points_per_epoch,
        epoch_labels: None,
    })
}

fn load_edf(path: &Path) -> Result<Recording, String> {
    let b = fs::read(path).map_err(err)?;
    if b.len() < 256 {
        return Err("EDF header too short".into());
    }
    let text = |o: usize, n: usize| String::from_utf8_lossy(&b[o..o + n]).trim().to_string();
    let hb: text_parse::Int = text(184, 8).parse().map_err(err)?;
    let records: i32 = text(236, 8).parse().unwrap_or(-1);
    let secs: f64 = text(244, 8).replace(',', ".").parse().map_err(err)?;
    let ns: usize = text(252, 4).parse().map_err(err)?;
    let mut o = 256;
    let fields = |o: usize, w: usize| -> Vec<String> {
        (0..ns)
            .map(|i| {
                String::from_utf8_lossy(&b[o + i * w..o + (i + 1) * w])
                    .trim()
                    .to_string()
            })
            .collect()
    };
    let labels = fields(o, 16);
    o += ns * 16;
    o += ns * 80;
    let dims = fields(o, 8);
    o += ns * 8;
    let nums = |o: usize| -> Vec<f64> {
        fields(o, 8)
            .iter()
            .map(|x| x.replace(',', ".").parse().unwrap_or(0.0))
            .collect()
    };
    let pmin = nums(o);
    o += ns * 8;
    let pmax = nums(o);
    o += ns * 8;
    let dmin = nums(o);
    o += ns * 8;
    let dmax = nums(o);
    o += ns * 8;
    o += ns * 80;
    let spr: Vec<usize> = fields(o, 8)
        .iter()
        .map(|x| x.parse().unwrap_or(0))
        .collect();
    let per: usize = spr.iter().sum();
    let rec = if records > 0 {
        records as usize
    } else {
        (b.len() - hb) / (2 * per)
    };
    let keep: Vec<usize> = (0..ns)
        .filter(|i| {
            spr[*i] > 0
                && !labels[*i].to_lowercase().contains("annotation")
                && !labels[*i].to_lowercase().contains("status")
        })
        .collect();
    let first = keep.first().ok_or("EDF has no signals")?;
    let rate = spr[*first] as f64 / secs;
    let mut out: Vec<Vec<f32>> = keep.iter().map(|i| vec![0.0; rec * spr[*i]]).collect();
    let mut cursor = hb;
    for r in 0..rec {
        for c in 0..ns {
            let gain = (pmax[c] - pmin[c]) / (dmax[c] - dmin[c]);
            for s in 0..spr[c] {
                let d = i16::from_le_bytes([b[cursor], b[cursor + 1]]) as f64;
                cursor += 2;
                if let Some(k) = keep.iter().position(|i| *i == c) {
                    let mut v = d * gain + pmin[c] - gain * dmin[c];
                    if dims[c].eq_ignore_ascii_case("v") {
                        v *= 1e6
                    }
                    out[k][r * spr[c] + s] = v as f32
                }
            }
        }
    }
    let min = out.iter().map(Vec::len).min().unwrap();
    for x in &mut out {
        x.truncate(min)
    }
    Ok(Recording {
        rate,
        labels: keep.iter().map(|i| labels[*i].clone()).collect(),
        channels: out,
        source_epoch_samples: None,
        epoch_labels: None,
    })
}
mod text_parse {
    pub type Int = usize;
}

fn write_csv(
    path: &str,
    cols: &[String],
    rows: &[Row],
    file: &str,
    sub: &str,
    sess: &str,
    cond: &str,
    mode: &str,
) -> Result<(), String> {
    let mut w = fs::File::create(path).map_err(err)?;
    let mut h = cols.to_vec();
    h.extend(
        [
            "Chan",
            "Epoch",
            "epoch_label",
            "filename",
            "subjid",
            "sessn",
            "condn",
            "bin_idx",
            "bin_start_s",
            "bin_end_s",
            "mode",
        ]
        .map(str::to_string),
    );
    writeln!(w, "{}", h.join(",")).map_err(err)?;
    for r in rows {
        let mut v: Vec<String> = r
            .values
            .iter()
            .map(|x| {
                if x.is_finite() {
                    format!("{x:.10}")
                } else {
                    String::new()
                }
            })
            .collect();
        v.extend([
            csv(&r.channel),
            r.epoch.to_string(),
            csv(r.epoch_label.as_deref().unwrap_or("NA")),
            csv(file),
            csv(sub),
            csv(sess),
            csv(cond),
            r.bin.to_string(),
            format!("{:.3}", r.start),
            format!("{:.3}", r.end),
            mode.into(),
        ]);
        writeln!(w, "{}", v.join(",")).map_err(err)?
    }
    Ok(())
}
fn csv(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.into()
    }
}
fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sine_is_alpha() {
        let rate = 100.0;
        let x: Vec<f64> = (0..1000)
            .map(|i| (2.0 * std::f64::consts::PI * 10.0 * i as f64 / rate).sin())
            .collect();
        let powers = features::bandpowers(&x, rate);
        assert!(powers["Alpha_PSD"] > powers["Delta_PSD"]);
        assert!(features::acw50(&x, rate) > 0.0)
    }
    #[test]
    fn modes_validate() {
        let o = Options {
            mode: "bins".into(),
            start_seconds: 0.0,
            end_seconds: 10.0,
            bin_seconds: 4.0,
            psd: true,
            fooof: false,
            irasa: false,
            nonlinear: false,
            acw: false,
            connectivity: false,
            mic: false,
            mim: false,
            gc: false,
            gc_tr: false,
            coh: false,
            plv: false,
            ciplv: false,
            pli: false,
            wpli: false,
            remove_non_eeg: true,
            non_eeg_channels: Vec::new(),
        };
        assert_eq!(groups(&o, 5, 2.0).unwrap().len(), 2)
    }

    fn recording_with(labels: &[&str]) -> Recording {
        Recording {
            rate: 100.0,
            labels: labels.iter().map(|s| s.to_string()).collect(),
            // Distinct constant per channel so the average reference is easy
            // to reason about.
            channels: (0..labels.len())
                .map(|i| vec![(i as f32) + 1.0; 8])
                .collect(),
            source_epoch_samples: None,
            epoch_labels: None,
        }
    }

    #[test]
    fn explicit_non_eeg_list_is_authoritative() {
        // "FT9" contains no aux token, but the built-in heuristic is substring
        // based and this test pins that the explicit list is what governs.
        let mut rec = recording_with(&["Fp1", "FT9", "Cz", "ECG", "GSR"]);
        let non_eeg = vec!["ECG".to_string(), "GSR".to_string()];
        remove_non_eeg_and_reference(&mut rec, &non_eeg);
        assert_eq!(rec.labels, vec!["Fp1", "FT9", "Cz"]);
        assert_eq!(rec.channels.len(), 3);
    }

    #[test]
    fn explicit_list_matches_case_insensitively() {
        let mut rec = recording_with(&["Fp1", "ecg", "Cz"]);
        remove_non_eeg_and_reference(&mut rec, &["ECG".to_string()]);
        assert_eq!(rec.labels, vec!["Fp1", "Cz"]);
    }

    #[test]
    fn explicit_list_can_keep_a_channel_the_heuristic_would_drop() {
        // User overrode "EOG1" back to EEG: passing an empty-of-it list must
        // keep it, even though the built-in heuristic contains "EOG".
        let mut rec = recording_with(&["Fp1", "EOG1", "Cz"]);
        remove_non_eeg_and_reference(&mut rec, &["SomethingElse".to_string()]);
        assert_eq!(rec.labels, vec!["Fp1", "EOG1", "Cz"]);
    }

    #[test]
    fn empty_list_falls_back_to_heuristic() {
        let mut rec = recording_with(&["Fp1", "ECG", "GSR", "Cz"]);
        remove_non_eeg_and_reference(&mut rec, &[]);
        assert_eq!(rec.labels, vec!["Fp1", "Cz"]);
    }

    #[test]
    fn aux_channels_are_excluded_from_the_average_reference() {
        // Two EEG channels at 1.0 and 2.0 plus a huge aux channel. If the aux
        // channel leaked into the mean, the EEG values would be dragged far
        // from their true ±0.5 deviation about their own average.
        let mut rec = Recording {
            rate: 100.0,
            labels: vec!["Fp1".into(), "Cz".into(), "ECG".into()],
            channels: vec![vec![1.0; 4], vec![2.0; 4], vec![1000.0; 4]],
            source_epoch_samples: None,
            epoch_labels: None,
        };
        remove_non_eeg_and_reference(&mut rec, &["ECG".to_string()]);
        assert_eq!(rec.labels, vec!["Fp1", "Cz"]);
        assert!((rec.channels[0][0] - (-0.5)).abs() < 1e-5);
        assert!((rec.channels[1][0] - 0.5).abs() < 1e-5);
    }

    #[test]
    fn never_removes_every_channel() {
        // A misconfigured list must not leave the recording empty.
        let mut rec = recording_with(&["Fp1", "Cz"]);
        remove_non_eeg_and_reference(
            &mut rec,
            &["Fp1".to_string(), "Cz".to_string()],
        );
        assert_eq!(rec.labels.len(), 2);
    }
}
