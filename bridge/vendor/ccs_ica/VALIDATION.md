# ccs_ica — Rust port of the ICA / ICLabel stages of `accs_CCScleaningpipeline.m`

Ports: EEGLAB `runica` + `pop_runica` (Infomax, incl. rank/PCA path, RMS-microvolt scaling of `eeg_checkset`),
Picard (`picard.rs`, port of python-picard 0.8: standard, ortho, extended; `pop_picard` mirrors eegprep `eeg_picard`),
ICLabel (default net), `accs_autoICAremoval` / `accs_eyeblinkremoval` selection loops, `pop_subcomp`.
clean_rawdata ASR (`asr.rs`, `yulewalk.rs`, `special.rs`: `clean_asr`, `asr_calibrate`, `asr_process`, `clean_windows`, burst rejection),
blink detection (`blink.rs`: `accs_eyeblinkdetection` + EEGLAB `eegfilt`/`firls`/`filtfilt`) and an in-memory two-stage API
(`studio.rs`) used by CCS EEG Studio. Epoching, high-pass filtering and bad-channel detection stay *inputs*.

CLI: `ccs_ica <pop_runica|picard|asr|blink|variant|studio|iclabel|net|resample|ica1|ica2|select> <case_dir> <out_dir>`

## Validation (`validation/`)
* `matlab/job_refgen.m` – runs the real pipeline stages in MATLAB/EEGLAB with logging copies of `runica`/`pop_runica`
  (random permutations are recorded so Rust can replay them) and dumps inputs, outputs, ICLabel features, selections, cleaned data.
* `compare_runica.py <cases>` – replays the permutations through Rust `pop_runica`; **status: parity ~1e-6 on all 3 sample EDFs**
  (component sign differs in the rank-deficient/PCA path: LAPACK eigenvector sign is arbitrary).
* `run_parity.py <cases>` – ICLabel features/labels, selection and end-to-end chain vs MATLAB (needs a fresh `job_refgen.m` run).
* `picard_parity.py` – Rust Picard vs python-picard (needs `pip install python-picard`); parity 1e-12 (std, ortho), 3e-6 (ortho, extended=False).

## Parity results (3 sample EDFs, 120 s, MATLAB R2024b / EEGLAB 2024.2.1)
| stage | result |
|---|---|
| `pop_runica` (replayed permutations) | W/winv max diff 1e-6..1e-4 (all 6 runs); only component *sign* differs in PCA path |
| ICLabel features, ICA2 (continuous) | topo 0, autocorr 6e-8, psd ≤1e-5; class probabilities ≤1e-4, argmax 100% |
| ICLabel features, ICA1 (epoched) | topo/autocorr exact; psd exact except 1 blink-like component per file (≤0.16 normalised); probabilities ≤1.5e-2, argmax 100% |
| component selection (`accs_*` loops) | identical component lists and signalslost on all 6 runs |
| cleaned data | ICA2 exact (no components exceeded thresholds, so this is weak evidence for stage-2 removal); ICA1 1e-5..1e-4 (µV, with removals) |

## ASR parity (`run_asr_parity.py asr_cases`, MATLAB `matlab/asr_ref.m` + `job_asr.m`)
Rust vs MATLAB `clean_asr` / `clean_windows` (clean_artifacts parameters), cutoffs 5/15/20, 3 sample EDFs (30 ch, 250 Hz, 120 s):
yulewalk B/A 1e-13; calibration `M` 1e-13..3e-9, thresholds `T` 1e-11..3e-6; repaired data 1e-12 (RestEyesClosed, RestEyesOpen) and
5e-8 (MeditationEyesClosed); burst masks identical; rejected data and window-clean data identical in shape and value.
Two MATLAB behaviours had to be reproduced: `a:step:b` evaluates the second half of the range backward from the end (changes `round()`
of x.5 window offsets), and `pop_select(..., 'point', ...)` drops a lone trailing one-sample interval.
## Blink detection (`run_blink_parity.py`, `matlab/job_blink.m`) — MATLAB-verified
Events are identical to MATLAB `accs_eyeblinkdetection` on all 3 EDFs (11 / 39 / 7 blinks); `firls` 1.5e-14, `eegfilt` <= 5e-12.

