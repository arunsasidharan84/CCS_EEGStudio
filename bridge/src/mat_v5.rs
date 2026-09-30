//! Minimal MATLAB v5 reader for the nested structs/cells used by FieldTrip.
//!
//! The `matfile` crate only exposes numeric top-level arrays. FieldTrip stores
//! recordings in a struct, so this module also handles structs, cells, chars,
//! and zlib-compressed matrix elements.

use flate2::read::ZlibDecoder;
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;

const MI_INT8: u32 = 1;
const MI_UINT8: u32 = 2;
const MI_INT16: u32 = 3;
const MI_UINT16: u32 = 4;
const MI_INT32: u32 = 5;
const MI_UINT32: u32 = 6;
const MI_SINGLE: u32 = 7;
const MI_DOUBLE: u32 = 9;
const MI_INT64: u32 = 12;
const MI_UINT64: u32 = 13;
const MI_MATRIX: u32 = 14;
const MI_COMPRESSED: u32 = 15;
const MI_UTF8: u32 = 16;
const MI_UTF16: u32 = 17;

const MX_CELL_CLASS: u8 = 1;
const MX_STRUCT_CLASS: u8 = 2;
const MX_CHAR_CLASS: u8 = 4;

#[derive(Debug, Clone, Default)]
pub struct MatValue {
    pub name: String,
    pub dims: Vec<usize>,
    pub numeric: Vec<f64>,
    pub text: String,
    pub fields: HashMap<String, Vec<MatValue>>,
}

struct Tag<'a> {
    tag_type: u32,
    data: &'a [u8],
    next_offset: usize,
}

fn u32_le(data: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        data.get(offset..offset + 4)?.try_into().ok()?,
    ))
}

fn padding(length: usize) -> usize {
    (8 - length % 8) % 8
}

impl<'a> Tag<'a> {
    fn read(bytes: &'a [u8], offset: usize) -> Option<Self> {
        let raw_type = u32_le(bytes, offset)?;
        let small_len = raw_type >> 16;
        if small_len > 0 {
            let len = small_len as usize;
            return Some(Self {
                tag_type: raw_type & 0xffff,
                data: bytes.get(offset + 4..offset + 4 + len)?,
                next_offset: offset.checked_add(8)?,
            });
        }
        let len = u32_le(bytes, offset + 4)? as usize;
        let start = offset.checked_add(8)?;
        let end = start.checked_add(len)?;
        Some(Self {
            tag_type: raw_type,
            data: bytes.get(start..end)?,
            next_offset: end.checked_add(padding(len))?,
        })
    }
}

fn integers(data: &[u8], tag_type: u32) -> Vec<usize> {
    match tag_type {
        MI_INT32 | MI_UINT32 => data
            .chunks_exact(4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()) as usize)
            .collect(),
        MI_INT16 | MI_UINT16 => data
            .chunks_exact(2)
            .map(|b| u16::from_le_bytes(b.try_into().unwrap()) as usize)
            .collect(),
        MI_INT8 | MI_UINT8 => data.iter().map(|&v| v as usize).collect(),
        _ => Vec::new(),
    }
}

fn numbers(data: &[u8], tag_type: u32) -> Vec<f64> {
    match tag_type {
        MI_DOUBLE => data
            .chunks_exact(8)
            .map(|b| f64::from_le_bytes(b.try_into().unwrap()))
            .collect(),
        MI_SINGLE => data
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()) as f64)
            .collect(),
        MI_INT8 => data.iter().map(|&v| (v as i8) as f64).collect(),
        MI_UINT8 => data.iter().map(|&v| v as f64).collect(),
        MI_INT16 => data
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes(b.try_into().unwrap()) as f64)
            .collect(),
        MI_UINT16 => data
            .chunks_exact(2)
            .map(|b| u16::from_le_bytes(b.try_into().unwrap()) as f64)
            .collect(),
        MI_INT32 => data
            .chunks_exact(4)
            .map(|b| i32::from_le_bytes(b.try_into().unwrap()) as f64)
            .collect(),
        MI_UINT32 => data
            .chunks_exact(4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()) as f64)
            .collect(),
        MI_INT64 => data
            .chunks_exact(8)
            .map(|b| i64::from_le_bytes(b.try_into().unwrap()) as f64)
            .collect(),
        MI_UINT64 => data
            .chunks_exact(8)
            .map(|b| u64::from_le_bytes(b.try_into().unwrap()) as f64)
            .collect(),
        _ => Vec::new(),
    }
}

fn text(data: &[u8], tag_type: u32) -> String {
    let result = match tag_type {
        MI_UINT16 | MI_INT16 | MI_UTF16 => String::from_utf16_lossy(
            &data
                .chunks_exact(2)
                .map(|b| u16::from_le_bytes(b.try_into().unwrap()))
                .filter(|&c| c != 0)
                .collect::<Vec<_>>(),
        ),
        MI_UTF8 | MI_INT8 | MI_UINT8 => String::from_utf8_lossy(data).into_owned(),
        _ => numbers(data, tag_type)
            .into_iter()
            .filter_map(|v| char::from_u32(v as u32))
            .collect(),
    };
    result.trim_matches(char::from(0)).trim().to_string()
}

