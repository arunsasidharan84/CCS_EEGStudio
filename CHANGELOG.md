# Changelog

All notable CCS EEG Studio changes are documented here. Version headings are
also the source for GitHub Release notes, so a tagged release is rejected when
its matching section is missing.

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
