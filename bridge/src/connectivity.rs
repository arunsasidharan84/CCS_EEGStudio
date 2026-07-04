use nalgebra::{DMatrix, SymmetricEigen};
use rustfft::{num_complex::Complex64, FftPlanner};

use crate::{Options, BANDS};

const N_FREQS: usize = 15;
const GC_LAGS: usize = 25;

pub fn column_names(options: &Options) -> Vec<String> {
    let mut names = Vec::new();
    for (enabled, metric) in [
        (options.mic, "mic"),
        (options.mim, "mim"),
        (options.gc, "gc"),
        (options.gc_tr, "gc_tr"),
        (options.coh, "coh"),
        (options.plv, "plv"),
        (options.ciplv, "ciplv"),
        (options.pli, "pli"),
        (options.wpli, "wpli"),
    ] {
        if enabled {
            names.extend(
                BANDS[1..]
                    .iter()
                    .map(|band| format!("conn_{metric}_{}", band.2)),
            );
        }
    }
    names
}

pub fn compute_epoch(
    channels: &[Vec<f32>],
    labels: &[String],
    start: usize,
    end: usize,
    sfreq: f64,
    options: &Options,
) -> Vec<Vec<f64>> {
    let n_channels = channels.len();
    let mut output = vec![Vec::new(); n_channels];
    if !options.connectivity || start >= end {
        return output;
    }
    let data: Vec<Vec<f64>> = channels
        .iter()
        .map(|channel| {
            channel[start..end]
                .iter()
                .map(|value| *value as f64)
                .collect()
        })
        .collect();
    let frequencies = logspace(4.0, 40.0, N_FREQS);
    let cycles: Vec<f64> = logspace(3.0, 20.0, N_FREQS)
        .into_iter()
        .map(|value| value as usize as f64)
        .collect();
    let coefficients = morlet_coefficients(&data, sfreq, &frequencies, &cycles);

    let multivariate = multivariate_scores(&coefficients, labels, options);
    for (enabled, values) in [
        (options.mic, multivariate.mic.as_slice()),
        (options.mim, multivariate.mim.as_slice()),
        (options.gc, multivariate.gc.as_slice()),
        (options.gc_tr, multivariate.gc_tr.as_slice()),
    ] {
        if enabled {
            let bands = band_means(&values, &frequencies);
            for channel in &mut output {
                channel.extend_from_slice(&bands);
            }
        }
    }

    let bivariate = bivariate_scores(&coefficients, options);
    for channel in 0..n_channels {
        for metric in &bivariate[channel] {
            output[channel].extend(band_means(metric, &frequencies));
        }
    }
    output
}

struct MultivariateScores {
    mic: Vec<f64>,
    mim: Vec<f64>,
    gc: Vec<f64>,
    gc_tr: Vec<f64>,
}

