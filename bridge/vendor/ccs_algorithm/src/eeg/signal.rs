use rustfft::{num_complex::Complex64, FftPlanner};

pub fn hamming(size: usize) -> Vec<f64> {
    (0..size)
        .map(|index| 0.54 - 0.46 * (2.0 * std::f64::consts::PI * index as f64 / size as f64).cos())
        .collect()
}

pub fn rfft_power(signal: &[f64]) -> Vec<f64> {
    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(signal.len());
    let mut buffer: Vec<Complex64> = signal
        .iter()
        .map(|&value| Complex64::new(value, 0.0))
        .collect();
    fft.process(&mut buffer);
    buffer[..=signal.len() / 2]
        .iter()
        .map(|value| value.norm_sqr())
        .collect()
}
