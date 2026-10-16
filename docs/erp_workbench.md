# Guided ERP analysis

All multi-recording analysis is accessed through **Batch Workspace**, with EEG, ERP and Microstates profiles. EEG retains preprocessing → features → plots/statistics. ERP accepts continuous event recordings or saved epoch files. Microstates learns a shared template and back-fits it to batch recordings. The single-recording ERP module consumes the active recording's saved trials and condition labels; it has no duplicate file/folder batch picker or guided/legacy tabs.

Computational ERP kernels run in Rust (`bridge/src/erp_math.rs` and `erp_workbench.rs`); Flutter handles controls, figures and PDF export. The metadata-driven LMM/GLM workbench retains its Python backend.

## Interactive ERP: preprocessing → compare groups

1. Load a recording, then use **Preprocess → Event-based trials**. Choose locking events and optionally assign named conditions. Save the prepared epochs.
2. Open **ERP Analysis**. The active saved trial file loads automatically. Choose MMN, N170, N2pc, N400, P3, LRP, ERN or Custom. Each task shows its locking, comparison, ROI and measurement guide.
3. Select saved labels for **Group A** and **Group B**. A group may combine several saved labels; the same label cannot belong to both sides. This selects existing trials and never cuts them again. Existing trial boundaries and original event onsets are reused. An unmatched MMN default is not applied to arbitrary conditions.
4. Review the baseline, ROI and measurement window, choose an output folder and run. Changing the ERP task does not silently change the saved epoch window. A baseline/window outside those epochs must be corrected or the data must be prepared with a wider window.
5. Optional **Suggest task groups from saved locking events** reconstructs the preset comparison from original event codes preserved in the epoch annotations. This is useful when previously saved groups represent a different factor. For example, the supplied `39_ERN_cleaned-epo_clean.ccseeg.json` has Congruent/Incongruent labels, while ERN requires Correct response/Error response. Its original locking codes permit a 319/82 split without re-epoching. The user can review/choose those suggested groups before running.

The full existing ERP engine remains available as source for previous analyses, but is no longer presented as a second competing screen. The current interactive screen and batch profile use the same native engine.

## Batch ERP CORE

1. Open **Batch Workspace → ERP**. Import a task folder or the ERP CORE root. Recursive import prefers a cleaned EDF over its raw counterpart; the first-two-participant pilot limit spans tasks. Review participant identifiers.
2. Continuous inputs need event classes because trials have not yet been cut. Saved epochs instead expose their existing condition labels. Review each task in a mixed batch; saved task settings apply to matching inputs. For grouped prepared trials, task comparisons can be reconstructed from original locking codes when these were retained.
3. Review windows/ROIs, rejection, models and output folder. Run to obtain per-recording and participant-level outputs. Reopen saved results without rerunning.
4. Condition or difference-wave measurements can be sent to metadata/group models. Conventional participant-level paired inference is already included in ERP results. Review metadata joins and the model before fitting additional LMM/GLM analyses.

Cleaned inputs are assumed when amplitude rejection is off; no additional filter, rereference, author-specific exclusion, ocular rejection, or display-lag correction is silently applied. Use the preprocessing workflow when these are needed. Saved segmented recordings reuse their trial layout. Sparse continuous overlap correction remains available only for continuous input. Decoding of saved epochs requires original event onsets to support temporal purging.

## ERP CORE starting presets

All times below are milliseconds relative to the locking event. These are editable starting configurations, not an exact reproduction of every published ERP CORE processing decision.

| Component | A / B codes | Lock, epoch | Baseline | ROI | Measurement window / polarity |
|---|---|---|---|---|---|
| MMN | 80 standard / 70 deviant; 180 excluded | Stimulus, −200…500 | −200…0 | FCz | 125…225, negative |
| N170 | 41–80 cars / 1–40 faces | Stimulus, −200…800 | −200…0 | PO7 + PO8 mean | 110…170, negative |
| N2pc | 111,112,211,212 left / 121,122,221,222 right | Stimulus, −200…800 | −200…0 | PO7/PO8, contra/ipsilateral | 200…275, negative |
| N400 | 211,212 related / 221,222 unrelated targets | Stimulus, −200…800 | −200…0 | Cz | 300…500, negative |
| P3 | two-digit codes with digits 1–5 unequal / 11,22,33,44,55 targets | Stimulus, −200…800 | −200…0 | Pz | 300…600, positive |
| LRP | 111,121 correct left / 212,222 correct right responses | Response, −800…200 | −800…−600 | C3/C4, contra/ipsilateral | −100…0, negative |
| ERN | 111,121,212,222 correct / 112,122,211,221 errors | Response, −600…400 | −400…−200 | FCz | 0…100, negative |