fn matrix_element(bytes: &[u8], offset: usize) -> Option<(MatValue, usize)> {
    let tag = Tag::read(bytes, offset)?;
    (tag.tag_type == MI_MATRIX)
        .then(|| matrix(tag.data, 0, tag.data.len()).map(|(v, _)| (v, tag.next_offset)))?
}

fn matrix(bytes: &[u8], mut offset: usize, end: usize) -> Option<(MatValue, usize)> {
    let flags = Tag::read(bytes, offset)?;
    offset = flags.next_offset;
    let class_id = *flags.data.first()?;
    let dims_tag = Tag::read(bytes, offset)?;
    offset = dims_tag.next_offset;
    let dims = integers(dims_tag.data, dims_tag.tag_type);
    let name_tag = Tag::read(bytes, offset)?;
    offset = name_tag.next_offset;
    let name = String::from_utf8_lossy(name_tag.data)
        .trim_matches(char::from(0))
        .trim()
        .to_string();

    if class_id == MX_STRUCT_CLASS {
        let length_tag = Tag::read(bytes, offset)?;
        offset = length_tag.next_offset;
        let field_len = integers(length_tag.data, length_tag.tag_type)
            .first()
            .copied()?;
        if field_len == 0 {
            return None;
        }
        let names_tag = Tag::read(bytes, offset)?;
        offset = names_tag.next_offset;
        let names: Vec<String> = names_tag
            .data
            .chunks(field_len)
            .map(|b| {
                String::from_utf8_lossy(b)
                    .trim_matches(char::from(0))
                    .trim()
                    .to_string()
            })
            .filter(|s| !s.is_empty())
            .collect();
        let count = dims.iter().copied().product::<usize>();
        let mut fields: HashMap<String, Vec<MatValue>> =
            names.iter().map(|n| (n.clone(), Vec::new())).collect();
        for _ in 0..count {
            for field in &names {
                let (value, next) = matrix_element(bytes, offset)?;
                offset = next;
                fields.get_mut(field)?.push(value);
            }
        }
        return Some((
            MatValue {
                name,
                dims,
                fields,
                ..Default::default()
            },
            offset,
        ));
    }

    if class_id == MX_CELL_CLASS {
        let count = dims.iter().copied().product::<usize>();
        let mut values = Vec::with_capacity(count);
        for _ in 0..count {
            let (value, next) = matrix_element(bytes, offset)?;
            offset = next;
            values.push(value);
        }
        let mut fields = HashMap::new();
        fields.insert("cell".to_string(), values);
        return Some((
            MatValue {
                name,
                dims,
                fields,
                ..Default::default()
            },
            offset,
        ));
    }

    let value_tag = (offset < end).then(|| Tag::read(bytes, offset)).flatten();
    offset = value_tag.as_ref().map_or(offset, |t| t.next_offset);
    if class_id == MX_CHAR_CLASS {
        return Some((
            MatValue {
                name,
                dims,
                text: value_tag.map_or_else(String::new, |t| text(t.data, t.tag_type)),
                ..Default::default()
            },
            offset,
        ));
    }
    Some((
        MatValue {
            name,
            dims,
            numeric: value_tag.map_or_else(Vec::new, |t| numbers(t.data, t.tag_type)),
            ..Default::default()
        },
        offset,
    ))
}

/// Reads all top-level variables from a little-endian MATLAB v5 file.
pub fn load(path: &Path) -> Result<HashMap<String, MatValue>, String> {
    let bytes = fs::read(path).map_err(|e| e.to_string())?;
    if bytes.len() < 136 || &bytes[..6] != b"MATLAB" {
        return Err("Only MATLAB v5 MAT files are supported (not v7.3/HDF5).".into());
    }
    if bytes.get(126..128) != Some(b"IM") {
        return Err("Big-endian MATLAB v5 files are not currently supported.".into());
    }
    let mut out = HashMap::new();
    let mut offset = 128;
    while let Some(tag) = Tag::read(&bytes, offset) {
        offset = tag.next_offset;
        let value = match tag.tag_type {
            MI_MATRIX => matrix(tag.data, 0, tag.data.len()).map(|v| v.0),
            MI_COMPRESSED => {
                let mut inflated = Vec::new();
                ZlibDecoder::new(tag.data)
                    .read_to_end(&mut inflated)
                    .map_err(|e| format!("Invalid compressed MAT element: {e}"))?;
                matrix_element(&inflated, 0).map(|v| v.0)
            }
            _ => None,
        };
        if let Some(value) = value {
            out.insert(value.name.clone(), value);
        }
        if offset >= bytes.len() {
            break;
        }
    }
    Ok(out)
}
