# Changelog

All notable CCS EEG Studio changes are documented here. Version headings are
also the source for GitHub Release notes, so a tagged release is rejected when
its matching section is missing.

## [1.2.14]

### Stacked Multi-Group TopoStats Display & Lateral Spread Controls

- **Stacked Multi-Group Figures**: Added first-class support in "Plots & Report" (TopoStats) for displaying multiple recordings, subjects, or experimental sessions stacked vertically one below the other.
- **Group Management**: Automatically partitions sessions by recording ID (`groupByRecording`) and provides sidebar actions to append additional folders or CSV sets (`+ Add group`).
- **Active Group Editing**: Active group dropdown in the sidebar lets you reorder sessions, select custom baseline sessions, and adjust session colors independently per group.
- **Synchronized Inspection & Zoom**: Hover tooltips, click-to-inspect topomap dialogs, and smooth zoom (`Cmd+Scroll` / toolbar buttons) work seamlessly across all stacked figure cards.
- **Multi-Group Export**: Export PDF generates a high-resolution multi-page PDF document with one page per plot group; Export PNG and CSV exports batch results for all active groups.
- **Lateral Spread Reduction & Width Presets**: Added quick width pills (`Compact (0.35")`, `Medium (0.5")`, `Wide (0.8")`) and responsive recalculation (`onSubmitted`) for `Topo width` to instantly compress wide figures across long timelines without recomputing permutation statistics.

### MMN ERP Stimulus Epoching Parity

- **Epoch Preservation**: Prevented continuous sliding-window overlap slicing (`RecordingTransform.subepoch()`) from modifying stimulus-locked epoched files during preprocessing.
- **Stimulus Epoch Configuration**: Automatically zeroed and hid continuous window overlap settings in the UI when stimulus-locked epoching is enabled.
- **Dataset Parity Verification**: Re-generated and verified MMN epoched files for Day 3 (`20260922`), matching the 750-epoch structure and cluster permutation tests of Day 1 (`20260709`) and Day 2 (`20260710`).

### Group Statistics & Workspace

- Repaired group-statistics numeric imports, including mixed CSV types and DFA/fE:I numeric aggregation. Aligned pooled CSVs by column names instead of row position.
- Added consistent readable group-workbench theming, folder/multi-file loading, visible run controls, channel scope, and simpler EEG-focused defaults.
- Added searchable bounded plot recording lists and bulk selection; initially select up to eight records while keeping all files available.
- Added explicit exploratory short-epoch DFA/fE:I verification with separate `_short` columns. Published-scale estimators are not silently redefined.
- Defaulted analysis PDFs to compact summaries with representative channels, limited maps/time courses, and key tables. Detailed mode retains all channels/features.
- Rendered waveforms using preview sampling rate and a shared peak-safe amplitude scale; avoid row clipping of shown peaks. Added fitted scalp outlines and contours.
- Added configurable DFA/fE:I source context (UI default 60 s; zero = epoch only), retaining shorter epochs for other features and respecting saved trial boundaries.
- Recorded actual context duration/start/end in CSV metadata and provenance.
- Rejected fE:I when DFA is missing, closing the legacy NaN-comparison qualification loophole.
- Validated four-page PC001 report visually and full-band computation on five representative channels with five-second cadence and 60-second context.

## [1.2.13]

### FieldTrip loading and extraction

- Fixed continuous FieldTrip MAT inspection: a one-cell continuous trial remains
  continuous instead of being exposed as one synthetic saved epoch.
- This fixes "recording is shorter than one analysis epoch" for psiconnect
  recordings longer than four minutes. The native engine reads the original
  full-resolution file rather than a decimated waveform preview.
- Materialize full samples before serializing decimated native epoched inputs.
  Original recording names and source identity remain in feature outputs.

### Overlapping windows

- Added feature epoch overlap in seconds. Zero overlap preserves nonoverlapping
  extraction; overlap must be nonnegative and shorter than the window.
- Added optional subdivision of existing trials into feature windows, preserving
  parent boundaries and source window coordinates. Incomplete tails are dropped.
- Added overlapping saved windows after preprocessing: clean each original sample
  once, then construct the output windows. On continuous inputs this defers saved
  epoch construction until cleaning finishes. Existing parent trials remain boundaries.
- Persist output window/overlap and timing provenance. Overlap is not a change to
  GEDAI's internal covariance-window implementation.