For N170/N2pc/N400/P3, correct-response eligibility uses the first 201/202 response within the configured response window (default 200–1000 ms) and requires code 201. Disable or edit this rule for a different paradigm. MMN has no response filter; LRP/ERN use their response codes directly.

N2pc/LRP average trials after aligning physical stimulus/response sides. Displayed A is ipsilateral and B contralateral; their ROI difference is contra minus ipsilateral. Maps use a canonical left-event orientation with antisymmetric contra-minus-ipsi values and zero midline. Regression and decoding retain physical left/right event classes, as labeled, rather than treating derived contra/ipsilateral traces as independent trials.

## Preprocessing and waveform navigation

In Preprocess, choose **Event-based trials (ERP)** before cleaning settings. Select detected marker chips or **Add labeled group…** to combine codes under a name such as Correct response. Groups can be renamed, reassigned or removed; a code belongs to at most one named group. Trial labels carry group names while original marker codes/times remain in annotations. The direct waveform **Epoch Events** dialog offers the same grouping editor. Normal marker selection needs no regex; regex is retained under Advanced marker matching. Exact normalized code matching prevents selecting 112 when 12 was intended.

Event trials are cut after filtering and used directly by GEDAI; fixed-window epoching is disabled for that path. For continuous work, choose whether to save fixed-length windows and set their length/overlap together. If continuous output is selected, GEDAI's processing-window setting describes internal denoising and does not imply saved trials. Existing segmented files retain their trial boundaries. ICA/ASR/muscle cleaners currently require continuous input and are skipped in the event-trial path; the UI identifies this limitation.

The waveform toolbar starts compact: Controls expands the full menu, Overview and Event labels toggle independently, and the header focus button hides auxiliary panels then restores their previous state. Navigation position survives collapsing. Marker lanes grow only to the rows needed.

The waveform's whole-recording overview shows the first-channel amplitude trend, event ticks, time axis and selected viewport. Click a tick/time or drag to navigate. Labels occupy three separate lanes above the signals, with collision suppression for dense events. Hover a label for the complete code/time; Events opens the full event list, including labels omitted from the dense view. Faint guides remain on the signal area. The overview of stitched trials uses stitched display time, not elapsed source time across gaps.

## Event timing and epochs

Auto source priority is adjacent EEGLAB `.evt`, portable JSON markers, then EDF+ annotations or calibrated integer Status/Trigger transitions. The supplied ERP CORE `.evt` latency/duration columns are **seconds**. EEGLAB can also export samples; convert those exports to seconds before use. The workflow does not guess units or subtract a one-sample offset. Native EDF source can be explicitly selected.

The event audit retains the original sidecar row index, source onset and fractional seconds. Epoch extraction rounds onset and endpoints to nearest samples. Epoch and baseline endpoints include the endpoint sample; source onsets remain unchanged in the audit. Trials can overlap naturally around successive events. Bounds, nonfinite samples and optional peak-to-peak rejection are counted; conventional ERP eligibility and continuous FIR event eligibility are reported separately.

In the tested cleaned ERP CORE files, sidecar and Status sequences matched but differed by up to about 4.9 ms in timing. This is reported rather than silently replacing one source. The viewer also exposes supplied `.evt` markers.

## Measurements and models

- Native-resolution ROI condition averages and B-minus-A waves: arithmetic mean, trapezoidal signed/positive/negative AUC (µV·s), polarity-specific peak amplitude and latency, 50% polarity-area latency, and fractional-peak onset. Fractional crossings interpolate between samples; undefined area/onset is missing, not zero. JSON/CSV latencies are seconds, while UI/report latency labels use milliseconds. Single-trial measurements retain event indices in a dedicated audit CSV.
- rERP: SVD ordinary least squares per channel and time bin, with intercept, B-vs-A class, centered reaction time when complete and variable, and optional numeric trial covariates. Trial metadata CSV requires `file,event_index` plus numeric predictor columns; `file` accepts full path or basename. Missing values or a rank-deficient design report a model warning while retaining conventional ERP results. Coefficient controls select any fitted channel/predictor. Time bins average samples (default 20 ms); native-resolution descriptive measurements are retained separately.
- Continuous overlap correction: a sparse time-expanded FIR/stick basis, separate A/B/other-stimulus/other-response kernels and a continuous intercept, solved with LSQR. Every eligible source event contributes, including events excluded from conventional averages; this distinction is in the model scope/audit. Tolerance and iteration limit are editable; per-channel residual/convergence diagnostics are saved. This is the linear FIR subset of the Unfold approach, **not a full port of Unfold**: no spline/GAM terms, nonlinear smoothers, regularization selection or mixed-effects deconvolution are claimed.
- Multivariate neural decoding: shrinkage LDA across EEG channels, time-resolved ROC AUC and balanced accuracy, optionally train-time × test-time generalization. Scaling, covariance and classifier fitting use training data only. Contiguous blocked folds purge nearby training events by the full epoch duration to prevent shared epoch samples between train/test. Missing-class folds are audited/skipped. Shrinkage and fold count are editable. Physical event classes are decoded; this is linear decoding, not a neural-network model. Scores have no automatic permutation significance claim.