fn multivariate_scores(
    coefficients: &[Vec<Vec<Complex64>>],
    labels: &[String],
    options: &Options,
) -> MultivariateScores {
    let mut seeds: Vec<usize> = labels
        .iter()
        .enumerate()
        .filter(|(_, l)| {
            let u = l.to_uppercase();
            u.starts_with('F') || u.contains("FRONTAL")
        })
        .map(|(index, _)| index)
        .collect();
    let mut targets: Vec<usize> = labels
        .iter()
        .enumerate()
        .filter(|(_, l)| {
            let u = l.to_uppercase();
            u.starts_with('P') || u.starts_with('O') || u.contains("PARIETAL") || u.contains("OCCIPITAL")
        })
        .map(|(index, _)| index)
        .collect();
    let empty = || vec![f64::NAN; N_FREQS];
    if seeds.is_empty() || targets.is_empty() {
        let n = labels.len();
        if n >= 2 {
            seeds = (0..n / 2).collect();
            targets = (n / 2..n).collect();
        } else {
            return MultivariateScores {
                mic: empty(),
                mim: empty(),
                gc: empty(),
                gc_tr: empty(),
            };
        }
    }
    let indices: Vec<usize> = seeds.iter().chain(&targets).copied().collect();
    let csd = csd_matrices(coefficients, &indices);
    let mut mic = empty();
    let mut mim = empty();
    if options.mic || options.mim {
        for (frequency, matrix) in csd.iter().enumerate() {
            let e = imaginary_coherency(matrix, seeds.len());
            if options.mim {
                mim[frequency] = e.iter().map(|value| value * value).sum();
            }
            if options.mic {
                let left = SymmetricEigen::new(&e * e.transpose());
                let right = SymmetricEigen::new(e.transpose() * &e);
                let alpha = lapack_orient(
                    left.eigenvectors
                        .column(left.eigenvalues.imax())
                        .into_owned(),
                );
                let beta = lapack_orient(
                    right
                        .eigenvectors
                        .column(right.eigenvalues.imax())
                        .into_owned(),
                );
                mic[frequency] =
                    (alpha.transpose() * &e * &beta)[(0, 0)] / (alpha.norm() * beta.norm());
            }
        }
    }
    let gc = if options.gc {
        granger(&csd, seeds.len(), false)
    } else {
        empty()
    };
    let gc_tr = if options.gc_tr {
        granger(&csd, seeds.len(), true)
    } else {
        empty()
    };
    MultivariateScores {
        mic,
        mim,
        gc,
        gc_tr,
    }
}

fn csd_matrices(
    coefficients: &[Vec<Vec<Complex64>>],
    indices: &[usize],
) -> Vec<DMatrix<Complex64>> {
    (0..N_FREQS)
        .map(|frequency| {
            let times = coefficients[indices[0]][frequency].len();
            DMatrix::from_fn(indices.len(), indices.len(), |row, column| {
                coefficients[indices[row]][frequency]
                    .iter()
                    .zip(&coefficients[indices[column]][frequency])
                    .map(|(left, right)| *left * right.conj())
                    .sum::<Complex64>()
                    / times as f64
            })
        })
        .collect()
}

fn imaginary_coherency(csd: &DMatrix<Complex64>, n_seeds: usize) -> DMatrix<f64> {
    let n = csd.nrows();
    let real = DMatrix::from_fn(n, n, |row, column| csd[(row, column)].re);
    let mut transform = DMatrix::<f64>::zeros(n, n);
    for (offset, size) in [(0, n_seeds), (n_seeds, n - n_seeds)] {
        let block = real.view((offset, offset), (size, size)).into_owned();
        let eigen = SymmetricEigen::new(block);
        let maximum = eigen.eigenvalues.iter().copied().fold(0.0, f64::max);
        let inverse = DMatrix::from_diagonal(&eigen.eigenvalues.map(|value| {
            if value > maximum * 1e-6 {
                1.0 / value.sqrt()
            } else {
                0.0
            }
        }));
        let block_transform = &eigen.eigenvectors * inverse * eigen.eigenvectors.transpose();
        transform
            .view_mut((offset, offset), (size, size))
            .copy_from(&block_transform);
    }
    let t = transform.map(|value| Complex64::new(value, 0.0));
    let coherency = &t * csd * &t;
    DMatrix::from_fn(n_seeds, n - n_seeds, |row, column| {
        coherency[(row, n_seeds + column)].im
    })
}

fn lapack_orient(mut vector: nalgebra::DVector<f64>) -> nalgebra::DVector<f64> {
    let dominant = vector.iamax();
    let desired_sign = if dominant % 2 == 0 { -1.0 } else { 1.0 };
    if vector[dominant].signum() != desired_sign {
        vector *= -1.0;
    }
    vector
}

