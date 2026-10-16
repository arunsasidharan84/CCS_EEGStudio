//! Guided ERP analysis: ERP CORE presets are suggestions, never inferred evidence
//! that preprocessing, behavioral exclusions or timing correction already occurred.
use crate::{erp_math as math, Recording};
use nalgebra::DMatrix;
use rand::{rngs::StdRng, Rng, SeedableRng};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    path::{Path, PathBuf},
};
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub label: String,
    pub onset: f64,
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub index: usize,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub task: String,
    #[serde(default)]
    pub component_name: String,
    pub a_name: String,
    pub b_name: String,
    pub a_codes: Vec<String>,
    pub b_codes: Vec<String>,
    pub roi: Vec<String>,
    pub epoch: [f64; 2],
    pub baseline: [f64; 2],
    pub window: [f64; 2],
    pub polarity: f64,
    pub lateralized: bool,
}
fn codes(x: &[i32]) -> Vec<String> {
    x.iter().map(|v| v.to_string()).collect()
}
pub fn profile(task: &str) -> Result<Profile, String> {
    let mut p = Profile {
        task: task.into(),
        component_name: task.into(),
        a_name: "A".into(),
        b_name: "B".into(),
        a_codes: Vec::new(),
        b_codes: Vec::new(),
        roi: vec!["Fz".into()],
        epoch: [-0.2, 0.8],
        baseline: [-0.2, 0.],
        window: [0.1, 0.2],
        polarity: -1.,
        lateralized: false,
    };
    match task {
        "MMN" => {
            p.a_name = "Standard".into();
            p.b_name = "Deviant".into();
            p.a_codes = codes(&[80]);
            p.b_codes = codes(&[70]);
            p.roi = vec!["FCz".into()];
            p.epoch = [-0.2, 0.5];
            p.window = [0.125, 0.225];
        }
        "N170" => {
            p.a_name = "Car".into();
            p.b_name = "Face".into();
            p.a_codes = codes(&(41..=80).collect::<Vec<_>>());
            p.b_codes = codes(&(1..=40).collect::<Vec<_>>());
            p.roi = vec!["PO7".into(), "PO8".into()];
            p.window = [0.11, 0.17];
        }
        "N400" => {
            p.a_name = "Related target".into();
            p.b_name = "Unrelated target".into();
            p.a_codes = codes(&[211, 212]);
            p.b_codes = codes(&[221, 222]);
            p.roi = vec!["Cz".into()];
            p.window = [0.3, 0.5];
        }
        "P3" => {
            p.a_name = "Non-target".into();
            p.b_name = "Target".into();
            p.a_codes = codes(
                &(1..=5)
                    .flat_map(|a| (1..=5).filter(move |&b| b != a).map(move |b| 10 * a + b))
                    .collect::<Vec<_>>(),
            );
            p.b_codes = codes(&[11, 22, 33, 44, 55]);
            p.roi = vec!["Pz".into()];
            p.window = [0.3, 0.6];
            p.polarity = 1.;
        }
        "N2pc" => {
            p.a_name = "Left target".into();
            p.b_name = "Right target".into();
            p.a_codes = codes(&[111, 112, 211, 212]);
            p.b_codes = codes(&[121, 122, 221, 222]);
            p.roi = vec!["PO7".into(), "PO8".into()];
            p.window = [0.2, 0.275];
            p.lateralized = true;
        }
        "LRP" => {
            p.a_name = "Left-hand correct response".into();
            p.b_name = "Right-hand correct response".into();
            p.a_codes = codes(&[111, 121]);
            p.b_codes = codes(&[212, 222]);
            p.roi = vec!["C3".into(), "C4".into()];
            p.epoch = [-0.8, 0.2];
            p.baseline = [-0.8, -0.6];
            p.window = [-0.1, 0.];
            p.lateralized = true;
        }
        "ERN" => {
            p.a_name = "Correct response".into();
            p.b_name = "Error response".into();
            p.a_codes = codes(&[111, 121, 212, 222]);
            p.b_codes = codes(&[112, 122, 211, 221]);
            p.roi = vec!["FCz".into()];
            p.epoch = [-0.6, 0.4];
            p.baseline = [-0.4, -0.2];
            p.window = [0., 0.1];
        }
        "Custom" => {}
        _ => return Err(format!("Unknown ERP task {task}")),
    };
    Ok(p)
}
fn normalized(s: &str) -> String {
    let s = s.trim().rsplit('/').next().unwrap_or(s).trim();
    let tail = s.trim_start_matches(|c: char| c.is_ascii_alphabetic() || c.is_whitespace());
    tail.parse::<i32>()
        .map(|n| n.to_string())
        .unwrap_or_else(|_| s.to_lowercase())
}
fn code(e: &Event) -> i32 {
    normalized(&e.label).parse().unwrap_or(-1)
}
pub fn detect_task(path: &str) -> Option<String> {
    for part in path.rsplit(['/', '\\']) {
        for token in part.split(|c: char| !c.is_ascii_alphanumeric()) {
            let upper = token.to_uppercase();
            let name = match upper.as_str() {
                "N170" => "N170",
                "N2PC" => "N2pc",
                "N400" => "N400",
                "MMN" => "MMN",
                "ERN" => "ERN",
                "LRP" => "LRP",
                "P3" | "P300" => "P3",
                _ => continue,
            };
            return Some(name.into());
        }
    }
    None
}