The native kernels are independent implementations checked against NumPy/SciPy reference calculations for their explicitly defined designs. They do not establish feature-for-feature parity with entire MNE, Unfold, ERPLAB, Ragu, or decoding toolboxes.

## Group and topographical inference

Participants are the inferential units. Multiple recordings of a participant are averaged before group tests, and grand waveforms weight participants equally. Single-participant results remain descriptive. Paired t tests use the Student-t distribution and BH-FDR across the available measurement tests within a component. A paired difference in condition peak latency/amplitude is distinct from measuring the peak of the grand-average difference wave; both are labeled separately.

Subject-level sign flips provide max-|t| FWER correction across (a) component-window channels and (b) all channels × binned times as separate families. Exact enumeration is used through 12 participants; larger samples use seeded random patterns including the observed arrangement. rERP class betas with matching predictor lists also support participant-level channel × time max-|t| inference. Common channels are aligned by label across recordings. Interpolated display pixels are not independent statistical tests. The UI can mask maps at corrected p ≤ .05.

A paired TANOVA-style component-window test compares global map dissimilarity after channel-mean removal and unit-GFP normalization. Flat maps cannot supply a valid normalized-map p value. GFP time courses are exported. This implements the paired two-condition test, not Ragu's entire factorial, microstate, duration-threshold or topographic-consistency toolbox. No cluster/TFCE equivalence is claimed for this guided workflow. Very small pilot samples have coarse exact permutation p values; the two-participant pilot is a software check, not a powered study.

ERP CORE's derived `(uncorr) HEOG` and `(uncorr) VEOG` channels are now recognized as auxiliary EOG on load. This prevents future preprocessing from treating those labels as scalp electrodes. It does not repair previous cleaned outputs: if the log reported GEDAI without a valid leadfield reference, regenerate preprocessing from the original recording after verifying channel types. The saved-trial validation below checks sample/condition handling of the provided file; it does not validate the earlier cleaning quality.

## Outputs

| File | Contents |
|---|---|
| `erp_report.pdf` | Compact overview plus a waveform/topography/statistics page per component; optional advanced-model pages when models are selected |
| `erp_results.json` | Reopenable configuration, marker/timing audit, trial counts, accepted events, curves, maps, models, solver/CV diagnostics and failures |
| `erp_measurements.csv` | Participant/recording A, B and difference-wave measurements |
| `erp_trial_measurements.csv` | Optional advanced event-indexed trial measurements; default off from 1.2.16 |
| `erp_group_statistics.csv` | Participant-level paired measurement statistics and FDR |
| `erp_waveforms.csv` | Recording and grand-average ROI waveforms |
| `erp_model_coefficients.csv` | Optional channel/predictor/time coefficients for rERP and FIR models |
| `Group_Statistics/…` | Created on demand for metadata/group-model analysis |

A failed optional model does not discard successful conventional ERP analysis. Per-file errors do not abort other batch inputs. Reusing an output folder overwrites matching ERP result files; use a distinct folder for each analysis configuration.

## Reproducible validation

`bridge/tests/erp_workbench_parity.rs` checks measurements, OLS, LSQR, LDA, max-t reference results, task detection, lateralized alignment, participant grouping and supplied sidecar/Status sequences. Reference fixture generation is in `bridge/tests/generate_erp_reference.py`.

