//! Raw little-endian binary exchange format used between MATLAB/Python validation scripts and the Rust CLI.
//! Matrices are stored row-major (C order) as float64 unless noted.

use crate::linalg::Mat;
use std::fs;
use std::path::Path;

pub fn read_f64(path: &Path) -> Result<Vec<f64>, String> {
    let b = fs::read(path).map_err(|e| format!("{}: {}", path.display(), e))?;
    if b.len() % 8 != 0 {
        return Err(format!("{}: size not a multiple of 8", path.display()));
    }
    Ok(b.chunks_exact(8).map(|c| f64::from_le_bytes(c.try_into().unwrap())).collect())
}

pub fn read_i32(path: &Path) -> Result<Vec<i32>, String> {
    let b = fs::read(path).map_err(|e| format!("{}: {}", path.display(), e))?;
    Ok(b.chunks_exact(4).map(|c| i32::from_le_bytes(c.try_into().unwrap())).collect())
}

pub fn read_f32(path: &Path) -> Result<Vec<f32>, String> {
    let b = fs::read(path).map_err(|e| format!("{}: {}", path.display(), e))?;
    Ok(b.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect())
}

pub fn write_f64(path: &Path, v: &[f64]) -> Result<(), String> {
    let mut b = Vec::with_capacity(v.len() * 8);
    for x in v {
        b.extend_from_slice(&x.to_le_bytes());
    }
    fs::write(path, b).map_err(|e| format!("{}: {}", path.display(), e))
}

pub fn write_f32(path: &Path, v: &[f32]) -> Result<(), String> {
    let mut b = Vec::with_capacity(v.len() * 4);
    for x in v {
        b.extend_from_slice(&x.to_le_bytes());
    }
    fs::write(path, b).map_err(|e| format!("{}: {}", path.display(), e))
}

/// Read a row-major `rows x cols` matrix.
pub fn read_mat(path: &Path, rows: usize, cols: usize) -> Result<Mat, String> {
    let v = read_f64(path)?;
    if v.len() != rows * cols {
        return Err(format!("{}: expected {}x{} values, found {}", path.display(), rows, cols, v.len()));
    }
    Ok(Mat::from_row_slice(rows, cols, &v))
}

/// Write a matrix row-major.
pub fn write_mat(path: &Path, m: &Mat) -> Result<(), String> {
    let mut v = Vec::with_capacity(m.nrows() * m.ncols());
    for i in 0..m.nrows() {
        for j in 0..m.ncols() {
            v.push(m[(i, j)]);
        }
    }
    write_f64(path, &v)
}

pub fn read_json(path: &Path) -> Result<serde_json::Value, String> {
    let s = fs::read_to_string(path).map_err(|e| format!("{}: {}", path.display(), e))?;
    serde_json::from_str(&s).map_err(|e| format!("{}: {}", path.display(), e))
}
