# AKNLTP014_REMED1_RCB Python vs Rust Parity Report

Input: `/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/AKNLTP014_REMED1_RCB.set`
Channels: Fz, F3, F4, C3, C4, P3, P4, Pz, O1, O2
Window: first 15 seconds, epoch length 15 seconds

## Feature Extraction

Python feature shape: [10, 111]
Rust feature shape: [10, 111]
Common numeric features compared: 104

Family summary is in `feature_comparison_by_family.csv`; worst columns are in `feature_comparison_by_column.csv`.

| Family | Features | Max abs | Median mean abs | Median corr |
|---|---:|---:|---:|---:|
| acw | 1 | 0 | 0 | 1 |
| connectivity | 54 | 0.67517 | 2.68137e-09 | 1 |
| fooof | 19 | 5.57945 | 0.000710271 | 0.99998 |
| irasa | 12 | 1.33674e-06 | 2.24617e-08 | 1 |
| metadata | 3 | 0 | 0 | NA |
| nonlinear | 8 | 0.000319949 | 6.53261e-10 | 1 |
| psd | 7 | 2.05291e-08 | 3.89176e-09 | 1 |

## Worst Feature Columns

| Feature | n | Max abs | Mean abs | Max rel | Corr |
|---|---:|---:|---:|---:|---:|
| auc_FOOOF | 10 | 5.57945 | 1.40531 | 8.17315 | 0.994337 |
| conn_mic_Alpha | 10 | 0.67517 | 0.67517 | 2 | NA |
| conn_mic_Gamma1 | 10 | 0.364188 | 0.364188 | 15.3529 | NA |
| cf_0_FOOOF | 10 | 0.244197 | 0.0413328 | 0.0113035 | 0.999949 |
| conn_mic_Theta | 10 | 0.220766 | 0.220766 | 2.49628 | NA |
| conn_mic_Beta1 | 10 | 0.218856 | 0.218856 | 1.50823 | NA |
| conn_mic_ThetaAlpha | 10 | 0.216948 | 0.216948 | 0.586956 | 1 |
| conn_mic_Beta2 | 10 | 0.125749 | 0.125749 | 1.07784 | 1 |
| conn_wpli_Gamma1 | 10 | 0.0867167 | 0.0412525 | 0.410777 | 0.781987 |
| cf_1_FOOOF | 5 | 0.0850479 | 0.0412943 | 0.00385287 | 0.999999 |
| conn_pli_Gamma1 | 10 | 0.0588467 | 0.0316493 | 0.634334 | 0.662396 |
| conn_ciplv_Gamma1 | 10 | 0.0432772 | 0.025926 | 0.645928 | 0.685327 |
| conn_mim_Gamma1 | 10 | 0.0399641 | 0.0399641 | 0.188131 | NA |
| bw_0_FOOOF | 10 | 0.0394723 | 0.00694913 | 0.00948375 | 1 |
| conn_plv_Gamma1 | 10 | 0.0353942 | 0.0181362 | 0.140687 | 0.891935 |

## Preprocessing

Python sample rate: 250.0
Rust sample rate: 250.0
Channels compared: Fz, F3, F4, C3, C4, P3, P4, Pz, O1, O2
Samples compared: 1000
RMS difference (uV): 4.33829
Median absolute difference (uV): 2.8171
Max absolute difference (uV): 22.1237

Snapshots:

- `preprocess_snapshot_stacked.png`
- `preprocess_snapshot_Fz.png` and `preprocess_overlay_Fz.png`
- `preprocess_snapshot_F3.png` and `preprocess_overlay_F3.png`
- `preprocess_snapshot_F4.png` and `preprocess_overlay_F4.png`
- `preprocess_snapshot_C3.png` and `preprocess_overlay_C3.png`
- `preprocess_snapshot_C4.png` and `preprocess_overlay_C4.png`
- `preprocess_snapshot_P3.png` and `preprocess_overlay_P3.png`
- `preprocess_snapshot_P4.png` and `preprocess_overlay_P4.png`
- `preprocess_snapshot_Pz.png` and `preprocess_overlay_Pz.png`

Visual summaries:

- `feature_family_parity.png`
- `feature_scatter_parity.png`
- `connectivity_metric_parity.png`

## Interpretation

PSD, nonlinear features, ACW, and most connectivity values are at or near numerical precision against the Python reference on this real-data slice.
IRASA oscillatory band powers match closely; IRASA fitted aperiodic parameters remain less exact because Rust and Python fitting paths are not identical.
FOOOF and preprocessing remain the hardest native parity targets. The report includes scatter plots and shared-scale preprocessing overlays so achieved parity and remaining gaps are visible rather than only tabular.
