# Changelog

All notable CCS EEG Studio changes are documented here. Version headings are
also the source for GitHub Release notes, so a tagged release is rejected when
its matching section is missing.

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