fn bivariate_scores(coefficients: &[Vec<Vec<Complex64>>], options: &Options) -> Vec<Vec<Vec<f64>>> {
    let enabled = [
        options.coh,
        options.plv,
        options.ciplv,
        options.pli,
        options.wpli,
    ];
    let metric_count = enabled.iter().filter(|value| **value).count();
    let n = coefficients.len();
    let mut output = vec![vec![vec![0.0; N_FREQS]; metric_count]; n];
    for left in 1..n {
        for right in 0..left {
            for frequency in 0..N_FREQS {
                let x = &coefficients[left][frequency];
                let y = &coefficients[right][frequency];
                let mut cross_sum = Complex64::new(0.0, 0.0);
                let mut power_x = 0.0;
                let mut power_y = 0.0;
                let mut phase_sum = Complex64::new(0.0, 0.0);
                let mut pli_sum = 0.0;
                let mut imag_sum = 0.0;
                let mut abs_imag_sum = 0.0;
                for (x, y) in x.iter().zip(y) {
                    let cross = *x * y.conj();
                    cross_sum += cross;
                    power_x += x.norm_sqr();
                    power_y += y.norm_sqr();
                    if cross.norm() > 0.0 {
                        phase_sum += cross / cross.norm();
                    }
                    pli_sum += cross.im.signum();
                    imag_sum += cross.im;
                    abs_imag_sum += cross.im.abs();
                }
                let count = x.len() as f64;
                let phase_mean = phase_sum / count;
                let values = [
                    cross_sum.norm() / (power_x * power_y).sqrt().max(f64::MIN_POSITIVE),
                    phase_mean.norm(),
                    phase_mean.im.abs() / (1.0 - phase_mean.re.abs().powi(2)).max(0.0).sqrt(),
                    (pli_sum / count).abs(),
                    imag_sum.abs() / abs_imag_sum.max(f64::MIN_POSITIVE),
                ];
                let mut metric = 0;
                for (is_enabled, value) in enabled.into_iter().zip(values) {
                    if is_enabled {
                        output[left][metric][frequency] += value / n as f64;
                        output[right][metric][frequency] += value / n as f64;
                        metric += 1;
                    }
                }
            }
        }
    }
    output
}

fn robust_cholesky(matrix: &DMatrix<f64>) -> Option<DMatrix<f64>> {
    let sym = (matrix + matrix.transpose()) * 0.5;
    if let Some(c) = sym.clone().cholesky() {
        return Some(c.l());
    }
    let eigen = SymmetricEigen::new(sym);
    let max_eval = eigen.eigenvalues.iter().copied().fold(1e-9, f64::max);
    let min_eval = max_eval * 1e-6;
    let clamped_evals = eigen.eigenvalues.map(|v| v.max(min_eval));
    let pos_def = &eigen.eigenvectors
        * DMatrix::from_diagonal(&clamped_evals)
        * eigen.eigenvectors.transpose();
    let sym_pos = (&pos_def + pos_def.transpose()) * 0.5;
    if let Some(c) = sym_pos.cholesky() {
        return Some(c.l());
    }
    Some(DMatrix::from_diagonal(&clamped_evals.map(|v| v.sqrt())))
}

