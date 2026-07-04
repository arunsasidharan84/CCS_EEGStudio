# AKNLTP014_REMED1_RCB Benchmark Parity Report

Input: `/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/AKNLTP014_REMED1_RCB.set`
Scope: Rust app output compared against benchmark reference outputs for feature extraction and preprocessing.

## Benchmark Sources

GEDAI benchmark source: `/Users/arunsasidharan/Code/ActiveProjects/ABRL_OctaveMatlab_tools/external_functions/GEDAI`
FOOOF/specparam benchmark source: `/Users/arunsasidharan/Code/Python_misc/fooof-main`

MATLAB and Octave executables were not available on PATH in this shell, so the GEDAI benchmark source is documented and the Rust GEDAI implementation is aligned to the MATLAB algorithmic reconstruction path. The numerical preprocessing comparison plot is against the local reproducible reference pipeline artifact generated for AKNL.

FOOOF parity is evaluated against the local specparam/FOOOF algorithm source path requested above, through the same Welch PSD inputs used by the app report harness.

## Feature Parity Summary

Python/reference feature shape: [10, 111]
Rust feature shape: [10, 111]
Common numeric features compared: 104

| Family | Features | Max abs | Median mean abs | Median corr |
|---|---:|---:|---:|---:|
| acw | 1 | 0 | 0 | 1 |
| connectivity | 54 | 0.67517 | 2.68137e-09 | 1 |
| fooof | 19 | 5.57945 | 0.000710271 | 0.99998 |
| irasa | 12 | 1.33674e-06 | 2.24617e-08 | 1 |
| metadata | 3 | 0 | 0 | NA |
| nonlinear | 8 | 0.000319949 | 6.53261e-10 | 1 |
| psd | 7 | 2.05291e-08 | 3.89176e-09 | 1 |

## Targeted Remaining Metrics

| Metric | Max abs | Mean abs | Corr |
|---|---:|---:|---:|
| auc_FOOOF | 5.57945 | 1.40531 | 0.994337 |
| intercept_Irasa | 1.33674e-06 | 5.89644e-07 | 1 |
| slope_Irasa | 6.35226e-07 | 2.98971e-07 | 1 |
| rsquared_Irasa | 6.64319e-08 | 4.48781e-08 | 1 |
| auc_Irasa | 5.41146e-07 | 2.42293e-07 | 1 |
| oscspectraledge_Irasa | 0 | 0 | 1 |
| conn_mic_Theta | 0.220766 | 0.220766 | NA |
| conn_mic_ThetaAlpha | 0.216948 | 0.216948 | 1 |
| conn_mic_Alpha | 0.67517 | 0.67517 | NA |
| conn_mic_Beta1 | 0.218856 | 0.218856 | NA |
| conn_mic_Beta2 | 0.125749 | 0.125749 | 1 |
| conn_mic_Gamma1 | 0.364188 | 0.364188 | NA |

## Preprocessing Snapshot Summary

Python/reference sample rate: 250.0
Rust sample rate: 250.0
Channels compared: Fz, F3, F4, C3, C4, P3, P4, Pz, O1, O2
Samples compared: 1000
RMS difference (uV): 4.33829
Median absolute difference (uV): 2.8171
Max absolute difference (uV): 22.1237
Rust GEDAI SENSAI score: 14.6238
Rust GEDAI thresholds: [10.0, 0.0]
Rust bad channels: ['F3']

## Interpretation

IRASA fitted aperiodic descriptors are now at numerical parity on this AKNL slice.
FOOOF overall parity is high, with auc_FOOOF remaining the largest FOOOF-specific discrepancy.
MIM parity is near exact, but MIC remains sensitive to spatial-filter orientation and remains the main connectivity outlier.
Preprocessing snapshots are included with shared visual scaling and overlays so the remaining GEDAI/filter/interpolation waveform differences are visible.

## Included Plot Files

- `feature_family_parity.png`
- `feature_scatter_parity.png`
- `connectivity_metric_parity.png`
- `preprocess_snapshot_stacked.png`
- `preprocess_overlay_Fz.png`
- `preprocess_overlay_F3.png`
- `preprocess_overlay_F4.png`