fn participant(path: &str) -> String {
    let stem = Path::new(path)
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy();
    if let Some(s) = stem.split('_').find(|s| s.starts_with("sub-")) {
        return s.trim_start_matches("sub-").to_string();
    }
    stem.split('_').next().unwrap_or("unknown").to_string()
}
fn csv_row(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut x = String::new();
    let mut quote = false;
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            '"' => {
                if quote && it.peek() == Some(&'"') {
                    x.push('"');
                    it.next();
                } else {
                    quote = !quote;
                }
            }
            ',' if !quote => out.push(std::mem::take(&mut x)),
            _ => x.push(c),
        }
    }
    out.push(x);
    out
}
fn csv(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.into()
    }
}
pub fn read_events(path: &Path) -> Result<(Vec<Event>, String), String> {
    let sidecar = path.with_extension("evt");
    if sidecar.exists() {
        let text = fs::read_to_string(&sidecar).map_err(|e| e.to_string())?;
        let mut lines = text.lines();
        let header: Vec<_> = lines
            .next()
            .unwrap_or("")
            .split('\t')
            .map(|s| s.trim().to_lowercase())
            .collect();
        let label = header
            .iter()
            .position(|s| s == "type")
            .ok_or("EVT sidecar needs type and latency columns")?;
        let onset = header
            .iter()
            .position(|s| s == "latency")
            .ok_or("EVT sidecar needs latency in seconds")?;
        let dur = header.iter().position(|s| s == "duration");
        let mut events = Vec::new();
        for (i, line) in lines.enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let row: Vec<_> = line.split('\t').collect();
            let value = row
                .get(onset)
                .and_then(|v| v.parse::<f64>().ok())
                .filter(|v| v.is_finite() && *v >= 0.)
                .ok_or("Invalid EVT latency; seconds are required")?;
            events.push(Event {
                label: row.get(label).ok_or("Truncated EVT row")?.to_string(),
                onset: value,
                duration: dur
                    .and_then(|d| row.get(d))
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0.),
                index: i + 1,
            });
        }
        events.sort_by(|a, b| a.onset.total_cmp(&b.onset));
        return Ok((events, "EEGLAB .evt (seconds)".into()));
    }
    if path.extension().and_then(|s| s.to_str()) == Some("json") {
        let mut v: Value = serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        if v["markers"].as_array().is_none_or(|a| a.is_empty()) {
            let sidecar = PathBuf::from(format!("{}.preprocessing.json", path.display()));
            if let Ok(bytes) = fs::read(sidecar) {
                if let Ok(side) = serde_json::from_slice::<Value>(&bytes) {
                    if side["timeline_preserved"] == true && side["markers"].is_array() {
                        v["markers"] = side["markers"].clone();
                    }
                }
            }
        }
        let mut events: Vec<Event> = v["markers"]
            .as_array()
            .ok_or("Portable input has no markers; use the legacy epoched view for epoch labels")?
            .iter()
            .enumerate()
            .map(|(i, m)| Event {
                label: m["description"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .or(m["type"].as_str())
                    .unwrap_or("")
                    .into(),
                onset: m["start_seconds"].as_f64().unwrap_or(-1.),
                duration: m["duration_seconds"].as_f64().unwrap_or(0.),
                index: i + 1,
            })
            .collect();
        if events.iter().any(|e| {
            !e.onset.is_finite() || e.onset < 0. || !e.duration.is_finite() || e.duration < 0.
        }) {
            return Err(
                "Portable event onsets/durations must be finite nonnegative seconds".into(),
            );
        }
        events.sort_by(|a, b| a.onset.total_cmp(&b.onset));
        return Ok((events, "Portable markers".into()));
    }
    read_edf_events(path)
}
/// EDF+ TALs or calibrated integer Status transitions; sidecar takes precedence.
pub fn read_edf_events(path: &Path) -> Result<(Vec<Event>, String), String> {
    let b = fs::read(path).map_err(|e| e.to_string())?;
    if b.len() < 256 {
        return Err("Truncated EDF".into());
    }
    let field = |o: usize, n: usize| String::from_utf8_lossy(&b[o..o + n]).trim().to_string();
    let n: usize = field(252, 4).parse().map_err(|_| "Invalid EDF channels")?;
    let hb: usize = field(184, 8).parse().map_err(|_| "Invalid EDF header")?;
    let secs: f64 = field(244, 8)
        .parse()
        .map_err(|_| "Invalid EDF record duration")?;
    if hb > b.len() || hb < 256 + n * 256 || secs <= 0. {
        return Err("Invalid EDF header length".into());
    }
    let labels: Vec<_> = (0..n).map(|i| field(256 + i * 16, 16)).collect();
    let spr: Vec<usize> = (0..n)
        .map(|i| field(256 + n * 216 + i * 8, 8).parse().unwrap_or(0))
        .collect();
    let total: usize = spr.iter().sum();
    if total == 0 {
        return Err("EDF has no samples".into());
    }
    let rec = (b.len() - hb) / (2 * total);
    let mut events = Vec::new();
    let mut status_events = Vec::new();
    let mut cursor = hb;
    let mut previous = 0i32;
    let status = labels
        .iter()
        .position(|l| l.eq_ignore_ascii_case("status") || l.eq_ignore_ascii_case("trigger"));
    for r in 0..rec {
        for c in 0..n {
            let len = spr[c] * 2;
            if cursor + len > b.len() {
                return Err("Truncated EDF data".into());
            }
            if labels[c].to_lowercase().contains("annotation") {
                for tal in b[cursor..cursor + len].split(|v| *v == 0) {
                    let mut parts = tal.split(|v| *v == 20);
                    let timing = parts.next().unwrap_or(&[]);
                    let timing: Vec<_> = timing.split(|v| *v == 21).collect();
                    if let Ok(t) = String::from_utf8_lossy(timing[0]).parse::<f64>() {
                        let duration = timing
                            .get(1)
                            .and_then(|v| String::from_utf8_lossy(v).parse().ok())
                            .unwrap_or(0.);
                        for text in parts {
                            if !text.is_empty() {
                                events.push(Event {
                                    label: String::from_utf8_lossy(text).into(),
                                    onset: t,
                                    duration,
                                    index: events.len() + 1,
                                });
                            }
                        }
                    }
                }
            } else if Some(c) == status {
                let number = |offset| {
                    field(256 + n * offset + c * 8, 8)
                        .parse::<f64>()
                        .unwrap_or(0.)
                };
                let (lo, hi, dlo, dhi) = (number(104), number(112), number(120), number(128));
                if dhi == dlo {
                    return Err("Invalid Status channel calibration".into());
                }
                for i in 0..spr[c] {
                    let raw = i16::from_le_bytes([b[cursor + 2 * i], b[cursor + 2 * i + 1]]) as f64;
                    let v = ((raw - dlo) * (hi - lo) / (dhi - dlo) + lo).round() as i32;
                    if v != 0 && v != previous {
                        status_events.push(Event {
                            label: v.to_string(),
                            onset: r as f64 * secs + i as f64 * secs / spr[c] as f64,
                            duration: 0.,
                            index: status_events.len() + 1,
                        });
                    }
                    previous = v;
                }
            }
            cursor += len;
        }
    }
    let annotations_used = !events.is_empty();
    if events.is_empty() {
        events = status_events;
    }
    if events.is_empty() {
        return Err("No annotation/Status events or .evt sidecar found".into());
    }
    events.sort_by(|a, b| a.onset.total_cmp(&b.onset));
    Ok((
        events,
        if annotations_used {
            "EDF+ annotations"
        } else {
            "EDF calibrated Status transitions"
        }
        .into(),
    ))
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Options {
    pub task: String,
    pub event_source: String,
    pub correct_only: bool,
    pub response_min: f64,
    pub response_max: f64,
    pub reject_uv: f64,
    pub bin_ms: f64,
    pub permutations: usize,
    pub seed: u64,
    pub regression: bool,
    pub deconvolution: bool,
    pub decoding: bool,
    pub temporal_generalization: bool,
    pub folds: usize,
    pub profile_override: Option<Profile>,
    pub profile_overrides: BTreeMap<String, Profile>,
    pub regroup_epochs: bool,
    pub lsqr_tolerance: f64,
    pub lsqr_iterations: usize,
    pub trial_metadata_path: String,
    pub decode_shrinkage: f64,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            task: "Auto".into(),
            event_source: "auto".into(),
            correct_only: true,
            response_min: 0.2,
            response_max: 1.0,
            reject_uv: 0.,
            bin_ms: 20.,
            permutations: 1000,
            seed: 42,
            regression: false,
            deconvolution: false,
            decoding: false,
            temporal_generalization: false,
            folds: 5,
            profile_override: None,
            profile_overrides: BTreeMap::new(),
            regroup_epochs: false,
            lsqr_tolerance: 1e-12,
            lsqr_iterations: 1000,
            trial_metadata_path: String::new(),
            decode_shrinkage: 0.1,
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Input {
    pub path: String,
    #[serde(default)]
    pub subject: String,
}
#[derive(Deserialize)]
pub struct Job {
    pub inputs: Vec<Input>,
    pub output: String,
    #[serde(default)]
    pub options: Options,
}
fn input_profile(path: &str, o: &Options) -> Result<Profile, String> {
    if let Some(p) = &o.profile_override {
        return Ok(p.clone());
    }
    let task = if o.task == "Auto" {
        detect_task(path)
            .ok_or("Choose an ERP task: filename does not identify a unique paradigm")?
    } else {
        o.task.clone()
    };
    o.profile_overrides
        .get(&task)
        .cloned()
        .map(Ok)
        .unwrap_or_else(|| profile(&task))
}
fn validate(o: &Options, p: &Profile) -> Result<(), String> {
    if !o.bin_ms.is_finite()
        || o.bin_ms < 1.
        || o.bin_ms > 100.
        || o.permutations < 1
        || o.permutations > 100000
        || !o.lsqr_tolerance.is_finite()
        || o.lsqr_tolerance <= 0.0
        || o.lsqr_tolerance > 0.01
        || o.lsqr_iterations < 1
        || o.lsqr_iterations > 10000
        || o.folds < 2
        || o.folds > 20
        || !o.decode_shrinkage.is_finite()
        || !(0.0..=1.0).contains(&o.decode_shrinkage)
        || !o.reject_uv.is_finite()
        || o.reject_uv < 0.
        || o.response_min < 0.
        || o.response_min >= o.response_max
    {
        return Err(
            "Invalid ERP bin width, permutations, folds, amplitude threshold, or response window"
                .into(),
        );
    }
    if p.epoch[0] >= p.epoch[1]
        || p.baseline[0] < p.epoch[0]
        || p.baseline[1] > p.epoch[1]
        || p.baseline[0] >= p.baseline[1]
        || p.window[0] < p.epoch[0]
        || p.window[1] > p.epoch[1]
        || p.window[0] >= p.window[1]
        || p.a_codes.is_empty()
        || p.b_codes.is_empty()
        || p.a_codes
            .iter()
            .any(|a| p.b_codes.iter().any(|b| normalized(a) == normalized(b)))
    {
        return Err("Review event classes and epoch, baseline, measurement windows; event classes must not overlap".into());
    }
    Ok(())
}
fn selected_events(path: &Path, o: &Options) -> Result<(Vec<Event>, String), String> {
    match o.event_source.as_str() {
        "auto" => read_events(path),
        "native" => read_edf_events(path),
        "sidecar" => {
            if !path.with_extension("evt").exists() {
                return Err("Selected .evt source is missing".into());
            }
            read_events(path)
        }
        _ => Err("Unknown event source".into()),
    }
}
fn timing_audit(path: &str, _events: &[Event]) -> Option<Value> {
    if !path.to_lowercase().ends_with(".edf") || !Path::new(path).with_extension("evt").exists() {
        return None;
    }
    let (events, _) = read_events(Path::new(path)).ok()?;
    let (native, source) = read_edf_events(Path::new(path)).ok()?;
    let same = events.len() == native.len()
        && events
            .iter()
            .zip(&native)
            .all(|(a, b)| normalized(&a.label) == normalized(&b.label));
    if !same {
        return Some(
            json!({"sequence_match":false,"native_source":source,"native_events":native.len()}),
        );
    }
    let mut deltas: Vec<_> = events
        .iter()
        .zip(&native)
        .map(|(a, b)| (a.onset - b.onset) * 1000.)
        .collect();
    deltas.sort_by(|a, b| a.total_cmp(b));
    Some(
        json!({"sequence_match":true,"native_source":source,"median_delta_ms":deltas[deltas.len()/2],"max_abs_delta_ms":deltas.iter().map(|v|v.abs()).fold(0.,f64::max),"note":"Sidecar minus native event time; no automatic adjustment is applied"}),
    )
}
fn epoch_metadata(path: &str) -> Option<Value> {
    if !path.to_lowercase().ends_with(".json") {
        return None;
    }
    let value: Value = serde_json::from_slice(&fs::read(path).ok()?).ok()?;
    if value["source_epoch_samples"].as_u64().unwrap_or(0) == 0 {
        return None;
    }
    Some(value)
}
fn original_epoch_codes(path: &str, meta: &Value) -> BTreeMap<usize, String> {
    let sidecar: Value = fs::read(format!("{}.preprocessing.json", path))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null);
    let markers = meta["markers"]
        .as_array()
        .or_else(|| sidecar["markers"].as_array());
    let zero = -meta["epoch_tmin"].as_f64().unwrap_or(0.);
    let tolerance = 2. / meta["sample_rate"].as_f64().unwrap_or(250.);
    let mut best: BTreeMap<usize, (f64, String)> = BTreeMap::new();
    for marker in markers.into_iter().flatten() {
        let Some(index) = marker["epoch_index"].as_u64() else {
            continue;
        };
        let Some(t) = marker["start_seconds"].as_f64() else {
            continue;
        };
        let delta = (t - zero).abs();
        if delta <= tolerance && best.get(&(index as usize)).is_none_or(|(d, _)| delta < *d) {
            best.insert(
                index as usize,
                (delta, marker["description"].as_str().unwrap_or("").into()),
            );
        }
    }
    best.into_iter().map(|(i, (_, s))| (i, s)).collect()
}
fn regrouped_label(code: Option<&String>, task: &str) -> Option<String> {
    let p = profile(task).ok()?;
    let code = normalized(code?);
    if p.a_codes.iter().any(|c| normalized(c) == code) {
        Some(p.a_name)
    } else if p.b_codes.iter().any(|c| normalized(c) == code) {
        Some(p.b_name)
    } else {
        None
    }
}
fn prepared_profile(path: &str, o: &Options, meta: Option<&Value>) -> Result<Profile, String> {
    let mut p = match input_profile(path, o) {
        Ok(p) => p,
        Err(e) => {
            if meta.is_some() && o.task == "Auto" {
                profile("Custom")?
            } else {
                return Err(e);
            }
        }
    };
    if let Some(v) = meta {
        let n = v["source_epoch_samples"].as_u64().unwrap() as usize;
        let rate = v["sample_rate"]
            .as_f64()
            .ok_or("Saved epochs need sample_rate")?;
        p.epoch[0] = v["epoch_tmin"]
            .as_f64()
            .ok_or("Saved epochs need epoch_tmin; set epoch timing in preprocessing")?;
        p.epoch[1] = p.epoch[0] + (n - 1) as f64 / rate;
    }
    if meta.is_some()
        && o.regroup_epochs
        && p.task != "Custom"
        && o.profile_override.is_none()
        && !o.profile_overrides.contains_key(&p.task)
    {
        let original = profile(&p.task)?;
        p.a_codes = vec![original.a_name.clone()];
        p.b_codes = vec![original.b_name.clone()];
        p.a_name = original.a_name;
        p.b_name = original.b_name;
    }
    Ok(p)
}
pub fn inspect(inputs: &[Input], o: &Options) -> Value {
    json!({"files":inputs.iter().map(|i| {
   let meta=epoch_metadata(&i.path);
   let p=prepared_profile(&i.path,o,meta.as_ref()).ok();
   if let Some(v)=meta {
     let labels=v["epoch_labels"].as_array().cloned().unwrap_or_default();let mut counts=BTreeMap::new();
     let raw_codes=original_epoch_codes(&i.path,&v);
     for (index,label) in labels.iter().enumerate() {let grouped=if o.regroup_epochs {regrouped_label(raw_codes.get(&index),p.as_ref().map(|p|p.task.as_str()).unwrap_or(""))}else{None};let label=if o.regroup_epochs {grouped.as_deref().unwrap_or("Unassigned")}else{label.as_str().unwrap_or("")};*counts.entry(label.to_string()).or_insert(0usize)+=1;}
     return json!({"path":i.path,"subject":if i.subject.is_empty(){participant(&i.path)}else{i.subject.clone()},"profile":p,"is_epoched":true,"marker_source":"Saved epoch condition labels","marker_counts":counts,"event_count":labels.len(),"epoch_tmin":v["epoch_tmin"],"epoch_tmax":v["epoch_tmax"],"can_regroup":!raw_codes.is_empty()});
   }
   match selected_events(Path::new(&i.path),o) {Ok((events,source))=>{let mut counts=BTreeMap::new();for e in &events{*counts.entry(e.label.clone()).or_insert(0usize)+=1;}json!({"path":i.path,"subject":if i.subject.is_empty(){participant(&i.path)}else{i.subject.clone()},"suggested_task":detect_task(&i.path),"profile":p,"is_epoched":false,"marker_source":source,"marker_counts":counts,"event_count":events.len(),"timing_audit":timing_audit(&i.path,&events)})},Err(error)=>json!({"path":i.path,"error":error})}
 }).collect::<Vec<_>>()})
}
#[derive(Clone)]
struct Trial {
    event: Event,
    class: usize,
    rt: Option<f64>,
    sample_start: Option<usize>,
}
fn classify(events: &[Event], p: &Profile, o: &Options) -> (Vec<Trial>, usize) {
    let mut trials = Vec::new();
    let mut rejected = 0;
    for (i, e) in events.iter().enumerate() {
        let normalized = normalized(&e.label);
        let class = if p.a_codes.iter().any(|x| self::normalized(x) == normalized) {
            0
        } else if p.b_codes.iter().any(|x| self::normalized(x) == normalized) {
            1
        } else {
            continue;
        };
        let response = if !["MMN", "ERN", "LRP"].contains(&p.task.as_str()) {
            events
                .iter()
                .skip(i + 1)
                .take_while(|r| r.onset - e.onset <= o.response_max)
                .find(|r| [201, 202].contains(&code(r)))
        } else {
            None
        };
        let rt = response.map(|r| r.onset - e.onset);
        if o.correct_only
            && !["MMN", "ERN", "LRP", "Custom"].contains(&p.task.as_str())
            && !(response.is_some_and(|r| code(r) == 201)
                && rt.is_some_and(|t| t >= o.response_min))
        {
            rejected += 1;
            continue;
        }
        trials.push(Trial {
            event: e.clone(),
            class,
            rt,
            sample_start: None,
        });
    }
    (trials, rejected)
}
fn mirror(label: &str) -> String {
    let up = label.to_uppercase();
    let at = up.find(|c: char| c.is_ascii_digit());
    if let Some(i) = at {
        if let Ok(n) = up[i..].parse::<usize>() {
            return format!("{}{}", &up[..i], if n % 2 == 1 { n + 1 } else { n - 1 });
        }
    }
    up
}
fn eeg(label: &str) -> bool {
    let up = label.to_uppercase();
    !["EOG", "ECG", "EMG", "STATUS", "TRIGGER", "PPG", "AUX"]
        .iter()
        .any(|s| up.contains(s))
}
fn avg(x: &[Vec<f64>]) -> Vec<f64> {
    if x.is_empty() {
        return Vec::new();
    }
    (0..x[0].len())
        .map(|j| x.iter().map(|r| r[j]).sum::<f64>() / x.len() as f64)
        .collect()
}
#[derive(Clone, Serialize)]
pub struct FileResult {
    pub path: String,
    pub subject: String,
    pub task: String,
    pub marker_source: String,
    pub timing_audit: Option<Value>,
    pub profile: Profile,
    pub labels: Vec<String>,
    pub times: Vec<f64>,
    pub bin_times: Vec<f64>,
    pub a: Vec<f64>,
    pub b: Vec<f64>,
    pub difference: Vec<f64>,
    pub n_a: usize,
    pub n_b: usize,
    pub rejected_behavior: usize,
    pub rejected_boundary: usize,
    pub rejected_amplitude: usize,
    pub measurements: BTreeMap<String, math::Measures>,
    pub topo_a: Vec<f64>,
    pub topo_b: Vec<f64>,
    pub topo_difference: Vec<f64>,
    /// Full-resolution condition difference for interactive window topographies.
    pub channel_difference: Vec<Vec<f64>>,
    pub gfp_a: Vec<f64>,
    pub gfp_b: Vec<f64>,
    pub regression: Option<Value>,
    pub deconvolution: Option<Value>,
    pub decoding: Option<Value>,
    pub warnings: Vec<String>,
    #[serde(skip)]
    pub topo_bins: Vec<Vec<f64>>,
    pub accepted_events: Vec<Value>,
    #[serde(skip)]
    pub trial_metrics: Vec<Value>,
}
fn to_bins(y: &[f64], times: &[f64], p: &Profile, dt: f64, nb: usize) -> Vec<f64> {
    let mut sum = vec![0.; nb];
    let mut count = vec![0; nb];
    for (i, &t) in times.iter().enumerate() {
        let b = (((t - p.epoch[0]) / dt).floor().max(0.) as usize).min(nb - 1);
        sum[b] += y[i];
        count[b] += 1;
    }
    for (v, n) in sum.iter_mut().zip(count) {
        *v /= n.max(1) as f64;
    }
    sum
}
fn column_measure(y: &[f64], times: &[f64], window: [f64; 2]) -> f64 {
    let mut sum = 0.;
    let mut n = 0;
    for (v, t) in y.iter().zip(times) {
        if *t >= window[0] - 1e-10 && *t <= window[1] + 1e-10 {
            sum += v;
            n += 1;
        }
    }
    sum / n.max(1) as f64
}
fn gfp(waves: &[Vec<f64>]) -> Vec<f64> {
    (0..waves[0].len())
        .map(|t| {
            let m = waves.iter().map(|c| c[t]).sum::<f64>() / waves.len() as f64;
            (waves.iter().map(|c| (c[t] - m).powi(2)).sum::<f64>() / waves.len() as f64).sqrt()
        })
        .collect()
}
fn metadata(path: &str) -> Result<(Vec<String>, HashMap<(String, usize), Vec<f64>>), String> {
    if path.is_empty() {
        return Ok((Vec::new(), HashMap::new()));
    }
    let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut rows = text.lines();
    let h = csv_row(rows.next().ok_or("Empty trial metadata")?);
    if h.len() < 3 || h[0] != "file" || h[1] != "event_index" {
        return Err(
            "Trial metadata starts with file,event_index followed by numeric predictor columns"
                .into(),
        );
    }
    let mut map = HashMap::new();
    for line in rows.filter(|l| !l.trim().is_empty()) {
        let r = csv_row(line);
        if r.len() != h.len() {
            return Err("Trial metadata column count mismatch".into());
        }
        let index = r[1].parse::<usize>().map_err(|_| "Invalid event_index")?;
        let values = r[2..]
            .iter()
            .map(|v| {
                v.parse::<f64>()
                    .map_err(|_| "Trial predictors must be finite numeric values")
            })
            .collect::<Result<Vec<_>, _>>()?;
        if values.iter().any(|v| !v.is_finite())
            || map.insert((r[0].clone(), index), values).is_some()
        {
            return Err("Nonfinite predictor or duplicate trial metadata key".into());
        }
    }
    Ok((h[2..].to_vec(), map))
}
fn analyse_file(input: &Input, rec: Recording, o: &Options) -> Result<FileResult, String> {
    let metadata = epoch_metadata(&input.path);
    let p = prepared_profile(&input.path, o, metadata.as_ref())?;
    validate(o, &p)?;
    let epoched = rec.source_epoch_samples.is_some();
    let mut epoch_timing_known = true;
    let (events, source, trials, rejected_behavior) = if let Some(n) = rec.source_epoch_samples {
        let meta = metadata
            .as_ref()
            .ok_or("Saved epochs need their timing metadata")?;
        let labels = rec
            .epoch_labels
            .as_ref()
            .ok_or("Saved epochs have no condition labels")?;
        if labels.len() * n != rec.channels[0].len() {
            return Err("Saved epoch labels do not match sample layout".into());
        }
        let onsets = meta["epoch_onsets"].as_array();
        epoch_timing_known = onsets.is_some_and(|a| {
            a.len() == labels.len()
                && a.iter()
                    .all(|v| v.as_f64().is_some_and(|x| x.is_finite() && x >= 0.))
        });
        let mut trials = Vec::new();
        let mut events = Vec::new();
        let original_codes = original_epoch_codes(&input.path, meta);
        for (i, label) in labels.iter().enumerate() {
            let grouped = if o.regroup_epochs {
                regrouped_label(original_codes.get(&i), &p.task)
            } else {
                None
            };
            let label = if o.regroup_epochs {
                grouped.as_deref().unwrap_or("Unassigned")
            } else {
                label.as_str()
            };
            let class = if p.a_codes.iter().any(|c| normalized(c) == normalized(label)) {
                0
            } else if p.b_codes.iter().any(|c| normalized(c) == normalized(label)) {
                1
            } else {
                continue;
            };
            let event = Event {
                label: label.to_string(),
                onset: onsets
                    .and_then(|v| v.get(i))
                    .and_then(Value::as_f64)
                    .unwrap_or(i as f64 * n as f64 / rec.rate - p.epoch[0]),
                duration: 0.,
                index: i + 1,
            };
            events.push(event.clone());
            trials.push(Trial {
                event,
                class,
                rt: None,
                sample_start: Some(i * n),
            });
        }
        trials.sort_by(|a, b| a.event.onset.total_cmp(&b.event.onset));
        (
            events,
            "Saved epoch condition labels (boundaries preserved)".to_string(),
            trials,
            0,
        )
    } else {
        let (events, source) = selected_events(Path::new(&input.path), o)?;
        let (trials, rejected) = classify(&events, &p, o);
        (events, source, trials, rejected)
    };
    if trials.is_empty() {
        return Err("No qualifying trials: review markers and response rules".into());
    }
    let indices: Vec<_> = rec
        .labels
        .iter()
        .enumerate()
        .filter(|(_, l)| eeg(l))
        .map(|(i, _)| i)
        .collect();
    let labels: Vec<_> = indices.iter().map(|&i| rec.labels[i].clone()).collect();
    if labels.len() < 2 {
        return Err("At least two EEG channels are needed".into());
    }
    let roi: Vec<usize> = p
        .roi
        .iter()
        .map(|name| {
            labels
                .iter()
                .position(|l| l.eq_ignore_ascii_case(name))
                .ok_or_else(|| format!("ROI channel {name} missing; choose available ROI channels"))
        })
        .collect::<Result<_, _>>()?;
    if roi.is_empty() || (p.lateralized && roi.len() != 2) {
        return Err(
            "A lateralized component needs exactly one left and one right ROI channel".into(),
        );
    }
    let rate = rec.rate;
    let start = (p.epoch[0] * rate).round() as isize;
    let stop = (p.epoch[1] * rate).round() as isize;
    let points = (stop - start + 1) as usize;
    let times: Vec<_> = (0..points)
        .map(|i| (start + i as isize) as f64 / rate)
        .collect();
    let baseline: Vec<_> = times
        .iter()
        .enumerate()
        .filter(|(_, t)| **t >= p.baseline[0] - 1e-10 && **t <= p.baseline[1] + 1e-10)
        .map(|(i, _)| i)
        .collect();
    if baseline.is_empty() {
        return Err("Baseline has no samples".into());
    }
    let nb = ((p.epoch[1] - p.epoch[0]) / (o.bin_ms / 1000.)).ceil() as usize;
    let dt = o.bin_ms / 1000.;
    let bin_times: Vec<_> = (0..nb)
        .map(|b| p.epoch[0] + (b as f64 + 0.5) * dt)
        .collect();
    let mut mean_a = vec![vec![0.; points]; labels.len()];
    let mut mean_b = mean_a.clone();
    let mut roi_a = vec![0.; points];
    let mut roi_b = roi_a.clone();
    let mut n = [0usize; 2];
    let (mut boundary, mut artifact) = (0, 0);
    let mut accepted = Vec::new();
    let mut trial_metrics = Vec::new();
    let mut binned = Vec::new();
    let mut kept = Vec::new();
    let mut warnings = Vec::new();
    let mirrors: Vec<_> = labels
        .iter()
        .enumerate()
        .map(|(i, l)| {
            labels
                .iter()
                .position(|r| r.eq_ignore_ascii_case(&mirror(l)))
                .unwrap_or(i)
        })
        .collect();
    for trial in trials {
        let onset = (trial.event.onset * rate).round() as isize;
        let a = trial
            .sample_start
            .map(|n| n as isize)
            .unwrap_or(onset + start);
        let b = a + points as isize - 1;
        if a < 0 || b >= rec.channels[0].len() as isize {
            boundary += 1;
            continue;
        }
        let mut x: Vec<Vec<f64>> = indices
            .iter()
            .map(|&c| {
                rec.channels[c][a as usize..=b as usize]
                    .iter()
                    .map(|&v| v as f64)
                    .collect()
            })
            .collect();
        for c in &mut x {
            let base = baseline.iter().map(|&i| c[i]).sum::<f64>() / baseline.len() as f64;
            for v in c {
                *v -= base;
            }
        }
        if x.iter()
            .flatten()
            .any(|v| !v.is_finite() || (o.reject_uv > 0. && v.abs() > o.reject_uv))
        {
            artifact += 1;
            continue;
        }
        let class = trial.class;
        n[class] += 1;
        let (ra, rb) = if p.lateralized {
            let ipsi = roi[class];
            let contra = roi[1 - class];
            (x[ipsi].clone(), x[contra].clone())
        } else {
            let r: Vec<_> = (0..points)
                .map(|t| roi.iter().map(|&c| x[c][t]).sum::<f64>() / roi.len() as f64)
                .collect();
            if class == 0 {
                (r, Vec::new())
            } else {
                (Vec::new(), r)
            }
        };
        if p.lateralized {
            for c in 0..labels.len() {
                let canonical = if class == 0 { c } else { mirrors[c] };
                let opposite = mirrors[canonical];
                for t in 0..points {
                    mean_a[c][t] += x[opposite][t];
                    mean_b[c][t] += x[canonical][t];
                }
            }
        } else {
            let target = if class == 0 { &mut mean_a } else { &mut mean_b };
            for c in 0..labels.len() {
                for t in 0..points {
                    target[c][t] += x[c][t];
                }
            }
        }
        if !ra.is_empty() {
            for t in 0..points {
                roi_a[t] += ra[t];
            }
            trial_metrics.push(json!({"event_index":trial.event.index,"condition":if p.lateralized{"Ipsilateral"}else{&p.a_name},"metrics":math::measure(&times,&ra,p.window,p.polarity)?}));
        }
        if !rb.is_empty() {
            for t in 0..points {
                roi_b[t] += rb[t];
            }
            trial_metrics.push(json!({"event_index":trial.event.index,"condition":if p.lateralized{"Contralateral"}else{&p.b_name},"metrics":math::measure(&times,&rb,p.window,p.polarity)?}));
        }
        if o.regression || o.decoding {
            binned.push(
                x.iter()
                    .flat_map(|c| to_bins(c, &times, &p, dt, nb))
                    .collect::<Vec<_>>(),
            );
        }
        accepted.push(json!({"event_index":trial.event.index,"label":trial.event.label,"onset_s":trial.event.onset,"class":class,"rt_s":trial.rt,"epoch_start_s":a as f64/rate,"epoch_end_s":b as f64/rate}));
        kept.push(trial);
    }
    if n.iter().any(|&v| v < 2) {
        return Err(format!(
            "Each event class needs at least two accepted trials; got {} and {}",
            n[0], n[1]
        ));
    }
    let denominators = if p.lateralized { [n[0] + n[1]; 2] } else { n };
    for c in 0..labels.len() {
        for t in 0..points {
            mean_a[c][t] /= denominators[0] as f64;
            mean_b[c][t] /= denominators[1] as f64;
        }
    }
    for t in 0..points {
        roi_a[t] /= denominators[0] as f64;
        roi_b[t] /= denominators[1] as f64;
    }
    let difference: Vec<_> = roi_b.iter().zip(&roi_a).map(|(b, a)| b - a).collect();
    let mut measurements = BTreeMap::new();
    for (name, x) in [("A", &roi_a), ("B", &roi_b), ("B_minus_A", &difference)] {
        measurements.insert(name.into(), math::measure(&times, x, p.window, p.polarity)?);
    }
    let topo_a: Vec<_> = mean_a
        .iter()
        .map(|c| column_measure(c, &times, p.window))
        .collect();
    let topo_b: Vec<_> = mean_b
        .iter()
        .map(|c| column_measure(c, &times, p.window))
        .collect();
    let topo_difference = topo_b.iter().zip(&topo_a).map(|(b, a)| b - a).collect();
    let topo_bins: Vec<_> = mean_a
        .iter()
        .zip(&mean_b)
        .map(|(a, b)| {
            to_bins(
                &b.iter().zip(a).map(|(b, a)| b - a).collect::<Vec<_>>(),
                &times,
                &p,
                dt,
                nb,
            )
        })
        .collect();
    let mut model_warning = |name: &str, result: Result<Value, String>| match result {
        Ok(value) => Some(value),
        Err(error) => {
            warnings.push(format!("{} unavailable: {}", name, error));
            None
        }
    };
    let regression = if o.regression {
        model_warning(
            "rERP",
            fit_regression(&input.path, &kept, &binned, &labels, &bin_times, o),
        )
    } else {
        None
    };
    drop(model_warning);
    if epoched {
        warnings.push("Existing trials and condition labels reused; no epoching or response re-filtering performed. Verify that stimulus/response locking matches the chosen component.".into());
    }
    if epoched && o.deconvolution {
        warnings.push("Continuous FIR overlap correction requires continuous input; unavailable for saved epochs".into());
    }
    if epoched && !epoch_timing_known && o.decoding {
        warnings.push("Decoding omitted: original event onsets are missing, so temporal leakage cannot be excluded".into());
    }
    let decoding = if o.decoding && (!epoched || epoch_timing_known) {
        let result = decode(
            &kept,
            &binned,
            &labels,
            &bin_times,
            points as f64 / rate,
            o,
            &mut warnings,
        );
        match result {
            Ok(value) => Some(value),
            Err(e) => {
                warnings.push(format!("Decoding unavailable: {}", e));
                None
            }
        }
    } else {
        None
    };
    let deconvolution = if o.deconvolution && !epoched {
        let result = deconvolve(&rec, &indices, &labels, &events, &p, o, &mut warnings);
        match result {
            Ok(value) => Some(value),
            Err(e) => {
                warnings.push(format!("Overlap correction unavailable: {}", e));
                None
            }
        }
    } else {
        None
    };
    if o.reject_uv == 0. {
        warnings
            .push("Amplitude rejection disabled; cleaned input is assumed, not verified".into());
    }
    Ok(FileResult {
        path: input.path.clone(),
        subject: if input.subject.is_empty() {
            participant(&input.path)
        } else {
            input.subject.clone()
        },
        task: p.task.clone(),
        timing_audit: timing_audit(&input.path, &events),
        marker_source: source,
        profile: p,
        labels,
        times,
        bin_times,
        a: roi_a,
        b: roi_b,
        difference,
        n_a: n[0],
        n_b: n[1],
        rejected_behavior,
        rejected_boundary: boundary,
        rejected_amplitude: artifact,
        measurements,
        topo_a,
        topo_b,
        topo_difference,
        channel_difference: mean_b
            .iter()
            .zip(&mean_a)
            .map(|(b, a)| b.iter().zip(a).map(|(b, a)| b - a).collect())
            .collect(),
        gfp_a: gfp(&mean_a),
        gfp_b: gfp(&mean_b),
        regression,
        deconvolution,
        decoding,
        warnings,
        topo_bins,
        accepted_events: accepted,
        trial_metrics,
    })
}
fn fit_regression(
    path: &str,
    trials: &[Trial],
    binned: &[Vec<f64>],
    labels: &[String],
    times: &[f64],
    o: &Options,
) -> Result<Value, String> {
    let (names, extra) = metadata(&o.trial_metadata_path)?;
    let with_rt = trials.iter().all(|t| t.rt.is_some())
        && trials
            .iter()
            .map(|t| t.rt.unwrap_or(0.))
            .fold(f64::NEG_INFINITY, f64::max)
            > trials
                .iter()
                .map(|t| t.rt.unwrap_or(0.))
                .fold(f64::INFINITY, f64::min)
                + 1e-8;
    let mut predictors = vec!["Intercept".to_string(), "Class_B_minus_A".into()];
    if with_rt {
        predictors.push("Reaction_time_s_centered".into());
    }
    predictors.extend(names);
    let mean_rt = trials.iter().map(|t| t.rt.unwrap_or(0.)).sum::<f64>() / trials.len() as f64;
    let basename = Path::new(path)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy();
    let mut rows = Vec::new();
    for t in trials {
        let mut row = vec![1., t.class as f64];
        if with_rt {
            row.push(t.rt.unwrap() - mean_rt);
        }
        if !extra.is_empty() {
            row.extend(
                extra
                    .get(&(path.into(), t.event.index))
                    .or_else(|| extra.get(&(basename.to_string(), t.event.index)))
                    .ok_or_else(|| {
                        format!("No trial metadata for {} event {}", basename, t.event.index)
                    })?,
            );
        }
        rows.push(row);
    }
    let x = DMatrix::from_fn(rows.len(), predictors.len(), |i, j| rows[i][j]);
    let y = DMatrix::from_fn(binned.len(), binned[0].len(), |i, j| binned[i][j]);
    let (beta, rank) = math::regression(&x, &y)?;
    let coefficients: Vec<Vec<Vec<f64>>> = (0..predictors.len())
        .map(|p| {
            (0..labels.len())
                .map(|c| {
                    (0..times.len())
                        .map(|t| beta[(p, c * times.len() + t)])
                        .collect()
                })
                .collect()
        })
        .collect();
    Ok(
        json!({"method":"mass-univariate OLS rERP; explicit intercept/class/RT/numeric predictors","predictors":predictors,"rank":rank,"n_trials":trials.len(),"channels":labels,"times":times,"coefficients":coefficients,"class_definition":"Physical event classes from the reviewed profile (left vs right for lateralized paradigms)"}),
    )
}
fn decode(
    trials: &[Trial],
    binned: &[Vec<f64>],
    labels: &[String],
    times: &[f64],
    epoch_duration: f64,
    o: &Options,
    warnings: &mut Vec<String>,
) -> Result<Value, String> {
    let n = trials.len();
    let nt = times.len();
    let mut diagonal = vec![Vec::<f64>::new(); nt];
    let mut accuracy = diagonal.clone();
    let mut general = vec![Vec::<f64>::new(); nt * nt];
    let mut folds_used = 0;
    let mut fold_audit = Vec::new();
    for fold in 0..o.folds {
        let a = n * fold / o.folds;
        let b = n * (fold + 1) / o.folds;
        if a == b {
            continue;
        }
        let test: Vec<_> = (a..b).collect();
        let start = trials[a].event.onset + trials.first().map(|_| -epoch_duration).unwrap_or(0.);
        let end = trials[b - 1].event.onset + epoch_duration;
        let train: Vec<_> = (0..n)
            .filter(|&i| i < a || i >= b)
            .filter(|&i| trials[i].event.onset < start || trials[i].event.onset > end)
            .collect();
        let y_train: Vec<_> = train.iter().map(|&i| trials[i].class).collect();
        let y_test: Vec<_> = test.iter().map(|&i| trials[i].class).collect();
        if [0, 1]
            .iter()
            .any(|k| y_train.iter().filter(|&v| v == k).count() < 2 || !y_test.contains(k))
        {
            fold_audit.push(json!({"fold":fold+1,"status":"skipped: missing class after temporal purging","train":train.len(),"test":test.len()}));
            continue;
        }
        let at = |indices: &[usize], t: usize| {
            DMatrix::from_fn(indices.len(), labels.len(), |r, c| {
                binned[indices[r]][c * nt + t]
            })
        };
        let predictions: Vec<_> = (0..nt)
            .into_par_iter()
            .map(|t| {
                let x = at(&train, t);
                let target_times: Vec<_> = if o.temporal_generalization {
                    (0..nt).collect()
                } else {
                    vec![t]
                };
                target_times
                    .into_iter()
                    .map(|u| {
                        math::lda_scores(&x, &y_train, &at(&test, u), o.decode_shrinkage).map(
                            |scores| {
                                let auc = math::auc(&y_test, &scores).unwrap();
                                let acc = (0..2)
                                    .map(|k| {
                                        scores
                                            .iter()
                                            .zip(&y_test)
                                            .filter(|(_, y)| **y == k)
                                            .filter(|(s, _)| usize::from(**s > 0.) == k)
                                            .count() as f64
                                            / y_test.iter().filter(|&&v| v == k).count() as f64
                                    })
                                    .sum::<f64>()
                                    / 2.;
                                (u, auc, acc)
                            },
                        )
                    })
                    .collect::<Result<Vec<_>, _>>()
            })
            .collect::<Result<Vec<_>, _>>()?;
        for (t, row) in predictions.iter().enumerate() {
            for &(u, auc, acc) in row {
                if t == u {
                    diagonal[t].push(auc);
                    accuracy[t].push(acc);
                }
                if o.temporal_generalization {
                    general[t * nt + u].push(auc);
                }
            }
        }
        folds_used += 1;
        fold_audit.push(json!({"fold":fold+1,"status":"used","train":train.len(),"test":test.len(),"first_test_event":trials[a].event.index,"last_test_event":trials[b-1].event.index}));
    }
    if folds_used < 2 {
        warnings.push("Decoding has fewer than two eligible purged folds; no reliable cross-validation summary".into());
    }
    let mean = |v: &Vec<f64>| {
        if v.is_empty() {
            None
        } else {
            Some(v.iter().sum::<f64>() / v.len() as f64)
        }
    };
    Ok(
        json!({"method":"within-recording purged blocked CV; shrinkage LDA; train-fold scaling","folds_used":folds_used,"folds":fold_audit,"times":times,"auc":diagonal.iter().map(mean).collect::<Vec<_>>(),"balanced_accuracy":accuracy.iter().map(mean).collect::<Vec<_>>(),"generalization_auc":if o.temporal_generalization{Some(general.iter().map(mean).collect::<Vec<_>>())}else{None},"generalization_shape":[nt,nt],"class_definition":"Original physical event classes; left/right side for N2pc and LRP","chance":0.5,"inference":"Descriptive CV scores; no above-chance significance claim without permutation testing"}),
    )
}
fn deconvolve(
    rec: &Recording,
    indices: &[usize],
    labels: &[String],
    events: &[Event],
    p: &Profile,
    o: &Options,
    warnings: &mut Vec<String>,
) -> Result<Value, String> {
    let dt = o.bin_ms / 1000.;
    let rows = (rec.channels[0].len() as f64 / rec.rate / dt).floor() as usize;
    let first = (p.epoch[0] / dt).round() as isize;
    let last = (p.epoch[1] / dt).round() as isize;
    let lags = (last - first + 1) as usize;
    let names = vec![
        p.a_name.clone(),
        p.b_name.clone(),
        "Other stimulus".into(),
        "Other response".into(),
    ];
    let mut design = math::SparseDesign {
        rows: vec![vec![(4 * lags, 1.)]; rows],
        columns: 4 * lags + 1,
    };
    let mut counts = [0usize; 4];
    for e in events {
        let label = normalized(&e.label);
        let c = if p.a_codes.iter().any(|x| normalized(x) == label) {
            Some(0)
        } else if p.b_codes.iter().any(|x| normalized(x) == label) {
            Some(1)
        } else {
            let k = code(e);
            if ["ERN", "LRP"].contains(&p.task.as_str()) {
                if [11, 12, 21, 22].contains(&k) {
                    Some(2)
                } else if (100..=222).contains(&k) {
                    Some(3)
                } else {
                    None
                }
            } else if [201, 202].contains(&k) {
                Some(3)
            } else if (1..=180).contains(&k) {
                Some(2)
            } else {
                None
            }
        };
        let Some(c) = c else {
            continue;
        };
        counts[c] += 1;
        let onset = (e.onset / dt).round() as isize;
        for l in 0..lags {
            let r = onset + first + l as isize;
            if r >= 0 && (r as usize) < rows {
                design.rows[r as usize].push((c * lags + l, 1.));
            }
        }
    }
    let fit: Vec<_> = indices
        .par_iter()
        .map(|&c| {
            let y: Vec<_> = (0..rows)
                .map(|r| {
                    let a = (r as f64 * dt * rec.rate).round() as usize;
                    let b = (((r + 1) as f64 * dt * rec.rate).round() as usize)
                        .min(rec.channels[c].len());
                    rec.channels[c][a..b].iter().map(|&v| v as f64).sum::<f64>()
                        / (b - a).max(1) as f64
                })
                .collect();
            math::lsqr(&design, &y, o.lsqr_tolerance, o.lsqr_iterations)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let converged = fit.iter().filter(|r| r.converged).count();
    if converged < fit.len() {
        warnings.push(format!(
            "Deconvolution LSQR converged for {converged}/{} channels; inspect solver diagnostics",
            fit.len()
        ));
    }
    let coefficients: Vec<Vec<Vec<f64>>> = (0..4)
        .map(|k| {
            fit.iter()
                .map(|r| r.coefficients[k * lags..(k + 1) * lags].to_vec())
                .collect()
        })
        .collect();
    Ok(
        json!({"method":"Unfold-style sparse FIR/stick-basis least squares (LSQR); intercept plus four event categories","channels":labels,"predictors":names,"event_counts":counts,"times":(0..lags).map(|l|(first+l as isize) as f64*dt).collect::<Vec<_>>(),"coefficients":coefficients,"solver":fit.iter().map(|r|json!({"iterations":r.iterations,"converged":r.converged,"residual_norm":r.residual_norm,"normal_residual_norm":r.normal_residual_norm})).collect::<Vec<_>>(),"sample_bin_ms":o.bin_ms,"lsqr_tolerance":o.lsqr_tolerance,"lsqr_iterations":o.lsqr_iterations,"max_event_quantization_ms":o.bin_ms/2.,"scope":"Continuous data; all reviewed category events including nuisance stimuli/responses. Behavioral/artifact trial exclusions used for conventional ERPs do not mask this model. No spline/GAM/mixed effects claim."}),
    )
}
fn signs(n: usize, permutations: usize, seed: u64) -> Vec<Vec<f64>> {
    if n <= 12 {
        (0..(1usize << n))
            .map(|mask| {
                (0..n)
                    .map(|i| if mask & (1 << i) == 0 { 1. } else { -1. })
                    .collect()
            })
            .collect()
    } else {
        let mut rng = StdRng::seed_from_u64(seed);
        let mut out = vec![vec![1.; n]];
        out.extend((0..permutations).map(|_| {
            (0..n)
                .map(|_| if rng.gen::<bool>() { 1. } else { -1. })
                .collect::<Vec<_>>()
        }));
        out
    }
}
fn interpolation(times: &[f64], y: &[f64], target: &[f64]) -> Vec<f64> {
    target
        .iter()
        .map(|t| {
            let upper = times.partition_point(|v| v < t);
            if upper == 0 {
                y[0]
            } else if upper >= times.len() {
                *y.last().unwrap()
            } else {
                let a = upper - 1;
                let f = (t - times[a]) / (times[upper] - times[a]);
                y[a] * (1. - f) + y[upper] * f
            }
        })
        .collect()
}
fn group(files: &[&FileResult], o: &Options) -> Value {
    let first = files[0];
    let mut subjects: BTreeMap<String, Vec<&FileResult>> = BTreeMap::new();
    for f in files {
        subjects.entry(f.subject.clone()).or_default().push(f);
    }
    let names: Vec<_> = subjects.keys().cloned().collect();
    let common_labels: Vec<String> = first
        .labels
        .iter()
        .filter(|label| {
            files.iter().all(|f| {
                f.labels
                    .iter()
                    .any(|other| other.eq_ignore_ascii_case(label))
            })
        })
        .cloned()
        .collect();
    let same_channels = common_labels.len() >= 4;
    let same_bins = files.iter().all(|f| f.bin_times == first.bin_times);
    let aligned = |f: &FileResult, values: &Vec<f64>| {
        common_labels
            .iter()
            .map(|label| {
                values[f
                    .labels
                    .iter()
                    .position(|other| other.eq_ignore_ascii_case(label))
                    .unwrap()]
            })
            .collect::<Vec<_>>()
    };
    let rows_a: Vec<_> = subjects
        .values()
        .map(|fs| {
            avg(&fs
                .iter()
                .map(|f| interpolation(&f.times, &f.a, &first.times))
                .collect::<Vec<_>>())
        })
        .collect();
    let rows_b: Vec<_> = subjects
        .values()
        .map(|fs| {
            avg(&fs
                .iter()
                .map(|f| interpolation(&f.times, &f.b, &first.times))
                .collect::<Vec<_>>())
        })
        .collect();
    let differences: Vec<Vec<f64>> = rows_a
        .iter()
        .zip(&rows_b)
        .map(|(a, b)| a.iter().zip(b).map(|(a, b)| b - a).collect())
        .collect();
    let a = avg(&rows_a);
    let b = avg(&rows_b);
    let difference = avg(&differences);
    let sem: Vec<_> = (0..difference.len())
        .map(|t| {
            if names.len() > 1 {
                (differences
                    .iter()
                    .map(|r| (r[t] - difference[t]).powi(2))
                    .sum::<f64>()
                    / ((names.len() - 1) * names.len()) as f64)
                    .sqrt()
            } else {
                0.
            }
        })
        .collect();
    let topoa: Vec<_> = subjects
        .values()
        .map(|fs| avg(&fs.iter().map(|f| aligned(f, &f.topo_a)).collect::<Vec<_>>()))
        .collect();
    let topob: Vec<_> = subjects
        .values()
        .map(|fs| avg(&fs.iter().map(|f| aligned(f, &f.topo_b)).collect::<Vec<_>>()))
        .collect();
    let topo: Vec<Vec<f64>> = topoa
        .iter()
        .zip(&topob)
        .map(|(a, b)| a.iter().zip(b).map(|(a, b)| b - a).collect())
        .collect();
    let flip = signs(names.len(), o.permutations, o.seed);
    let (topo_t, topo_p) = if same_channels {
        math::max_t(&topo, &flip)
    } else {
        (Vec::new(), Vec::new())
    };
    let (temporal_t, temporal_p) = if same_channels && same_bins {
        let rows: Vec<_> = subjects
            .values()
            .map(|fs| {
                avg(&fs
                    .iter()
                    .map(|f| {
                        common_labels
                            .iter()
                            .flat_map(|label| {
                                f.topo_bins[f
                                    .labels
                                    .iter()
                                    .position(|other| other.eq_ignore_ascii_case(label))
                                    .unwrap()]
                                .clone()
                            })
                            .collect::<Vec<_>>()
                    })
                    .collect::<Vec<_>>())
            })
            .collect();
        math::max_t(&rows, &flip)
    } else {
        (Vec::new(), Vec::new())
    };
    let normal = |v: &Vec<f64>| {
        let m = v.iter().sum::<f64>() / v.len() as f64;
        let norm = (v.iter().map(|x| (x - m).powi(2)).sum::<f64>() / v.len() as f64).sqrt();
        v.iter()
            .map(|x| if norm > 1e-12 { (x - m) / norm } else { 0. })
            .collect::<Vec<_>>()
    };
    let normalized: Vec<Vec<f64>> = topoa
        .iter()
        .zip(&topob)
        .map(|(a, b)| {
            normal(a)
                .iter()
                .zip(normal(b))
                .map(|(a, b)| b - a)
                .collect()
        })
        .collect();
    let norm = |v: &Vec<f64>| (v.iter().map(|x| x * x).sum::<f64>() / v.len() as f64).sqrt();
    let tanova = norm(&avg(&normalized));
    let nonflat = topoa.iter().chain(&topob).all(|v| {
        let m = v.iter().sum::<f64>() / v.len() as f64;
        v.iter().map(|x| (x - m).powi(2)).sum::<f64>() > 1e-20
    });
    let tanova_p = if names.len() > 1 && same_channels && nonflat {
        Some(
            flip.iter()
                .filter(|s| {
                    let changed: Vec<Vec<f64>> = normalized
                        .iter()
                        .zip(s.iter())
                        .map(|(r, sign)| r.iter().map(|x| x * sign).collect())
                        .collect();
                    norm(&avg(&changed)) >= tanova - 1e-10
                })
                .count() as f64
                / flip.len() as f64,
        )
    } else {
        None
    };
    let mut stats = Vec::new();
    for metric in [
        "mean",
        "signed_auc",
        "peak_amplitude",
        "peak_latency",
        "fractional_area_latency",
    ] {
        let mut diffs = Vec::new();
        for fs in subjects.values() {
            let mut values = Vec::new();
            for f in fs {
                let ma = serde_json::to_value(&f.measurements["A"]).unwrap();
                let mb = serde_json::to_value(&f.measurements["B"]).unwrap();
                if let (Some(a), Some(b)) = (ma[metric].as_f64(), mb[metric].as_f64()) {
                    values.push(b - a);
                }
            }
            if !values.is_empty() {
                diffs.push(values.iter().sum::<f64>() / values.len() as f64);
            }
        }
        let result = math::paired_test(&diffs);
        stats.push(json!({"metric":metric,"n_subjects":diffs.len(),"mean_difference":if diffs.is_empty(){None}else{Some(diffs.iter().sum::<f64>()/diffs.len() as f64)},"t":result.map(|v|v.0),"p":result.map(|v|v.1)}));
    }
    let mut order: Vec<_> = (0..stats.len())
        .filter(|&i| stats[i]["p"].as_f64().is_some())
        .collect();
    order.sort_by(|&a, &b| {
        stats[a]["p"]
            .as_f64()
            .unwrap()
            .total_cmp(&stats[b]["p"].as_f64().unwrap())
    });
    let mut q = 1f64;
    for k in (0..order.len()).rev() {
        let i = order[k];
        q = q.min(stats[i]["p"].as_f64().unwrap() * order.len() as f64 / (k + 1) as f64);
        stats[i]["q_fdr"] = json!(q);
    }
    let grand_difference_measurements = math::measure(
        &first.times,
        &difference,
        first.profile.window,
        first.profile.polarity,
    )
    .ok();
    let mut model_subjects: BTreeMap<String, Vec<Vec<f64>>> = BTreeMap::new();
    let reference_predictors = files
        .iter()
        .find_map(|f| f.regression.as_ref().map(|m| m["predictors"].clone()));
    for file in files {
        if let Some(model) = &file.regression {
            if Some(&model["predictors"]) != reference_predictors.as_ref() {
                continue;
            }
            if file.bin_times != first.bin_times {
                continue;
            }
            let row: Vec<_> = common_labels
                .iter()
                .flat_map(|label| {
                    let c = file
                        .labels
                        .iter()
                        .position(|other| other.eq_ignore_ascii_case(label))
                        .unwrap();
                    model["coefficients"][1][c]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_f64().unwrap())
                        .collect::<Vec<_>>()
                })
                .collect();
            model_subjects
                .entry(file.subject.clone())
                .or_default()
                .push(row);
        }
    }
    let regression_inference = if model_subjects.len() > 1 && same_channels {
        let rows: Vec<_> = model_subjects.values().map(|v| avg(v)).collect();
        let flip = signs(rows.len(), o.permutations, o.seed);
        let (t, p) = math::max_t(&rows, &flip);
        Some(
            json!({"n_subjects":rows.len(),"channels":common_labels,"times":first.bin_times,"t":t,"p_fwer":p,"mean_class_coefficient":avg(&rows),"method":"Subject-level class beta versus zero; max-|t| across channel × time"}),
        )
    } else {
        None
    };
    let gfp_a = avg(&subjects
        .values()
        .map(|fs| {
            avg(&fs
                .iter()
                .map(|f| interpolation(&f.times, &f.gfp_a, &first.times))
                .collect::<Vec<_>>())
        })
        .collect::<Vec<_>>());
    let gfp_b = avg(&subjects
        .values()
        .map(|fs| {
            avg(&fs
                .iter()
                .map(|f| interpolation(&f.times, &f.gfp_b, &first.times))
                .collect::<Vec<_>>())
        })
        .collect::<Vec<_>>());
    json!({"task":first.task,"component_name":first.profile.component_name,"profile":first.profile,"subjects":names,"n_subjects":subjects.len(),"n_files":files.len(),"times":first.times,"a":a,"b":b,"difference":difference,"sem_difference":sem,"grand_difference_measurements":grand_difference_measurements,"regression_inference":regression_inference,"gfp_a":gfp_a,"gfp_b":gfp_b,"labels":common_labels,"topo_difference":if same_channels{Some(avg(&topo))}else{None},"topo_t":topo_t,"topo_p_fwer":topo_p,"bin_times":first.bin_times,"spatiotemporal_t":temporal_t,"spatiotemporal_p_fwer":temporal_p,"statistics":stats,"tanova_gmd":tanova,"tanova_p":tanova_p,"permutation_patterns":flip.len(),"inference_unit":"participant; multiple recordings averaged within participant","warning":if !same_channels{"Fewer than four common channels: topographical inference omitted"}else if subjects.len()<2{"One participant: descriptive results only"}else{"Separate max-|t| families: component-window channels and all channel×time bins"}})
}
pub fn run<F>(job: &Job, mut load: F) -> Result<Value, String>
where
    F: FnMut(&str) -> Result<Recording, String>,
{
    if job.inputs.is_empty() {
        return Err("Choose at least one input recording".into());
    }
    fs::create_dir_all(&job.output).map_err(|e| e.to_string())?;
    let mut files = Vec::new();
    let mut failures = Vec::new();
    for (i, input) in job.inputs.iter().enumerate() {
        eprintln!("PROGRESS {} ERP {}", i * 85 / job.inputs.len(), input.path);
        match load(&input.path).and_then(|rec| analyse_file(input, rec, &job.options)) {
            Ok(f) => files.push(f),
            Err(error) => failures.push(json!({"path":input.path,"error":error})),
        }
    }
    let tasks: Vec<_> = files
        .iter()
        .map(|f| f.task.clone())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    let groups: Vec<_> = tasks
        .iter()
        .map(|task| {
            group(
                &files.iter().filter(|f| &f.task == task).collect::<Vec<_>>(),
                &job.options,
            )
        })
        .collect();
    let mut measurements=String::from("subject,task,file,condition,n_trials,mean_uv,signed_auc_uv_s,positive_auc_uv_s,negative_auc_uv_s,peak_amplitude_uv,peak_latency_s,fractional_area_latency_s,fractional_peak_latency_s\n");
    for f in &files {
        for (name, m) in &f.measurements {
            measurements.push_str(&format!(
                "{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
                csv(&f.subject),
                csv(&f.task),
                csv(&f.path),
                name,
                if name == "A" {
                    f.n_a
                } else if name == "B" {
                    f.n_b
                } else {
                    f.n_a + f.n_b
                },
                m.mean,
                m.signed_auc,
                m.positive_auc,
                m.negative_auc,
                m.peak_amplitude,
                m.peak_latency,
                m.fractional_area_latency
                    .map(|v| v.to_string())
                    .unwrap_or_default(),
                m.fractional_peak_latency
                    .map(|v| v.to_string())
                    .unwrap_or_default()
            ));
        }
    }
    fs::write(
        Path::new(&job.output).join("erp_measurements.csv"),
        measurements,
    )
    .map_err(|e| e.to_string())?;
    let mut statistics = String::from("task,n_subjects,metric,mean_difference,t,p,q_fdr\n");
    for g in &groups {
        for s in g["statistics"].as_array().unwrap() {
            statistics.push_str(&format!(
                "{},{},{},{},{},{},{}\n",
                g["task"].as_str().unwrap(),
                s["n_subjects"],
                s["metric"].as_str().unwrap(),
                s["mean_difference"],
                s["t"],
                s["p"],
                s["q_fdr"]
            ));
        }
    }
    fs::write(
        Path::new(&job.output).join("erp_group_statistics.csv"),
        statistics,
    )
    .map_err(|e| e.to_string())?;
    let mut trial_csv=String::from("subject,task,file,event_index,condition,marker,onset_s,rt_s,mean_uv,signed_auc_uv_s,positive_auc_uv_s,negative_auc_uv_s,peak_amplitude_uv,peak_latency_s,fractional_area_latency_s,fractional_peak_latency_s\n");
    let mut wave_csv =
        String::from("level,subject,task,time_s,A_uv,B_uv,difference_uv,sem_difference_uv\n");
    let numeric = |v: &Value| {
        v.as_f64()
            .filter(|v| v.is_finite())
            .map(|v| v.to_string())
            .unwrap_or_default()
    };
    for f in &files {
        for trial in &f.trial_metrics {
            let event = f
                .accepted_events
                .iter()
                .find(|e| e["event_index"] == trial["event_index"])
                .unwrap();
            let m = &trial["metrics"];
            let mut row = vec![
                csv(&f.subject),
                csv(&f.task),
                csv(&f.path),
                trial["event_index"].to_string(),
                csv(trial["condition"].as_str().unwrap()),
                csv(event["label"].as_str().unwrap()),
                numeric(&event["onset_s"]),
                numeric(&event["rt_s"]),
            ];
            for key in [
                "mean",
                "signed_auc",
                "positive_auc",
                "negative_auc",
                "peak_amplitude",
                "peak_latency",
                "fractional_area_latency",
                "fractional_peak_latency",
            ] {
                row.push(numeric(&m[key]));
            }
            trial_csv.push_str(&(row.join(",") + "\n"));
        }
        for t in 0..f.times.len() {
            wave_csv.push_str(&format!(
                "recording,{},{},{},{},{},{},\n",
                csv(&f.subject),
                csv(&f.task),
                f.times[t],
                f.a[t],
                f.b[t],
                f.difference[t]
            ));
        }
    }
    for g in &groups {
        for t in 0..g["times"].as_array().unwrap().len() {
            wave_csv.push_str(&format!(
                "group,,{},{},{},{},{},{}\n",
                csv(g["task"].as_str().unwrap()),
                numeric(&g["times"][t]),
                numeric(&g["a"][t]),
                numeric(&g["b"][t]),
                numeric(&g["difference"][t]),
                numeric(&g["sem_difference"][t])
            ));
        }
    }
    fs::write(
        Path::new(&job.output).join("erp_trial_measurements.csv"),
        trial_csv,
    )
    .map_err(|e| e.to_string())?;
    fs::write(Path::new(&job.output).join("erp_waveforms.csv"), wave_csv)
        .map_err(|e| e.to_string())?;
    let mut model_csv = String::from("subject,task,file,model,predictor,channel,time_s,beta\n");
    let mut model_rows = 0;
    for f in &files {
        for (name, model) in [("rERP", &f.regression), ("FIR_overlap", &f.deconvolution)] {
            if let Some(model) = model {
                let preds = model["predictors"].as_array().unwrap();
                let time = model["times"].as_array().unwrap();
                for p in 0..preds.len() {
                    for c in 0..f.labels.len() {
                        for t in 0..time.len() {
                            model_csv.push_str(&format!(
                                "{},{},{},{},{},{},{},{}\n",
                                csv(&f.subject),
                                csv(&f.task),
                                csv(&f.path),
                                name,
                                csv(preds[p].as_str().unwrap()),
                                csv(&f.labels[c]),
                                numeric(&time[t]),
                                numeric(&model["coefficients"][p][c][t])
                            ));
                            model_rows += 1;
                        }
                    }
                }
            }
        }
    }
    if model_rows > 0 {
        fs::write(
            Path::new(&job.output).join("erp_model_coefficients.csv"),
            model_csv,
        )
        .map_err(|e| e.to_string())?;
    }
    let result = json!({"schema":"ccs-erp-workbench-v1","options":job.options,"files":files,"groups":groups,"failures":failures,"output":job.output});
    fs::write(
        Path::new(&job.output).join("erp_results.json"),
        serde_json::to_vec(&result).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    eprintln!("PROGRESS 100 ERP workbench complete");
    Ok(result)
}