fn granger(csd: &[DMatrix<Complex64>], n_seeds: usize, reversed: bool) -> Vec<f64> {
    let n = csd[0].nrows();
    if n_seeds == 0 || n_seeds == n || GC_LAGS >= (N_FREQS - 1) * 2 {
        return vec![f64::NAN; N_FREQS];
    }
    let autocov = autocovariance(csd, reversed);
    let Some((coefficients, covariance)) = whittle_lwr(&autocov, GC_LAGS) else {
        eprintln!("WARNING GC Whittle LWR solve failed for {n} signals");
        return vec![f64::NAN; N_FREQS];
    };
    let targets: Vec<usize> = (n_seeds..n).collect();
    let seeds: Vec<usize> = (0..n_seeds).collect();
    let partial = partial_covariance(&covariance, &seeds, &targets);
    let Some(chol_v) = robust_cholesky(&covariance) else {
        eprintln!("WARNING GC residual covariance is not positive definite for {n} signals");
        return vec![f64::NAN; N_FREQS];
    };
    let Some(chol_partial) = robust_cholesky(&partial) else {
        eprintln!("WARNING GC partial covariance is not positive definite for {n} signals");
        return vec![f64::NAN; N_FREQS];
    };
    (0..N_FREQS)
        .map(|frequency| {
            let omega = std::f64::consts::PI * frequency as f64 / (N_FREQS - 1) as f64;
            let mut ar = DMatrix::<Complex64>::identity(n, n);
            for lag in 0..GC_LAGS {
                let phase = Complex64::from_polar(1.0, -omega * (lag + 1) as f64);
                ar -= coefficients[lag].map(|value| Complex64::new(value, 0.0) * phase);
            }
            let h = match ar.clone().try_inverse() {
                Some(inv) => inv,
                None => {
                    let mut reg_ar = ar.clone();
                    for i in 0..n {
                        reg_ar[(i, i)] += Complex64::new(1e-6, 0.0);
                    }
                    match reg_ar.try_inverse() {
                        Some(inv) => inv,
                        None => return f64::NAN,
                    }
                }
            };
            let hv = &h * chol_v.map(|value| Complex64::new(value, 0.0));
            let spectrum = &hv * hv.adjoint();
            let s_tt = select_complex(&spectrum, &targets, &targets);
            let h_ts = select_complex(&h, &targets, &seeds);
            let contribution = &h_ts * chol_partial.map(|value| Complex64::new(value, 0.0));
            let reduced = &s_tt - &contribution * contribution.adjoint();
            let numerator = s_tt.determinant().re.max(1e-15).ln();
            let denominator = reduced.determinant().re.max(1e-15).ln();
            numerator - denominator
        })
        .collect()
}

fn autocovariance(csd: &[DMatrix<Complex64>], reversed: bool) -> Vec<DMatrix<f64>> {
    let n = csd[0].nrows();
    let resolution = (N_FREQS - 1) * 2;
    (0..=GC_LAGS)
        .map(|lag| {
            DMatrix::from_fn(n, n, |row, column| {
                let (row, column) = if reversed {
                    (column, row)
                } else {
                    (row, column)
                };
                let mut sequence = Vec::with_capacity(resolution);
                for index in (1..N_FREQS).rev() {
                    sequence.push(csd[index][(row, column)].conj());
                }
                for matrix in csd.iter().take(N_FREQS - 1) {
                    sequence.push(matrix[(row, column)]);
                }
                let value = sequence
                    .iter()
                    .enumerate()
                    .map(|(index, value)| {
                        let angle = 2.0 * std::f64::consts::PI * index as f64 * lag as f64
                            / resolution as f64;
                        *value * Complex64::from_polar(1.0, angle)
                    })
                    .sum::<Complex64>()
                    / resolution as f64;
                if lag % 2 == 0 {
                    value.re
                } else {
                    -value.re
                }
            })
        })
        .collect()
}