- Short-window DFA/fE:I is permitted when meaningful for a band. Lower-band
  missing values and fE:I validity failures remain missing; the advisory warning
  does not block explicit continuation or fabricate values.

### Batch workflow and group statistics

- Added Already preprocessed mode to start with features and hide preprocessing.
- Added first-N-subject folder import (zero means all), using sorted BIDS subject
  IDs or first filename tokens. Queue counts now reflect the selected input stage.
- The main workflow can run feature extraction and plots without a preprocessing queue.
- Added Stage 4 Group Statistics, with optional automatic opening after batch
  completion. It pools successful feature outputs into an explicit group-input
  table and opens metadata/model configuration; it does not run an unspecified model.
- Fixed numeric categorical factors (such as sessions 1/2) being represented
  differently during model fitting and adjusted contrast construction.

### Filename metadata

- Added Infer metadata from filenames with a review-and-save preview.
- Recognize BIDS sub/ses/task/run/acq fields and legacy SubNN subject identifiers.
- Support custom named-group regular expressions and require an updated preview
  before saving an edited pattern. Preserve identifier strings in the metadata CSV.
- Deduplicate recording names, leave unmatched fields blank, select the reviewed
  CSV for metadata joining, and set filename as the join key.
- No demographic, diagnosis or treatment details are inferred from unsupported names.

### Validation and documentation

- 146 Flutter tests passed with 5 dataset-dependent skips; Dart analysis is clean.
  Rust tests passed, including sliding-window boundary checks; 6 Python statistics
  tests passed, including numeric categorical contrasts.
- All 79 recordings from PC001–PC010 passed full-channel PSD extraction using
  two-second windows and one-second overlap: 1,466,112 rows. No other subjects
  were processed and the source files were not modified.
- Bounded first-ten-second checks from one recording per subject produced 5,760
  finite Gamma1 DFA values and 708 finite Gamma1 fE:I values. Lower-band fits were
  unavailable at that window length; this is not a claim of validity in all bands.
- Exercised a metadata-joined Fz Alpha_PSD LMM with Task/Session fixed factors and
  Subject random intercepts. This validates the workflow, not a full dataset finding.
- Compiled and verified the local macOS app; platform CI builds installers for release.
- Updated README and docs/psiconnect_batch_workflow.md with controls, naming rules,
  statistical setup, implementation conventions and the exact pilot scope.

## [1.2.12]

### Feature-window warnings

- Added a pre-extraction popup for selected DFA/fE:I windows below the practical
  60-second full-band recommendation, FOOOF/IRASA below one second, Welch windows
  longer than the epoch, and insufficient samples for the configured GC lag count.
- Use actual saved parent-epoch length for already epoched files. Increasing the
  extraction control does not silently merge existing trials.
- Offer Change settings or explicit continuation with limited/missing values.
  Batch extraction deduplicates identical warnings; cancellation stops the stage.
- Confirmed the supplied Girish two-second outputs: all 28,132 Gamma1 DFA values
  are finite, 3,759 Gamma1 fE:I values are finite, and Delta through Beta2 DFA/fE:I
  values are missing. Missing values are retained rather than filled or fabricated.
- Sixty seconds is an implementation-informed recommendation, not a universal
  validity guarantee. fE:I has additional validity gates even with longer windows.

### Compact outputs and naming

- Default to one feature CSV per recording rather than also writing a redundant
  pooled Batch_features.csv. Combined export remains available when selected.
- Default to one combined plots PDF and statistics CSV per recording without
  hundreds of individual PNGs. PNG export remains selectable; disabling the plots
  PDF produces PNGs so a visible plot output remains available.
- Name new preprocessing/feature summary reports `.analysis_report.pdf`, replacing
  `.features_report.pdf`. Plot reports retain their established TopoStats names.
- Keep batch analysis PDFs in the selected output directory even when individual
  feature CSVs are disabled and engine CSVs are temporary.
- Retain cleaned signals, analysis/preprocessing provenance and numerical plot
  statistics. Existing outputs are not deleted or renamed automatically.

### Documentation and method references

- Updated README with actual window-warning thresholds, output defaults, method
  papers and reference implementation links.
- Added docs/output_files.md to distinguish data, analysis reports, plots, statistics,
  provenance and optional duplicate exports; docs/methods_and_validation.md retains
  scoped ICA/ASR/DFA/fE:I reference evidence and experimental-variant limits.
