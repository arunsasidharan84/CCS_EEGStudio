//! MNE FIF loader covering both epoched FIF and continuous raw FIF files.

use crate::Recording;
use std::fs;
use std::path::Path;

const FIFF_NCHAN: i32 = 200;
const FIFF_SFREQ: i32 = 201;
const FIFF_CH_INFO: i32 = 203;
const FIFF_DATA_BUFFER: i32 = 300;
const FIFF_DATA_SKIP: i32 = 301;

const FIFFT_BYTE: i32 = 1;
const FIFFT_SHORT: i32 = 2;
const FIFFT_INT: i32 = 3;
const FIFFT_FLOAT: i32 = 4;
const FIFFT_DOUBLE: i32 = 5;

#[derive(Debug)]
struct ChannelInfo {
    name: String,
    calibration: f32,
}

fn i32_be(data: &[u8], offset: usize) -> Result<i32, String> {
    Ok(i32::from_be_bytes(
        data.get(offset..offset + 4)
            .ok_or("Truncated FIF integer")?
            .try_into()
            .unwrap(),
    ))
}

fn f32_be(data: &[u8], offset: usize) -> Result<f32, String> {
    Ok(f32::from_be_bytes(
        data.get(offset..offset + 4)
            .ok_or("Truncated FIF float")?
            .try_into()
            .unwrap(),
    ))
}

fn primitive_values(data: &[u8], data_type: i32) -> Result<Vec<f32>, String> {
    match data_type & 0xffff {
        FIFFT_BYTE => Ok(data.iter().map(|&v| v as f32).collect()),
        FIFFT_SHORT => Ok(data
            .chunks_exact(2)
            .map(|b| i16::from_be_bytes(b.try_into().unwrap()) as f32)
            .collect()),
        FIFFT_INT => Ok(data
            .chunks_exact(4)
            .map(|b| i32::from_be_bytes(b.try_into().unwrap()) as f32)
            .collect()),
        FIFFT_FLOAT => Ok(data
            .chunks_exact(4)
            .map(|b| f32::from_be_bytes(b.try_into().unwrap()))
            .collect()),
        FIFFT_DOUBLE => Ok(data
            .chunks_exact(8)
            .map(|b| f64::from_be_bytes(b.try_into().unwrap()) as f32)
            .collect()),
        kind => Err(format!("Unsupported MNE raw FIF data type {kind}")),
    }
}

fn load_raw_fif(path: &Path) -> Result<Recording, String> {
    let bytes = fs::read(path).map_err(|e| format!("failed to read FIF file: {e}"))?;
    let mut offset = 0;
    let mut rate = None;
    let mut declared_channels = None;
    let mut infos = Vec::new();
    let mut channels: Vec<Vec<f32>> = Vec::new();
    let mut pending_skips = 0_usize;

    while offset + 16 <= bytes.len() {
        let kind = i32_be(&bytes, offset)?;
        let data_type = i32_be(&bytes, offset + 4)?;
        let size = i32_be(&bytes, offset + 8)?;
        if size < 0 {
            return Err("Invalid negative FIF tag size".into());
        }
        let start = offset + 16;
        let end = start
            .checked_add(size as usize)
            .ok_or("FIF tag size overflow")?;
        let data = bytes.get(start..end).ok_or("Truncated FIF tag")?;
        match kind {
            FIFF_NCHAN if data.len() >= 4 => {
                declared_channels = Some(i32_be(data, 0)? as usize);
            }
            FIFF_SFREQ if data.len() >= 4 => rate = Some(f32_be(data, 0)? as f64),
            FIFF_CH_INFO if data.len() >= 96 => {
                let name_bytes = &data[80..96];
                let name_end = name_bytes
                    .iter()
                    .position(|&byte| byte == 0)
                    .unwrap_or(name_bytes.len());
                infos.push(ChannelInfo {
                    name: String::from_utf8_lossy(&name_bytes[..name_end])
                        .trim()
                        .to_string(),
                    calibration: f32_be(data, 12)? * f32_be(data, 16)?,
                });
            }
            FIFF_DATA_SKIP if data.len() >= 4 => {
                pending_skips = i32_be(data, 0)?.max(0) as usize;
            }
            FIFF_DATA_BUFFER => {
                let n_channels = declared_channels.unwrap_or(infos.len());
                if n_channels == 0 {
                    return Err("MNE raw FIF data precedes channel metadata".into());
                }
                if channels.is_empty() {
                    if infos.len() < n_channels {
                        return Err("MNE raw FIF channel metadata is incomplete".into());
                    }
                    infos.truncate(n_channels);
                    channels = vec![Vec::new(); n_channels];
                }
                let values = primitive_values(data, data_type)?;
                if values.len() % n_channels != 0 {
                    return Err("MNE raw FIF data buffer has an invalid channel count".into());
                }
                let samples = values.len() / n_channels;
                if pending_skips > 0 {
                    let missing = samples.saturating_mul(pending_skips);
                    for channel in &mut channels {
                        channel.resize(channel.len() + missing, 0.0);
                    }
                    pending_skips = 0;
                }
                // MNE raw buffers store channels interleaved for each sample.
                for sample in 0..samples {
                    for channel in 0..n_channels {
                        channels[channel].push(
                            values[sample * n_channels + channel] * infos[channel].calibration,
                        );
                    }
                }
            }
            _ => {}
        }
        offset = end;
    }

    if channels.is_empty() {
        return Err("FIF file contains neither epoch nor raw data".into());
    }
    // The rest of the engine uses microvolts. MNE stores EEG in SI volts;
    // retain already-large auxiliary channels (e.g. PPG/status) as written.
    for channel in &mut channels {
        let max_abs = channel.iter().fold(0.0_f32, |m, v| m.max(v.abs()));
        if max_abs > 0.0 && max_abs < 0.1 {
            for sample in channel {
                *sample *= 1e6;
            }
        }
    }
    Ok(Recording {
        rate: rate.ok_or("MNE raw FIF sampling frequency is missing")?,
        labels: infos.into_iter().map(|info| info.name).collect(),
        channels,
        source_epoch_samples: None,
        epoch_labels: None,
    })
}

/// Uses the established epoched-FIF reader first and falls back to raw FIF.
pub fn load_fif(path: &Path) -> Result<Recording, String> {
    match ccs_algorithm::eeg::fif_loader::load_fif(path) {
        Ok(recording) => Ok(recording),
        Err(epoch_error) if epoch_error.contains("no epoch data") => load_raw_fif(path),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_big_endian_raw_values() {
        let bytes = [1.5_f32.to_be_bytes(), (-2.25_f32).to_be_bytes()].concat();
        assert_eq!(primitive_values(&bytes, FIFFT_FLOAT).unwrap(), [1.5, -2.25]);
    }
}