fn whittle_lwr(autocov: &[DMatrix<f64>], lags: usize) -> Option<(Vec<DMatrix<f64>>, DMatrix<f64>)> {
    let n = autocov[0].nrows();
    let qn = n * lags;
    let covariance = autocov[0].clone();
    let mut g_forward = DMatrix::<f64>::zeros(qn, n);
    let mut g_backward = DMatrix::<f64>::zeros(qn, n);
    for lag in 0..lags {
        g_forward
            .view_mut((lag * n, 0), (n, n))
            .copy_from(&autocov[lag + 1].transpose());
        g_backward
            .view_mut((lag * n, 0), (n, n))
            .copy_from(&autocov[lags - lag]);
    }
    let mut a_forward = DMatrix::<f64>::zeros(n, qn);
    let mut a_backward = DMatrix::<f64>::zeros(n, qn);
    let first_forward = solve_right(&autocov[1], &covariance)?;
    a_forward.view_mut((0, 0), (n, n)).copy_from(&first_forward);
    let first_backward = solve_right(&autocov[1].transpose(), &covariance)?;
    a_backward
        .view_mut((0, (lags - 1) * n), (n, n))
        .copy_from(&first_backward);

    for order in 2..=lags {
        let previous = order - 1;
        let previous_width = previous * n;
        let previous_backward_start = (lags - previous) * n;
        let a_f_previous = a_forward.view((0, 0), (n, previous_width)).into_owned();
        let a_b_previous = a_backward
            .view((0, previous_backward_start), (n, previous_width))
            .into_owned();
        let g_b_previous = g_backward
            .view((previous_backward_start, 0), (previous_width, n))
            .into_owned();
        let g_f_previous = g_forward.view((0, 0), (previous_width, n)).into_owned();

        let forward_target = g_backward
            .view(((lags - order) * n, 0), (n, n))
            .into_owned();
        let var_a_forward = forward_target - &a_f_previous * &g_b_previous;
        let var_b_forward = &covariance - &a_b_previous * &g_b_previous;
        let aa_forward = solve_right(&var_a_forward, &var_b_forward)?;

        let backward_target = g_forward.view(((order - 1) * n, 0), (n, n)).into_owned();
        let var_a_backward = backward_target - &a_b_previous * &g_f_previous;
        let var_b_backward = &covariance - &a_f_previous * &g_f_previous;
        let aa_backward = solve_right(&var_a_backward, &var_b_backward)?;

        let updated_forward = &a_f_previous - &aa_forward * &a_b_previous;
        a_forward
            .view_mut((0, 0), (n, previous_width))
            .copy_from(&updated_forward);
        a_forward
            .view_mut((0, previous_width), (n, n))
            .copy_from(&aa_forward);
        let backward_start = (lags - order) * n;
        let updated_backward = &a_b_previous - &aa_backward * &a_f_previous;
        a_backward
            .view_mut((0, backward_start), (n, n))
            .copy_from(&aa_backward);
        a_backward
            .view_mut((0, backward_start + n), (n, previous_width))
            .copy_from(&updated_backward);
    }
    let coefficients: Vec<DMatrix<f64>> = (0..lags)
        .map(|lag| a_forward.view((0, lag * n), (n, n)).into_owned())
        .collect();
    let residual = &covariance - &a_forward * &g_forward;
    Some((coefficients, residual))
}

fn solve_right(numerator: &DMatrix<f64>, denominator: &DMatrix<f64>) -> Option<DMatrix<f64>> {
    denominator
        .clone()
        .lu()
        .solve(&numerator.transpose())
        .map(|solution| solution.transpose())
}

fn partial_covariance(
    covariance: &DMatrix<f64>,
    seeds: &[usize],
    targets: &[usize],
) -> DMatrix<f64> {
    let v_ss = select_real(covariance, seeds, seeds);
    let v_st = select_real(covariance, seeds, targets);
    let v_tt = select_real(covariance, targets, targets);
    let v_ts = v_st.transpose();
    match v_tt.cholesky().map(|chol| chol.solve(&v_ts)) {
        Some(solution) => v_ss - v_st * solution,
        None => DMatrix::zeros(seeds.len(), seeds.len()),
    }
}

fn select_real(matrix: &DMatrix<f64>, rows: &[usize], columns: &[usize]) -> DMatrix<f64> {
    DMatrix::from_fn(rows.len(), columns.len(), |row, column| {
        matrix[(rows[row], columns[column])]
    })
}

fn select_complex(
    matrix: &DMatrix<Complex64>,
    rows: &[usize],
    columns: &[usize],
) -> DMatrix<Complex64> {
    DMatrix::from_fn(rows.len(), columns.len(), |row, column| {
        matrix[(rows[row], columns[column])]
    })
}