- No feature algorithms or estimator thresholds were changed in this release.

### Validation

- Targeted window/default/export tests passed, including PDF-only output retaining
  statistics without PNG files and saved epoch lengths overriding UI cut settings.
- The full run passed 141 tests with 5 skips; the sole stale UI-label test was
  updated and passed in the 12-test UI rerun (142 tests covered in total).
- Dart analysis is clean. The local macOS 1.2.12 bundle compiled, embedded its
  release engine, and passed code-signature verification. Desktop CI also runs
  the complete suite before publishing platform packages.

## [1.2.11]

### ICA and ASR preprocessing (alternative or precursor to GEDAI)

- New **ICA cleaning** option in Preprocess: EEGLAB-parity Infomax (`runica`) or Picard,
  with blink-locked ICA (eye / optional heart components), a second ICA stage
  (muscle, line noise, channel noise) and ICLabel classification. Runs before ASR and GEDAI.
- New **ASR burst cleaning** (clean_rawdata parity): *Correct* reconstructs bursts in place
  (timing preserved), *Reject* drops burst samples. It follows ICA when both are enabled.
- Engine: vendored `bridge/vendor/ccs_ica` (sources of `ccs_toolbox/rust_ica`, validated against
  MATLAB/EEGLAB). ICA/ICLabel need 10-05 electrode names and continuous data; bad channels are
  left out of the decomposition and interpolated afterwards. The preprocessing summary gains an
  `ica` report (components removed with ICLabel classes, ASR samples modified).
- Parameters (eye channel, thresholds, ICLabel classes, ASR cutoff, seed) are in Preprocessing parameters.
- **ASR variants**: Riemannian ASR (EEGLAB `asr_calibrate_r` port, MATLAB-verified), ASR_DBSCAN / ASR_GEV calibration for
  movement-heavy data (sample selection matches mne-denoise `select_juggler_reference_samples`: DBSCAN identical, GEV 1 of 12000
  samples), adaptive (EMA) ASR (own design, not the published A-ASR), and E-ASR / VMD-ASR / EMD-ASR for up to 8 channels
  (interpretations; the E-ASR reference could not be accessed, so no reference check exists).
- **Muscle / motion cleaners** (after ICA, before ASR): BSS-CCA and iCanClean (pseudo-reference) match mne-denoise numerically
  (1e-8 or better); wICA follows HAPPE `wICA.m` (coif5 SWT, 5 levels, `ddencmp` soft threshold) and matches a MATLAB run of it to
  9e-5 (MATLAB single precision). wICA default levels are now 5.
- Verification scripts and numbers: `ccs_toolbox/rust_ica/README.md`.

### Orbit recording fixes

- Corrected the engine handoff for Orbit `.orb` / `.signal` recordings: the app
  sends the parsed full-resolution channels as portable EEG rather than asking
  the EDF reader to parse Orbit JSON. This fixes "invalid digit found in string"
  during preprocessing and feature extraction.
- Scalar C/D fields no longer create false EEG channels; array-valued C/D still
  represent additional channels. Two-channel recordings show AF7, AF8 and PPG.
- Added regression checks for channel detection and engine preprocessing/extraction.

### DFA and functional excitation/inhibition

- Added optional band-limited amplitude-envelope DFA and fE:I extraction with
  band-specific CSV columns, family reporting, and shared batch controls.
- The Rust implementation follows the CCS Python DFA/fE:I implementation and
  Hardstone/Bruining methodology. Fit ranges and windows adapt to available data;
  bands without enough data yield missing values rather than fabricated estimates.
- Short-window results are adaptations and do not establish literature-scale
  long-range correlations. fE:I is a signal-derived index, not a measured synaptic ratio.

### Pipeline behavior and reproducibility

- ICA requires continuous input, at least 8 good channels with recognized 10-05
  positions and at least 20 seconds of data. Unlocated/bad channels are excluded.
- Enabled cleaners run after bad-channel detection in ICA, muscle, ASR order,
  before fixed-window subepoching/GEDAI. Already epoched input skips these cleaners
  with a warning. Stimulus epochs created before this stage are also epoched input.
- ASR Correct preserves sample count; Reject removes samples and loses one-to-one
  input timing. Marker copying and raw/cleaned comparison are disabled when that
  timeline is not preserved.
