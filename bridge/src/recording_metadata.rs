//! Application metadata companions for standard EDF/FIF signal files.
use crate::Recording;
use serde_json::Value;
use std::{fs, path::Path};
pub fn read(path: &Path) -> Result<Option<Value>, String> {
    let file = path.with_file_name(format!(
        "{}.ccsmeta",
        path.file_name()
            .ok_or("Missing data filename")?
            .to_string_lossy()
    ));
    if !file.exists() {
        return Ok(None);
    }
    let m: Value = serde_json::from_slice(&fs::read(file).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if m["schema"] != "ccs-recording-metadata-v1"
        || m["data_bytes"].as_u64() != Some(fs::metadata(path).map_err(|e| e.to_string())?.len())
    {
        return Err("The .ccsmeta companion does not match the signal file".into());
    }
    Ok(Some(m))
}
pub fn apply(rec: &mut Recording, path: &Path) -> Result<(), String> {
    let Some(m) = read(path)? else { return Ok(()) };
    let labels: Vec<String> =
        serde_json::from_value(m["labels"].clone()).map_err(|e| e.to_string())?;
    let n = m["sample_count"]
        .as_u64()
        .ok_or("Metadata sample_count missing")? as usize;
    let rate = m["sample_rate"]
        .as_f64()
        .filter(|r| r.is_finite() && *r > 0.)
        .ok_or("Invalid metadata sampling rate")?;
    let pts = m["source_epoch_samples"].as_u64().map(|n| n as usize);
    if labels.len() != rec.channels.len()
        || n == 0
        || rec.channels.iter().any(|c| c.len() < n)
        || pts.is_some_and(|p| p == 0 || n % p != 0)
    {
        return Err("Recording/metadata dimensions do not match".into());
    }
    for c in &mut rec.channels {
        c.truncate(n);
    }
    rec.labels = labels;
    rec.rate = rate;
    rec.source_epoch_samples = pts;
    rec.epoch_labels = if m["epoch_labels"].is_array() {
        Some(serde_json::from_value(m["epoch_labels"].clone()).map_err(|e| e.to_string())?)
    } else {
        None
    };
    Ok(())
}