fn morlet_coefficients(
    data: &[Vec<f64>],
    sfreq: f64,
    frequencies: &[f64],
    cycles: &[f64],
) -> Vec<Vec<Vec<Complex64>>> {
    let wavelets: Vec<Vec<Complex64>> = frequencies
        .iter()
        .zip(cycles)
        .map(|(frequency, cycles)| morlet(sfreq, *frequency, *cycles))
        .collect();
    let n_times = data[0].len();
    let full = n_times + wavelets.iter().map(Vec::len).max().unwrap() - 1;
    let fft_size = next_fast_len(full);
    let mut planner = FftPlanner::<f64>::new();
    let forward = planner.plan_fft_forward(fft_size);
    let inverse = planner.plan_fft_inverse(fft_size);
    let wavelet_spectra: Vec<Vec<Complex64>> = wavelets
        .iter()
        .map(|wavelet| {
            let mut padded = vec![Complex64::new(0.0, 0.0); fft_size];
            padded[..wavelet.len()].copy_from_slice(wavelet);
            forward.process(&mut padded);
            padded
        })
        .collect();
    data.iter()
        .map(|signal| {
            let mut signal_spectrum = vec![Complex64::new(0.0, 0.0); fft_size];
            for (target, value) in signal_spectrum.iter_mut().zip(signal) {
                target.re = *value;
            }
            forward.process(&mut signal_spectrum);
            wavelets
                .iter()
                .zip(&wavelet_spectra)
                .map(|(wavelet, spectrum)| {
                    let mut product: Vec<Complex64> = signal_spectrum
                        .iter()
                        .zip(spectrum)
                        .map(|(left, right)| *left * *right)
                        .collect();
                    inverse.process(&mut product);
                    let scale = 1.0 / fft_size as f64;
                    let convolution_len = n_times + wavelet.len() - 1;
                    let start = (convolution_len - n_times) / 2;
                    product[start..start + n_times]
                        .iter()
                        .map(|value| *value * scale)
                        .collect()
                })
                .collect()
        })
        .collect()
}

fn morlet(sfreq: f64, frequency: f64, cycles: f64) -> Vec<Complex64> {
    let sigma = cycles / (2.0 * std::f64::consts::PI * frequency);
    let positive: Vec<f64> = std::iter::successors(Some(0.0), |value| Some(*value + 1.0 / sfreq))
        .take_while(|value| *value < 5.0 * sigma)
        .collect();
    let times: Vec<f64> = positive[1..]
        .iter()
        .rev()
        .map(|value| -*value)
        .chain(positive.iter().copied())
        .collect();
    let mut wavelet: Vec<Complex64> = times
        .iter()
        .map(|time| {
            Complex64::from_polar(1.0, 2.0 * std::f64::consts::PI * frequency * time)
                * (-time.powi(2) / (2.0 * sigma.powi(2))).exp()
        })
        .collect();
    let norm = wavelet
        .iter()
        .map(|value| value.norm_sqr())
        .sum::<f64>()
        .sqrt()
        * 0.5_f64.sqrt();
    for value in &mut wavelet {
        *value /= norm;
    }
    wavelet
}

fn band_means(values: &[f64], frequencies: &[f64]) -> Vec<f64> {
    BANDS[1..]
        .iter()
        .map(|band| {
            let selected: Vec<f64> = values
                .iter()
                .zip(frequencies)
                .filter_map(|(value, frequency)| {
                    (*frequency >= band.0 && *frequency <= band.1).then_some(*value)
                })
                .collect();
            selected.iter().sum::<f64>() / selected.len() as f64
        })
        .collect()
}

fn logspace(start: f64, end: f64, count: usize) -> Vec<f64> {
    let start = start.log10();
    let step = (end.log10() - start) / (count - 1) as f64;
    (0..count)
        .map(|index| 10.0_f64.powf(start + step * index as f64))
        .collect()
}

