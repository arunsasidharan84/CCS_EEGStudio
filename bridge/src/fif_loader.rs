use crate::Recording;
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;

const FIFF_SFREQ: i32 = 201;
const FIFF_CH_INFO: i32 = 203;
const FIFF_DESCRIPTION: i32 = 206;
const FIFF_EPOCH: i32 = 302;
const FIFF_MNE_EVENT_LIST: i32 = 3561;
const FIFF_MNE_EVENT_COMMENTS: i32 = 3562;

fn read_i32_be(data: &[u8], offset: usize) -> i32 {
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&data[offset..offset + 4]);
    i32::from_be_bytes(buf)
}

fn read_f32_be(data: &[u8], offset: usize) -> f32 {
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&data[offset..offset + 4]);
    f32::from_be_bytes(buf)
}

struct ChInfo {
    name: String,
    cal: f32,
}

pub fn load_fif(path: &Path) -> Result<Recording, String> {
    let mut file = File::open(path).map_err(|e| format!("failed to open fif file: {}", e))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|e| format!("failed to read fif file: {}", e))?;

    let mut offset = 0;
    let mut rate = 1000.0f64;
    let mut ch_infos = Vec::new();
    let mut event_map = HashMap::<i32, String>::new();
    let mut raw_event_codes = Vec::new();
    let mut epoch_data_tag: Option<Vec<u8>> = None;

    while offset + 16 <= bytes.len() {
        let kind = read_i32_be(&bytes, offset);
        let _tag_type = read_i32_be(&bytes, offset + 4);
        let size = read_i32_be(&bytes, offset + 8);
        let _next = read_i32_be(&bytes, offset + 12);

        if size < 0 || offset + 16 + (size as usize) > bytes.len() {
            break;
        }

        let data = &bytes[offset + 16..offset + 16 + (size as usize)];

        if kind == FIFF_SFREQ && size >= 4 {
            rate = read_f32_be(data, 0) as f64;
        } else if kind == FIFF_CH_INFO && size >= 96 {
            let range_val = read_f32_be(data, 12);
            let cal_val = read_f32_be(data, 16);
            let name_bytes = &data[80..96];
            let name_end = name_bytes
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(name_bytes.len());
            let name = String::from_utf8_lossy(&name_bytes[..name_end])
                .trim()
                .to_string();
            ch_infos.push(ChInfo {
                name,
                cal: range_val * cal_val,
            });
        } else if kind == FIFF_DESCRIPTION || kind == FIFF_MNE_EVENT_COMMENTS {
            let text = String::from_utf8_lossy(data).to_string();
            if text.contains(';') && text.contains(':') {
                for pair in text.split(';') {
                    let parts: Vec<&str> = pair.split(':').collect();
                    if parts.len() == 2 {
                        let p0 = parts[0].trim();
                        let p1 = parts[1].trim();
                        if let Ok(code) = p1.parse::<i32>() {
                            event_map.insert(code, p0.to_string());
                        } else if let Ok(code) = p0.parse::<i32>() {
                            event_map.insert(code, p1.to_string());
                        }
                    }
                }
            }
        } else if kind == FIFF_MNE_EVENT_LIST {
            let count = data.len() / 4;
            let mut ints = Vec::with_capacity(count);
            for i in 0..count {
                ints.push(read_i32_be(data, i * 4));
            }
            let rows = count / 3;
            for r in 0..rows {
                raw_event_codes.push(ints[r * 3 + 2]);
            }
        } else if kind == FIFF_EPOCH {
            epoch_data_tag = Some(data.to_vec());
        }

        offset += 16 + (size as usize);
    }

    if ch_infos.is_empty() {
        return Err("FIF file contains no channel info".into());
    }

    let epoch_bytes = epoch_data_tag.ok_or_else(|| "FIF file contains no epoch data".to_string())?;
    if epoch_bytes.len() < 16 {
        return Err("FIF epoch data too short".into());
    }

    let ndim = read_i32_be(&epoch_bytes, epoch_bytes.len() - 4) as usize;
    if ndim != 3 || epoch_bytes.len() < 4 + 4 * ndim {
        return Err("FIF epoch data is not a 3D matrix".into());
    }

    let dims_offset = epoch_bytes.len() - 4 - 4 * ndim;
    let n_samples = read_i32_be(&epoch_bytes, dims_offset) as usize;
    let n_channels = read_i32_be(&epoch_bytes, dims_offset + 4) as usize;
    let n_epochs = read_i32_be(&epoch_bytes, dims_offset + 8) as usize;

    if n_channels != ch_infos.len() {
        return Err(format!(
            "FIF channel count mismatch: tag says {}, info says {}",
            n_channels,
            ch_infos.len()
        ));
    }

    let expected_floats = n_samples * n_channels * n_epochs;
    if dims_offset < expected_floats * 4 {
        return Err("FIF epoch data truncated".into());
    }

    let mut float_data = Vec::with_capacity(expected_floats);
    for i in 0..expected_floats {
        float_data.push(read_f32_be(&epoch_bytes, i * 4));
    }

    let labels: Vec<String> = ch_infos.iter().map(|c| c.name.clone()).collect();
    let mut channels = Vec::with_capacity(n_channels);
    for c in 0..n_channels {
        let cal = ch_infos[c].cal;
        let mut ch_samples = Vec::with_capacity(n_samples * n_epochs);
        let mut max_abs = 0.0f32;
        for e in 0..n_epochs {
            for s in 0..n_samples {
                let flat_idx = s + n_samples * c + n_samples * n_channels * e;
                let val = float_data[flat_idx] * cal;
                ch_samples.push(val);
                if val.abs() > max_abs {
                    max_abs = val.abs();
                }
            }
        }
        if max_abs > 0.0 && max_abs < 0.1 {
            for sample in &mut ch_samples {
                *sample *= 1e6;
            }
        }
        channels.push(ch_samples);
    }

    let epoch_labels = if !raw_event_codes.is_empty() {
        Some(
            raw_event_codes
                .iter()
                .map(|code| {
                    event_map
                        .get(code)
                        .cloned()
                        .unwrap_or_else(|| format!("Event {}", code))
                })
                .collect(),
        )
    } else {
        None
    };

    Ok(Recording {
        rate,
        labels,
        channels,
        source_epoch_samples: Some(n_samples),
        epoch_labels,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_fif_real_file() {
        let path = Path::new("/Users/arunsasidharan/EEGdata/SumaPhD/ERP_Analytsis_20260326/ERPData/Epoched/NC_1_PRE_AOB_P300_epo.fif");
        if !path.exists() {
            return;
        }
        let rec = load_fif(path).unwrap();
        assert_eq!(rec.rate, 1000.0);
        assert_eq!(rec.labels.len(), 65);
        assert_eq!(rec.source_epoch_samples, Some(2001));
        assert_eq!(rec.channels[0].len(), 2001 * 180);
        let el = rec.epoch_labels.unwrap();
        assert_eq!(el.len(), 180);
        assert!(el.contains(&"Frequent".to_string()) || el.contains(&"Rare".to_string()));
    }
}
