use flate2::read::ZlibDecoder;
use std::collections::HashMap;
use std::fs::File;
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
const MI_MATRIX: u32 = 14;
const MI_COMPRESSED: u32 = 15;

const MX_CELL_CLASS: u8 = 1;
const MX_STRUCT_CLASS: u8 = 2;
const MX_CHAR_CLASS: u8 = 4;

#[derive(Debug, Clone)]
pub struct MatValue {
    pub name: String,
    pub dims: Vec<u32>,
    pub numeric: Vec<f64>,
    pub text: String,
    pub fields: HashMap<String, Vec<MatValue>>,
}

struct Tag {
    tag_type: u32,
    data: Vec<u8>,
    next_offset: usize,
}

fn read_u32_le(data: &[u8], offset: usize) -> u32 {
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&data[offset..offset + 4]);
    u32::from_le_bytes(buf)
}

fn padding(length: usize) -> usize {
    let remainder = length % 8;
    if remainder == 0 { 0 } else { 8 - remainder }
}

impl Tag {
    fn read(bytes: &[u8], offset: usize) -> Option<Tag> {
        if offset + 8 > bytes.len() { return None; }
        let raw_type = read_u32_le(bytes, offset);
        let small_bytes = raw_type >> 16;
        if small_bytes > 0 {
            let tag_type = raw_type & 0xFFFF;
            let len = small_bytes as usize;
            if offset + 4 + len > bytes.len() { return None; }
            return Some(Tag {
                tag_type,
                data: bytes[offset + 4..offset + 4 + len].to_vec(),
                next_offset: offset + 8,
            });
        }
        let byte_count = read_u32_le(bytes, offset + 4) as usize;
        let data_offset = offset + 8;
        let pad = padding(byte_count);
        if data_offset + byte_count > bytes.len() { return None; }
        Some(Tag {
            tag_type: raw_type,
            data: bytes[data_offset..data_offset + byte_count].to_vec(),
            next_offset: data_offset + byte_count + pad,
        })
    }
}

fn read_ints(data: &[u8], tag_type: u32) -> Vec<u32> {
    let mut values = Vec::new();
    if tag_type == MI_INT32 || tag_type == MI_UINT32 {
        for i in (0..data.len()).step_by(4) {
            if i + 4 <= data.len() { values.push(read_u32_le(data, i)); }
        }
    } else if tag_type == MI_INT16 || tag_type == MI_UINT16 {
        for i in (0..data.len()).step_by(2) {
            if i + 2 <= data.len() {
                let mut buf = [0u8; 2];
                buf.copy_from_slice(&data[i..i + 2]);
                values.push(u16::from_le_bytes(buf) as u32);
            }
        }
    } else if tag_type == MI_INT8 || tag_type == MI_UINT8 {
        for &b in data { values.push(b as u32); }
    }
    values
}

fn read_numbers(data: &[u8], tag_type: u32) -> Vec<f64> {
    let mut values = Vec::new();
    if tag_type == MI_DOUBLE {
        for i in (0..data.len()).step_by(8) {
            if i + 8 <= data.len() {
                let mut buf = [0u8; 8];
                buf.copy_from_slice(&data[i..i + 8]);
                values.push(f64::from_le_bytes(buf));
            }
        }
    } else if tag_type == MI_SINGLE {
        for i in (0..data.len()).step_by(4) {
            if i + 4 <= data.len() {
                let mut buf = [0u8; 4];
                buf.copy_from_slice(&data[i..i + 4]);
                values.push(f32::from_le_bytes(buf) as f64);
            }
        }
    } else {
        for v in read_ints(data, tag_type) {
            values.push(v as f64);
        }
    }
    values
}

fn read_text(data: &[u8], tag_type: u32) -> String {
    if tag_type == MI_UINT16 || tag_type == MI_INT16 {
        let mut codes = Vec::new();
        for i in (0..data.len()).step_by(2) {
            if i + 2 <= data.len() {
                let mut buf = [0u8; 2];
                buf.copy_from_slice(&data[i..i + 2]);
                let code = u16::from_le_bytes(buf);
                if code != 0 { codes.push(code as u8); } // Basic ASCII cast
            }
        }
        return String::from_utf8_lossy(&codes).trim().to_string();
    }
    let filtered: Vec<u8> = data.iter().copied().filter(|&b| b != 0).collect();
    String::from_utf8_lossy(&filtered).trim().to_string()
}

fn read_matrix_element(bytes: &[u8], offset: usize) -> Option<(MatValue, usize)> {
    let tag = Tag::read(bytes, offset)?;
    if tag.tag_type != MI_MATRIX { return None; }
    read_matrix(&tag.data, 0, tag.data.len()).map(|v| (v.0, tag.next_offset))
}