fn next_fast_len(mut value: usize) -> usize {
    loop {
        let mut remainder = value;
        for factor in [2, 3, 5] {
            while remainder % factor == 0 {
                remainder /= factor;
            }
        }
        if remainder == 1 {
            return value;
        }
        value += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use std::collections::BTreeMap;

    #[derive(Deserialize)]
    struct ConnectivityFixture {
        sfreq: f64,
        labels: Vec<String>,
        data: Vec<Vec<f64>>,
        frequencies: Vec<f64>,
        bivariate: BTreeMap<String, Vec<Vec<f64>>>,
        multivariate: BTreeMap<String, Vec<f64>>,
    }

    #[test]
    fn morlet_has_mne_norm() {
        let wavelet = morlet(1000.0, 10.0, 3.0);
        let norm = wavelet
            .iter()
            .map(|value| value.norm_sqr())
            .sum::<f64>()
            .sqrt();
        assert!((norm - 2.0_f64.sqrt()).abs() < 1e-12);
        assert_eq!(wavelet.len() % 2, 1);
    }

    #[test]
    fn phase_metrics_detect_lag() {
        let sfreq = 100.0;
        let x: Vec<f64> = (0..400)
            .map(|i| (2.0 * std::f64::consts::PI * 10.0 * i as f64 / sfreq).sin())
            .collect();
        let y: Vec<f64> = (0..400)
            .map(|i| (2.0 * std::f64::consts::PI * 10.0 * i as f64 / sfreq + 0.8).sin())
            .collect();
        let frequencies = logspace(4.0, 40.0, N_FREQS);
        let cycles: Vec<f64> = logspace(3.0, 20.0, N_FREQS)
            .into_iter()
            .map(|v| v as usize as f64)
            .collect();
        let coeffs = morlet_coefficients(&[x, y], sfreq, &frequencies, &cycles);
        let options = Options::connectivity_test();
        let scores = bivariate_scores(&coeffs, &options);
        assert!(scores[0][1].iter().copied().fold(0.0, f64::max) > 0.4);
    }

    #[test]
    fn compare_mne_connectivity_0_8_fixture() {
        let fixture: ConnectivityFixture =
            serde_json::from_str(include_str!("../tests/reference/connectivity_mne_0_8.json"))
                .unwrap();
        let cycles: Vec<f64> = logspace(3.0, 20.0, N_FREQS)
            .into_iter()
            .map(|value| value as usize as f64)
            .collect();
        let coefficients =
            morlet_coefficients(&fixture.data, fixture.sfreq, &fixture.frequencies, &cycles);
        let options = Options::connectivity_test();
        let bivariate = bivariate_scores(&coefficients, &options);
        for (metric_index, metric) in ["coh", "plv", "ciplv", "pli", "wpli"].iter().enumerate() {
            let mut maximum = 0.0_f64;
            for (channel, values) in bivariate.iter().enumerate() {
                for (frequency, actual) in values[metric_index].iter().enumerate() {
                    maximum = maximum
                        .max((actual - fixture.bivariate[*metric][channel][frequency]).abs());
                }
            }
            println!("{metric} maximum error: {maximum:.12e}");
            assert!(maximum < 1e-9, "{metric} maximum error {maximum}");
        }
        let multivariate = multivariate_scores(&coefficients, &fixture.labels, &options);
        for (metric, actual) in [
            ("mic", multivariate.mic),
            ("mim", multivariate.mim),
            ("gc", multivariate.gc),
            ("gc_tr", multivariate.gc_tr),
        ] {
            assert!(
                actual.iter().all(|value| value.is_finite()),
                "{metric} produced non-finite values: {actual:?}"
            );
            let maximum = actual
                .iter()
                .zip(&fixture.multivariate[metric])
                .map(|(actual, expected)| (actual - expected).abs())
                .fold(0.0, f64::max);
            println!("{metric} maximum error: {maximum:.12e}");
            assert!(maximum.is_finite(), "{metric} produced non-finite error");
            let tolerance = if metric == "gc" || metric == "gc_tr" {
                1e-8
            } else {
                1e-9
            };
            assert!(maximum < tolerance, "{metric} maximum error {maximum}");
        }
    }
}