- E-ASR, VMD-ASR and EMD-ASR skip inputs above 8 channels with a warning.
  Riemannian ASR uses 30-second processing blocks in Studio.
- ICA, ASR and muscle cleaning remain opt-in; enabling multiple cleaners combines
  their effects. Sidecars, activity logs and reports record selected options and outcomes.
- GEDAI reports whether a leadfield or identity reference was used. Unknown labels
  produce an explicit warning: identity fallback is not leadfield-based GEDAI.
- Updated macOS project and CocoaPods deployment targets consistently to macOS 12.
- Added method papers, reference implementation links and a scoped numerical
  validation table in README and docs/methods_and_validation.md.

### Validation

- Dart analysis is clean; 138 Flutter tests passed with 5 dataset-dependent skips.
  All Rust bridge tests passed, including 8 ICA/ASR and 4 advanced-parameter checks.
  The vendored algorithm library passed all 26 tests, including DFA/fE:I checks.
  The local macOS 1.2.11 bundle compiled and passed code-signature verification.
- Detailed parity figures describe upstream checks, not freshly rerun clinical or
  algorithm-effectiveness validation. ICA2 removal is weakly tested on the upstream
  fixtures because no components exceeded its thresholds.

## [1.2.10]

### Recording preparation and epoch handling

- Added Crop / subepoch and save in Load Raw, Preprocess, and Feature Extraction.
- Crop by annotation endpoints, annotation start plus duration, time endpoints,
  or time start plus duration before creating subepochs. Saved portable recordings
  retain annotations and preparation provenance for reuse.
- Native previews are loaded at full resolution before preparation. Mixed-rate
  channels are rejected rather than silently truncated.
- Existing trials support within-trial crops and complete-epoch selection on the
  stitched timeline. Sliding windows support overlap without crossing parent trials;
  incomplete windows are dropped and sample rounding determines the exact hop.
- Preserve window start/end coordinates in saved recordings and feature CSVs.
  Interval extraction keeps complete windows; time bins use window centres.
- Hide continuous epoch-cutting controls for already epoched recordings.

### Preprocessing and feature settings

- Added settings icons for output and feature references, filters, bad-channel
  detection, interpolation, source analysis, and feature families.
- Output references support keeping the input reference, common average, and named
  EEG reference channels. Feature referencing can be configured independently.
- Added FIR taps, Butterworth order, notch stop/transition widths, bad-channel
  variance ratio, spline parameters, source SNR and selectable atlas regions.
- Added Welch mean/median and window settings, custom frequency bands, FOOOF peak
  controls, IRASA factors, sample-entropy tolerance, Higuchi kmax, ACW crossing,
  and GC lag settings. Existing defaults are retained.
- Added GC minus time-reversed GC as a separately named contrast. It uses the
  same fits as GC and GC-TR and is distinct from net directional GC.
- Fixed preprocessing resampling despite the downsampling option being disabled.
- Recover preprocessing/source completion from saved provenance, recognize legacy
  clean filenames, and recover adjacent feature CSVs and figure folders on reopen.

### File selection and plot presentation

- Added filename wildcard filtering with *, ?, and semicolon-separated patterns
  to file selectors and batch folder queues.
- Added manual session ordering and per-session hexadecimal line colors, including
  exported plots. Display reordering preserves the baseline and computed statistics.

### Metadata-based group statistics

- Added Group Statistics in the batch workspace and Full Pipeline, adapted from
  CCS SleepStudio's local Python LMM/GLM workbench.
- Join feature CSVs with metadata CSV/XLSX, choose subject/group/within-subject
  factors, covariates, and outcomes, then export model tables, contrasts, and plots.
- Validate metadata joins; aggregate epoch values per recording/channel/condition;
  avoid treating duplicated connectivity rows as separate channel observations.
- LMM uses subject random intercepts; GLM uses HC3 or subject-clustered covariance.
  Failed mixed models do not silently fall back to independent-observation OLS.
- Contrasts use model-adjusted means and covariance, with selected-outcome multiple
  comparison correction and separately recorded omnibus/coefficient families.
- This optional workbench requires local Python with numpy, pandas, scipy,
  matplotlib, and statsmodels. XLSX uses openpyxl; optional Word/PDF reports use
  python-docx/reportlab. Set CCS_EEG_PYTHON to select an interpreter.

### Analysis conventions and compatibility