fn read_matrix(bytes: &[u8], mut offset: usize, end: usize) -> Option<(MatValue, usize)> {
    let flags = Tag::read(bytes, offset)?;
    offset = flags.next_offset;
    let class_id = if flags.data.is_empty() { 0 } else { flags.data[0] };

    let dims_tag = Tag::read(bytes, offset)?;
    offset = dims_tag.next_offset;
    let dims = read_ints(&dims_tag.data, dims_tag.tag_type);

    let name_tag = Tag::read(bytes, offset)?;
    offset = name_tag.next_offset;
    let name = String::from_utf8_lossy(&name_tag.data).replace('\x00', "").trim().to_string();

    if class_id == MX_STRUCT_CLASS {
        let field_length_tag = Tag::read(bytes, offset)?;
        offset = field_length_tag.next_offset;
        let field_name_length = read_ints(&field_length_tag.data, field_length_tag.tag_type).first().copied().unwrap_or(0) as usize;
        
        let field_names_tag = Tag::read(bytes, offset)?;
        offset = field_names_tag.next_offset;
        let mut field_names = Vec::new();
        let mut i = 0;
        while i + field_name_length <= field_names_tag.data.len() {
            let fname = String::from_utf8_lossy(&field_names_tag.data[i..i + field_name_length])
                .replace('\x00', "").trim().to_string();
            if !fname.is_empty() {
                field_names.push(fname);
            }
            i += field_name_length;
        }

        let element_count = dims.iter().fold(1, |a, &b| a * b);
        let mut values: HashMap<String, Vec<MatValue>> = HashMap::new();
        for f in &field_names {
            values.insert(f.clone(), Vec::new());
        }

        for _ in 0..element_count {
            for field in &field_names {
                if offset >= end { break; }
                if let Some((val, next)) = read_matrix_element(bytes, offset) {
                    offset = next;
                    values.get_mut(field).unwrap().push(val);
                } else {
                    break;
                }
            }
        }
        return Some((MatValue { name, dims, numeric: Vec::new(), text: String::new(), fields: values }, offset));
    }

    if class_id == MX_CELL_CLASS {
        let mut values = Vec::new();
        while offset < end {
            if let Some((val, next)) = read_matrix_element(bytes, offset) {
                offset = next;
                values.push(val);
            } else {
                break;
            }
        }
        let mut fields = HashMap::new();
        fields.insert("cell".to_string(), values);
        return Some((MatValue { name, dims, numeric: Vec::new(), text: String::new(), fields }, offset));
    }

    if class_id == MX_CHAR_CLASS {
        let text_tag = if offset < end { Tag::read(bytes, offset) } else { None };
        offset = text_tag.as_ref().map(|t| t.next_offset).unwrap_or(offset);
        let text = text_tag.map(|t| read_text(&t.data, t.tag_type)).unwrap_or_default();
        return Some((MatValue { name, dims, numeric: Vec::new(), text, fields: HashMap::new() }, offset));
    }

    let numeric_tag = if offset < end { Tag::read(bytes, offset) } else { None };
    offset = numeric_tag.as_ref().map(|t| t.next_offset).unwrap_or(offset);
    let numeric = numeric_tag.map(|t| read_numbers(&t.data, t.tag_type)).unwrap_or_default();
    Some((MatValue { name, dims, numeric, text: String::new(), fields: HashMap::new() }, offset))
}

pub fn load_set(path: &Path) -> Result<MatValue, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    
    if bytes.len() < 136 || &bytes[0..6] != b"MATLAB" {
        return Err("Only MATLAB v5 MAT files are supported.".into());
    }

    let mut offset = 128;
    let mut top_level: HashMap<String, Vec<MatValue>> = HashMap::new();
    
    while offset + 8 <= bytes.len() {
        if let Some(tag) = Tag::read(&bytes, offset) {
            offset = tag.next_offset;
            if tag.tag_type == MI_COMPRESSED {
                let mut decoder = ZlibDecoder::new(&tag.data[..]);
                let mut inflated = Vec::new();
                if decoder.read_to_end(&mut inflated).is_ok() {
                    if let Some((value, _)) = read_matrix_element(&inflated, 0) {
                        if value.name == "EEG" { return Ok(value); }
                        top_level.entry(value.name.clone()).or_default().push(value);
                    }
                }
            } else if tag.tag_type == MI_MATRIX {
                if let Some((value, _)) = read_matrix(&tag.data, 0, tag.data.len()) {
                    if value.name == "EEG" { return Ok(value); }
                    top_level.entry(value.name.clone()).or_default().push(value);
                }
            }
        } else {
            break;
        }
    }
    
    if top_level.contains_key("srate") && top_level.contains_key("data") {
        return Ok(MatValue {
            name: "EEG".to_string(),
            dims: vec![1, 1],
            numeric: Vec::new(),
            text: String::new(),
            fields: top_level,
        });
    }
    
    Err("SET file does not contain EEGLAB metadata.".into())
}