## ASR variants and alternative cleaners (`variants.rs`, `decomp.rs`; CLI `ccs_ica variant`)
| Method | Status | Reference used |
|---|---|---|
| Riemannian ASR (`riemannian` flag of `AsrParams`) | port of EEGLAB `asr_calibrate_r`/`asr_process_r` | **MATLAB-verified** (3 EDFs x cutoffs 5/15/20, `rasr_ref.m` + `run_rasr_parity.py`): M 1e-13 (3e-9 on one file), T'T <= 2e-5 absolute (|T'T| ~1e3), repaired data 1e-12 where ASR changes the data (RestEyesOpen, change up to 210); on the two other files ASR changes <4e-6 so repair is only weakly tested. Reference run with maxmem 4096 (one block) |
| BSS-CCA | De Clercq 2006 (CCA of x(t), x(t-lag)) | **MATLAB `canoncorr`: rho on EDF 7.7e-14**; n_remove=0 reproduces data 7e-13 |
| iCanClean (pseudo-reference) | mne-denoise `ICanClean(pseudo_ref=True, filter_ref=("bandstop",(lo,hi)))`: 4th-order Butterworth band-stop `sosfiltfilt` reference, sliding-window QR/CCA, `r2 >= thr` rejection, least-squares cleaning, overlap-add | **numerical parity with `mne_denoise.icanclean`: max abs diff 1.3e-9 (band 1-8 Hz, thr 0.7) and 3.8e-8 (0.5-3 Hz, thr 0.8) on a 30-channel EEG whose change is up to 109 uV**; Butterworth/`sosfiltfilt` vs scipy 2e-11 (`run_butter_parity.py`, `run_icc_bss_parity.py`) |
| BSS-CCA | De Clercq 2006 (CCA of x(t), x(t-lag)) | **mne-denoise `BSSCCA`: 2.3e-10 (n_remove=3), 1.2e-10 (6), 2.3e-10 (rho_threshold 0.98, same 8 sources removed)**; MATLAB `canoncorr` rho 7.7e-14 |
| Adaptive ASR (EMA recalibration) | **own design - NOT the mne-denoise `AdaptiveASR` (psw/psp/mw) algorithm**; no parity with the published A-ASR is claimed | `alpha = 0` equals static ASR to 4e-13 |
| E-ASR (delay embedding) / VMD-ASR / EMD-ASR | interpretation: pseudo-channels from delay embedding / modes, ASR, recombine. The E-ASR paper and any reference code could not be accessed (PMC reCAPTCHA / Europe PMC rate limit), so E-ASR has **no reference check** | VMD modes vs `vmdpy` (port of reference VMD.m, same N-1 iterations): relative 1e-4 - 2.4e-4 per mode on a non-converged 499-iteration run; EMD sums back exactly; vs **MATLAB `emd`**: IMF1-3 correlation 0.998-0.999 (7 vs 8 IMFs); differs from PyEMD (other stopping rules, IMF1 corr 0.58 on blink-rich data) |
| wICA | **HAPPE `wICA.m` (Sorokin 2015 / Castellanos & Makarov 2006)**: extended runica, zero-pad to a multiple of 2^L (L=5), `ddencmp('den','wv')` soft threshold x `mult` on every SWT row incl. the approximation, coif5 SWT, `clean = X - A*wIC` | **MATLAB-verified end to end** (`matlab/wica_ref.m` runs HAPPE's wICA.m; `run_wica_parity.py` feeds MATLAB's W to Rust): cleaned data max diff 9.4e-5 (data change up to 211; difference is MATLAB single precision of ICs/coefficients); MATLAB-exact `swt`/`iswt` conventions ported |
| ASR_DBSCAN / ASR_GEV | calibration-sample selection of mne-denoise `select_juggler_reference_samples` (top-k amplitudes of the ASR-filtered data, Chebyshev DBSCAN eps = mode/10, GEV mode rule; numpy `fd` histogram mode) | **vs mne-denoise: DBSCAN mask identical (0 of 12000 samples differ), GEV mask 1 of 12000 differs (MLE optimiser tolerance)**; GEV fit = **MATLAB `gevfit`** and scipy; DBSCAN identical to **MATLAB `dbscan`** and scikit-learn. Reconstruction stage is this crate's EEGLAB-style ASR, not mne-denoise's ASR core (not compared) |

`run_variants_parity.py`, `run_icc_bss_parity.py`, `run_juggler_parity.py`, `run_wica_parity.py`, `run_butter_parity.py` and `run_variants_smoke.py`
reproduce these numbers (mne-denoise checks need the GitHub `main` source; the PyPI 0.0.1 release lacks these modules).
`matlab/variants_ref.m` (+ `job_all.m`) and `matlab/wica_ref.m` hold the MATLAB references (`canoncorr`, `gevfit`, `dbscan`, `emd`, HAPPE `wICA.m`).
Without original-code parity: Adaptive ASR (relabelled own design), E-ASR, VMD-ASR/EMD-ASR combinations (ASR on modes), the mne-denoise ASR core as the
reconstruction stage of Juggler. Deep-learning denoisers and nASR are not implemented.

## Known limits
* MATLAB's `runica` is clock-seeded, so independent runs are only statistically comparable; parity is shown by replaying logged draws.
* Open item: PSD of near-constant (blink) components in epoched ICA1 data differs by an affine dB offset (cause not found; selections unaffected).
* ICA2 selection removed nothing on these files, so threshold removal in stage 2 is covered only by the shared selection code exercised in stage 1.
* `binica` is not emulated (not usable on the reference Mac either; the pipeline falls back to `runica`).
* PCA-path component sign follows the eigen-solver, not LAPACK's.