- FOOOF/IRASA retain a 1–40 Hz fit range; connectivity retains its 4–40 Hz grid.
  Custom PSD bands may extend to Nyquist. Standard bands preserve legacy
  integration; custom bands use trapezoidal integration.
- Overlapping epochs are not independent group observations. Multiple subjects
  and estimable designs are required for group inference.
- Recording and analysis sidecars record the actual source, settings, and timing.
  Existing cleaned files are not automatically regenerated with the new options.

### Validation

- 136 Flutter tests passed; 5 dataset-dependent tests skipped. Dart analysis was clean.
- Rust bridge and parameter tests passed, including reference voltage differences,
  alpha/high-frequency filtering, Welch robustness, and GC contrast identity.
- 23 vendored reference-fixture tests and 5 group-statistics tests passed.

## [1.2.9]

### GEDAI controls

- Exposed GEDAI's automatic presets and numeric threshold in preprocessing,
  shared between interactive and batch workflows, with input validation.
- Kept the existing automatic default; lower numeric thresholds can be used
  to review more conservative cleaning without changing all users' settings.

### Feature reports

- Added separate raw and cleaned waveform panels with the same time interval
  and amplitude scale, divided into readable channel groups.
- Reduced plot density and simplified the report summary.
- Report the actual saved epoch duration rather than the extraction UI value.
- Persist raw-source and preprocessing provenance so batch reports can recover
  the raw recording and describe the settings actually used.
- Avoid raw comparisons when stimulus epochs or differing durations make the
  timelines incompatible.

### Validation

- Verified the revised report visually on the supplied recording and passed
  threshold configuration and UI regression tests.

## [1.2.8]

### Batch results and plotting

- Added View Results to completed batch runs and the batch workspace, opening
  the interactive plot comparison directly with the latest batch outputs.
- Added Open Reports Folder for the generated figures and PDFs.
- Prefer individual recording CSVs over the redundant Batch_features.csv.
  Combined-only exports are split into named sessions before plotting.
- Changing selected sessions updates the plot automatically and selects a
  remaining baseline when the previous baseline is removed.
- Deselecting all sessions clears the plot and prompts for a recording instead
  of retaining an invalid baseline or stale figure.
- The batch result viewer inherits the configured epoch, smoothing, and window
  settings. Combined CSV previews export beside the source CSV.

### Release packaging

- Fixed RPM installation steps to use shell syntax supported by rpmbuild and
  explicitly run Bash-based desktop launcher setup with Bash.
- Added engine --help support for the Linux installer smoke test.
- Supersedes the unpublished 1.2.7 build, whose RPM packaging check failed.

### Validation

- Added regression tests for pooled/per-recording inputs, quoted filenames,
  baseline removal, and deselecting/reselecting sessions in the viewer.

## [1.2.6]

### Batch analysis

- Fixed an IRASA crash on one-second epochs when resampling produced fewer
  samples than the requested Welch window. Short windows now retain the FFT
  grid through zero-padding.
- Included the patched algorithm source so all platform builds use the fix.

### Interactive workspace

- Open directly into the recording workspace with workflow modules and the
  waveform viewer visible.
- Show the waveform automatically after loading or switching raw recordings.

### Validation

- Verified feature extraction on all 11 recordings from the reported batch.
- Passed UI regression tests and spectral reference tests.

## [1.2.5]

### Release reliability

- Pinned Flutter 3.41.9 across macOS, Windows, and Linux so CI runs the same
  tested SDK on every platform instead of silently moving to a newer stable
  toolchain.
- Updated GitHub checkout steps to the Node 24-based action release.
- Retains all application, ERP, microstate, viewer, format-loader, batch, and
  reporting improvements documented for 1.2.4 below.

## [1.2.4]

### Microstate timeline and statistics

- Aligned the microstate sequence strip, EEG waveform, and per-state
  similarity traces to one absolute-time axis and one common plot area.
- Added selectable EEG density (3, 6, 12, or 24 visible channels) and
  individually toggleable similarity traces.
- Added sample-wise state-similarity probabilities based on normalized squared
  spatial correlations.
- Display transition probabilities as percentages with two decimal places so
  small off-diagonal transitions remain distinguishable.
- Clarified canonical-template correlations and applied the same state colors
  to maps, legends, sequences, and similarity traces.

### ERP scalp mapping