The continuous pilot used cleaned participant 1 and 2 recordings for all seven tasks (14 files). `tools/validate_erp_core.py` independently reads calibrated samples with MNE 1.11 and reconstructs event eligibility, baseline correction and averaging with NumPy. Accepted counts and native-resolution ROI waveforms matched all 14 recordings (maximum absolute waveform discrepancy 0 µV after matching the engine's float32 input representation). This verifies the implemented pipeline, not parity with author-provided final ERP waveforms.

The advanced pilot used participant 1 across all seven tasks. `tools/validate_erp_advanced.py` compares representative ROI rERP and continuous sparse FIR coefficients against NumPy least squares and SciPy LSQR. Maximum observed errors were below 7×10⁻¹⁴ µV for OLS and 7×10⁻⁸ µV for FIR at the recorded tolerances. All 28 channel FIR fits converged and all seven decoders had five usable purged folds. An additional independent NumPy reconstruction checks a representative decoding time bin in every purged fold for each task, including the no-shared-samples constraint; held-out AUC/balanced-accuracy discrepancies were zero in this pilot. This is a defined LDA/CV implementation check, not whole-toolbox equivalence.

Validation outputs are under ignored `output/erp_core_validation` and `output/erp_core_advanced_validation`; source data on the external volume is unchanged. Re-run validators against newly generated native results when altering code, settings or inputs.

An additional regression test exercises saved trials for all seven ERP tasks and confirms trial counts, sample layout, original onsets and no repeated behavioral filtering. On the user's saved ERN file, `tools/validate_saved_erp.py` independently reconstructs the original-code 319/82 comparison with NumPy; both condition waveform discrepancies are zero µV after matching float32 input. Outputs are in ignored `output/erp_saved_trial_validation`.

## Methods and original implementations

- Kappenman et al. (2021), **ERP CORE: An open resource for human event-related potential research**, [paper](https://doi.org/10.1016/j.neuroimage.2020.117465), [resource](https://erpinfo.org/erp-core), [scripts](https://github.com/lucklab/ERP_CORE).
- Smith & Kutas (2015), **Regression-based estimation of ERP waveforms: I. The rERP framework**, [paper](https://pmc.ncbi.nlm.nih.gov/articles/PMC5308234/). The native implementation uses the linear categorical/continuous-covariate subset described above.
- Ehinger & Dimigen (2019), **Unfold: an integrated toolbox for overlap correction, non-linear modeling, and regression-based EEG analysis**, [paper](https://doi.org/10.7717/peerj.7838), [workflow](https://www.unfoldtoolbox.org/toolboxWorkflow.html). The implemented native model is explicitly limited to sparse linear FIR/stick-basis least squares.
- King & Dehaene (2014), **Characterizing the dynamics of mental representations: the temporal generalization method**, [paper](https://pmc.ncbi.nlm.nih.gov/articles/PMC5635958/). Native decoding adds conservative blocked temporal purging; no automatic group decoding significance is implied.
- Habermann et al. (2018), **A Student's Guide to Randomization Statistics for Multichannel Event-Related Potentials Using Ragu**, [paper](https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2018.00355/full). Used for the normalized-map/GFP interpretation, not a claim of full Ragu parity.
- [SciPy LSQR documentation](https://docs.scipy.org/doc/scipy/reference/generated/scipy.sparse.linalg.lsqr.html) and Paige–Saunders LSQR: numerical comparison target for the sparse least-squares kernel.
- [EEGLAB event data structures](https://eeglab.org/tutorials/ConceptsGuide/Data_Structures.html): distinguish sample-indexed internal event latencies from supplied seconds-based exports.

## Reusable epoching and averaging protocols

Both **Epoch Events** on the waveform and **Event-based trials** in Preprocess edit the same settings. Choose locking events, combine codes into named groups, then review the trial and baseline windows. Direct epoching saves trials without running cleaning and opens ERP analysis. Preprocessing filters/cleans and saves trials; **Next: average and analyse saved trials** opens the same analysis screen. Existing epoched input keeps its trial boundaries.

New derived filenames distinguish `name-epo.ccseeg.json` (event epochs) and `name-epo_clean.ccseeg.json` (cleaned epochs). Original continuous and derived recordings stay available in the open-recording list when switching. Individual trial displays fit the trial duration. Previously written files retain their existing names.

In ERP analysis, choose a component and the saved condition groups A/B, review the ROI, baseline and measurement window, then **Average & analyse ERP**. The engine averages trials separately within conditions, displays A, B and B−A, and computes the selected measurements/statistics. Event grouping is an experimental choice: congruency is not automatically equivalent to correct/error responses.

**Save protocol** exports an editable `ccs-erp-protocol-v1` JSON containing locking codes, group names, trial/baseline/crop settings, task comparison, ROI, measurement window and model settings. It excludes signal data and participant paths. Save after configuring the comparison to include averaging settings; a protocol saved earlier may contain epoching only. **Load protocol** works in Preprocess, the direct epoch dialog, interactive ERP and the ERP Batch Workspace. Review event matches and group counts for each new dataset; saved epochs are not cut again on loading a protocol. Supported preparation/preprocessing sidecars restore the epoch settings when a saved recording is reopened. Older files without protocol metadata still expose their saved labels and timing for analysis.

Hover over the workflow module names, protocol help icon, file tabs and run controls for guidance. The protocol help icon provides the complete sequence without taking waveform space.

## Interactive batch review, smoothing and cohort labels

After averaging a batch, choose **Interactive batch review** above the result tabs. Search/select participants at left; choose the grand average, a participant average, or an individual recording in the view menu. Multiple recordings are averaged within participant before participants receive equal weight. Incompatible time grids, ROIs, baselines or condition definitions are excluded explicitly. **Participant differences** overlays participant difference waves for comparison.

The blue A, red B and grey B−A traces show numerical voltages. **Negative up** changes the vertical presentation only; **Component polarity** selects which peak to measure and never changes voltage signs. For a conventional ERN comparison use A = Correct and B = Incorrect, making B−A = Incorrect−Correct. Do not invert an unexpected positive difference merely to make it resemble an expected ERN; inspect input provenance and the response locking.

**Smoothing** is an optional symmetric moving average for display, with 8/16/24/40 ms spans. The unsmoothed condition averages remain the input to all exported measurements. In batch review, smoothing is applied to each participant's displayed waveform before computing the displayed grand mean and SEM, so the shading matches the displayed traces. Shadows are ±1 SEM across participants, separately for A, B and their paired difference; one participant has no between-participant SEM.

Adjust the measurement window with the range slider or millisecond endpoints. Descriptive measurements and the scalp map update immediately. New ERP outputs retain full-resolution channel difference waves for exact window maps; older results support their original map only and ask for re-averaging when the window changes. Existing inferential p-values are not reused for a changed window: send the reviewed CSV to group statistics to fit the selected model.

**Label groups** assigns between-participant cohort labels without changing the within-participant A/B condition labels. Choose metrics under **CSV parameters**, then **Export CSV** or **Group statistics**. Exports contain one row per participant/condition (A, B, B−A), the cohort label, ROI, window endpoints, recording count and selected raw-waveform metrics: mean amplitude, signed/positive/negative AUC, peak amplitude/latency and 50% area/peak latencies. Latencies are in milliseconds; amplitudes in µV and AUC in µV·s. Cohort labels travel in the CSV.

For externally cleaned data, use **Epoch only (keep existing cleaning)** in Preprocess or the waveform **Epoch Events** action. This cuts trials and applies the chosen baseline without adding filters or artifact cleaning. **Clean + epoch** is a separate choice. Existing outputs are not rewritten.


## Condition-average versus single-trial measurements

`erp_measurements.csv` measures each participant's condition-average waveform, including the B−A average difference. This is the usual export for conventional ERP comparisons.

`erp_trial_measurements.csv` instead describes each accepted event's individual trial within the chosen ROI and time window. Enable **Advanced analyses → Export individual-trial measurements** only for trial-level questions (for example amplitude versus reaction time or trial order). This export is disabled by default from 1.2.16. Individual-trial peak/latency estimates are noise-sensitive. Averaging trial peaks does not reproduce the peak of the averaged ERP. Trial rows are repeated observations within a participant, not additional independent participants. These derived measurements are not substitutes for full waveforms in rERP/FIR/deconvolution or decoding; those native analyses use the waveform data separately. Reaction time may be absent in prepared trials when it cannot be recovered reliably. Existing exports are not deleted when the option is turned off.

## Resampling correction and existing results

A stage-by-stage reconstruction of the supplied 256 Hz ERN input identified an incorrect preprocessing ratio: 244/250 instead of 125/128 for 256→250 Hz. The resulting signal rate was 249.856 Hz while metadata stated 250 Hz. By the end of a 13.5-minute recording this shifts response-locked samples by roughly 0.47 s. The negative ERN became positive before any artifact cleaner ran. The 1.2.16 correction uses a rate-preserving rational conversion and consistent per-trial output lengths.

With unchanged response classes, FCz, baseline −400…−200 ms and window 0…100 ms, Error−Correct was −9.68 µV without downsampling, +12.16 µV after the old downsampling, and −9.65 µV after corrected downsampling. With corrected resampling, filtering gave −10.47 µV and the complete saved GEDAI/interpolation configuration gave approximately −5.50 µV. This also documents substantial additional attenuation by GEDAI on an input already cleaned upstream; epoch-only remains the direct signal-preserving route for that input.

The correction is included in 1.2.16 and is absent from 1.2.15. Regenerate affected outputs from original recordings using the corrected build. The epoch-only/no-downsampling route also avoids this resampling error. Previously misaligned epochs cannot be repaired by flipping signs or exchanging condition labels.
