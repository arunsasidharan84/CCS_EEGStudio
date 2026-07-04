use std::collections::HashMap;
use std::fs;
use std::path::Path;
use crate::Recording;

enum Bm { I16, U16, I32, F32 }

pub fn load_vhdr(path: &Path) -> Result<Recording, String> {
    let content = fs::read_to_string(path)
        .map_err(|e| format!("Failed reading .vhdr header {}: {}", path.display(), e))?;

    let mut data_file = String::new();
    let mut orientation = String::from("MULTIPLEXED");
    let mut binary_format = String::from("IEEE_FLOAT_32");
    let mut num_channels = 0usize;
    let mut sampling_interval_us = 0.0f64;

    let mut channel_names = HashMap::new();
    let mut channel_resolutions = HashMap::new();

    let mut section = String::new();

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].trim().to_string();
            continue;
        }
        if let Some(idx) = line.find('=') {
            let k = line[..idx].trim();
            let v = line[idx + 1..].trim();
            match section.as_str() {
                "Common Infos" => {
                    if k.eq_ignore_ascii_case("DataFile") {
                        data_file = v.to_string();
                    } else if k.eq_ignore_ascii_case("DataOrientation") {
                        orientation = v.to_uppercase();
                    } else if k.eq_ignore_ascii_case("NumberOfChannels") {
                        num_channels = v.parse().unwrap_or(0);
                    } else if k.eq_ignore_ascii_case("SamplingInterval") {
                        sampling_interval_us = v.parse().unwrap_or(0.0);
                    }
                }
                "Binary Infos" => {
                    if k.eq_ignore_ascii_case("BinaryFormat") {
                        binary_format = v.to_uppercase();
                    }
                }
                "Channel Infos" => {
                    if k.to_lowercase().starts_with("ch") {
                        if let Ok(ch_idx) = k[2..].parse::<usize>() {
                            let parts: Vec<&str> = v.split(',').collect();
                            let name = if !parts.is_empty() && !parts[0].trim().is_empty() {
                                parts[0].trim().to_string()
                            } else {
                                format!("Ch{}", ch_idx)
                            };
                            channel_names.insert(ch_idx, name);
                            let res = if parts.len() >= 3 && !parts[2].trim().is_empty() {
                                parts[2].trim().parse::<f32>().unwrap_or(1.0)
                            } else {
                                1.0
                            };
                            channel_resolutions.insert(ch_idx, res);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    if sampling_interval_us <= 0.0 {
        return Err(format!("Invalid SamplingInterval {} in .vhdr", sampling_interval_us));
    }
    let rate = 1_000_000.0 / sampling_interval_us;
    if num_channels == 0 {
        return Err("NumberOfChannels is 0 in .vhdr".to_string());
    }

    let mut labels = Vec::with_capacity(num_channels);
    let mut resolutions = Vec::with_capacity(num_channels);
    for i in 1..=num_channels {
        labels.push(channel_names.get(&i).cloned().unwrap_or_else(|| format!("Ch{}", i)));
        resolutions.push(channel_resolutions.get(&i).cloned().unwrap_or(1.0));
    }

    let parent = path.parent().unwrap_or_else(|| Path::new(""));
    let mut data_path = parent.join(&data_file);
    if data_file.is_empty() || !data_path.exists() {
        let eeg_path = path.with_extension("eeg");
        let dat_path = path.with_extension("dat");
        if eeg_path.exists() {
            data_path = eeg_path;
        } else if dat_path.exists() {
            data_path = dat_path;
        } else {
            return Err(format!("Companion data file not found for {}", path.display()));
        }
    }

    let bytes = fs::read(&data_path)
        .map_err(|e| format!("Failed reading EEG data file {}: {}", data_path.display(), e))?;

    let bytes_per_sample = match binary_format.as_str() {
        "INT_16" | "UINT_16" => 2,
        "INT_32" => 4,
        _ => 4, // IEEE_FLOAT_32
    };

    let bm = match binary_format.as_str() {
        "INT_16" => Bm::I16,
        "UINT_16" => Bm::U16,
        "INT_32" => Bm::I32,
        _ => Bm::F32,
    };

    let total_samples = bytes.len() / (num_channels * bytes_per_sample);
    if total_samples == 0 {
        return Err(format!("Data file {} contains 0 complete samples", data_path.display()));
    }

    let mut channels = vec![vec![0.0f32; total_samples]; num_channels];

    if orientation == "VECTORIZED" {
        for c in 0..num_channels {
            let res = resolutions[c];
            let ch_slice = &mut channels[c];
            for s in 0..total_samples {
                let offset = (c * total_samples + s) * bytes_per_sample;
                if offset + bytes_per_sample <= bytes.len() {
                    let v = match bm {
                        Bm::I16 => i16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::U16 => u16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::I32 => i32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]) as f32,
                        Bm::F32 => f32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]),
                    };
                    ch_slice[s] = v * res;
                }
            }
        }
    } else {
        // MULTIPLEXED
        let mut offset = 0;
        for s in 0..total_samples {
            for c in 0..num_channels {
                if offset + bytes_per_sample <= bytes.len() {
                    let v = match bm {
                        Bm::I16 => i16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::U16 => u16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::I32 => i32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]) as f32,
                        Bm::F32 => f32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]),
                    };
                    channels[c][s] = v * resolutions[c];
                    offset += bytes_per_sample;
                }
            }
        }
    }

    Ok(Recording {
        rate,
        labels,
        channels,
        source_epoch_samples: None,
        epoch_labels: None,
    })
}