- Added condition A, condition B, B−A, and Welch-t scalp maps across standard
  10–20 electrodes.
- Added an independently configurable scalp-map time point and a switch between
  that point and the configured component-window average.
- Added electrode-level condition statistics with Benjamini–Hochberg FDR
  correction; significant electrodes are marked directly on the maps.
- Preserved the existing Python-parity waveform, cluster-permutation,
  bootstrap, and summary statistics.

### Viewer and usability

- Kept raw and preprocessed recordings at the same absolute timeline position
  while switching between them, including stitched epochs.
- Constrained long recording tabs, added ellipsis, and exposed the full name in
  a tooltip so filenames cannot cover adjacent controls.
- Increased waveform readability with a light canvas, uniform traces, channel
  paging, and EEGLAB-style stitched epoch navigation.

### Validation

- Verified ERP parity against the Python reference data.
- Added synthetic and real 32-channel tests for point and window scalp maps.
- Passed the complete Flutter test suite and macOS bundle signature checks.

## [1.2.3]

### Recording formats

- Added FieldTrip MATLAB v5 files with continuous numeric trials and cell-array
  trials, including the Psiconnect `*_Clean-ft.mat` layout.
- Added EEGLAB `.set` support for embedded data and external `.fdt` files.
- Added continuous and epoched MNE `.fif` loading.
- Added BrainVision marker parsing for stimulus-locked ERP epoch generation.

### Workflow and batch processing

- Reworked the home, single-recording, and batch workspaces to remove duplicate
  navigation and give the active task the full application area.
- Added independent preprocessing, feature-extraction, and plotting batch
  stages with explicit inputs and shared, visible parameters.
- Added recursive folder loading, per-file progress, live logs, cancellation,
  failure isolation, and incremental pooled CSV output.
- Added a configurable GEDAI epoch/window size and stimulus-locked preprocessing
  with epoch metadata preserved in portable CCS EEG files.

### Analysis and distribution

- Added interactive and batch microstate analysis, canonical maps, temporal
  metrics, transition matrices, sequence export, and timeline exploration.
- Added ERP condition selection, waveform/SEM plots, cluster permutation tests,
  effect sizes, bootstrap intervals, statistics tables, and PDF/CSV export.
- Added in-app update discovery and platform-specific installer download from
  GitHub Releases.

## [1.2.0]

- Restructured the application into connected workflow modules.
- Added automatic and reviewable EEG/auxiliary channel typing.
- Added single-recording and batch parameter parity, per-recording outputs,
  pooled feature CSVs, and group overlays.
- Integrated the shared `CCS_Algorithm` Rust crate and variance-based bad-channel
  detection.

## [1.1.3]

- Fixed sidebar and stage-card Material ancestry assertions.
- Stabilized interactive and batch navigation layout.

## [1.1.2]

- Resolved static-analysis failures that blocked release builds.
- Hardened CI lint handling and desktop compilation.

## [1.1.1]

- Made fixture-dependent plotting tests skip cleanly when external research
  datasets are unavailable on CI runners.
- Restored successful GitHub Actions builds on clean machines.

## [1.1.0]

- Introduced separate interactive and batch workflows.
- Added real-time preview filtering and configurable analysis controls.

## [1.0.0]

- First versioned desktop release.
- Added Rust-backed EEG feature extraction, connectivity analysis, plotting,
  batch execution, CSV output, and PDF reporting.

[1.2.5]: https://github.com/arunsasidharan84/CCS_EEGStudio/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/arunsasidharan84/CCS_EEGStudio/compare/v1.2.0...v1.2.4
[1.2.3]: https://github.com/arunsasidharan84/CCS_EEGStudio/compare/v1.2.0...v1.2.3
[1.2.0]: https://github.com/arunsasidharan84/CCS_EEGStudio/releases/tag/v1.2.0
[1.1.3]: https://github.com/arunsasidharan84/CCS_EEGStudio/releases/tag/v1.1.3
[1.1.2]: https://github.com/arunsasidharan84/CCS_EEGStudio/releases/tag/v1.1.2
[1.1.1]: https://github.com/arunsasidharan84/CCS_EEGStudio/releases/tag/v1.1.1
[1.1.0]: https://github.com/arunsasidharan84/CCS_EEGStudio/releases/tag/v1.1.0
[1.0.0]: https://github.com/arunsasidharan84/CCS_EEGStudio/releases/tag/v1.0.0
