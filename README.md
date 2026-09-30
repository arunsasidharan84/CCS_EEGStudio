<p align="center">
  <img src="screenshots/ccs_logo.png" width="170" alt="Centre for Consciousness Studies, NIMHANS">
</p>

<h1 align="center">CCS EEG Studio</h1>

<p align="center">
  <b>Native-speed EEG preprocessing, feature extraction, connectivity, statistics, and reporting.</b>
</p>

<p align="center">
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/arunsasidharan84/CCS_EEGStudio?style=for-the-badge&color=3b82f6"></a>
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/actions/workflows/build.yml"><img alt="Desktop build" src="https://img.shields.io/github/actions/workflow/status/arunsasidharan84/CCS_EEGStudio/build.yml?style=for-the-badge&label=desktop%20build"></a>
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/arunsasidharan84/CCS_EEGStudio/total?style=for-the-badge&color=22c55e"></a>
</p>

<p align="center">
  Developed by the <b>Centre for Consciousness Studies</b>, Department of Neurophysiology,<br>
  <b>NIMHANS</b>, Bengaluru, India.
</p>

<p align="center">
  <b>Current version: 1.2.4</b> ·
  <a href="CHANGELOG.md">Detailed changelog</a> ·
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/issues">Report a problem</a>
</p>

CCS EEG Studio turns research EEG recordings into reproducible, analysis-ready outputs without requiring Python or MATLAB on the end user's computer. A Flutter desktop interface orchestrates a native Rust engine for preprocessing, source projection, epoch-wise features, functional connectivity, ERP analysis, microstates, topographic statistics, plots, and PDF reports.

> The algorithms are ported from [`ccs_toolbox`](https://github.com/arunsasidharan84/ccs_toolbox) and continuously checked against the Python reference implementations and MNE Connectivity.

### What is new in 1.2.4

- A synchronized microstate explorer with aligned sequence, EEG, and
  state-similarity timelines; selectable waveform density; and toggleable
  state traces.
- ERP scalp maps at a selected time point or averaged time window, including
  A, B, B−A, Welch-t, and FDR-corrected electrode significance views.
- Safer recording tabs for long filenames and clearer percentage-form
  microstate transition matrices.
- Reproducible macOS, Windows, Debian/Ubuntu, and RHEL-family releases built by
  GitHub Actions with checksums and version-specific notes.

See the [1.2.4 release notes](CHANGELOG.md#124) for the complete list.

![CCS EEG Studio Main Window](screenshots/main.png)

## Why CCS EEG Studio?

| | Capability |
|---|---|
| ⚡ | Native Rust processing with parallel epoch dispatch |
| 🧠 | Spectral, aperiodic, nonlinear, connectivity, ERP, source-space, and microstate analysis |
| 📊 | Channel-level CSVs, scalp maps, statistics, plots, and publication-ready PDF reports |
| 📁 | EDF/EDF+, EEGLAB SET/FDT, MNE FIF, FieldTrip MAT, BrainVision, and portable CCS EEG files |
| 〰️ | SleepStudio-style light waveform canvas with uniform traces and EEGLAB-style stitched epoch scrolling |
| 🧹 | Configurable GEDAI window/epoch size for continuous and memory-safe preprocessing |
| 🔁 | Single-recording exploration and unattended batch pipelines share one configuration |
| ⬆️ | Built-in update checker downloads the correct installer from GitHub Releases |

## About

CCS EEG Studio is a standalone desktop implementation of the CCS EEG analysis pipeline. The interface keeps raw, preprocessed, source-space, feature, and report stages visible in one workspace, while the computation engine owns the numerical work and writes outputs directly to disk.

The workflow is validated with deterministic fixtures and real recordings against `ccstools.eegfeatures`, MNE-Python, and `mne-connectivity`. See the parity scripts under [`scripts/`](scripts/) for reproducible comparisons.

---

## Download

Pre-built desktop packages are published through GitHub Releases. The links below always resolve to the newest versioned release.

| Platform | Package | Download |
|---|---|---|
| macOS | Ad-hoc-signed application ZIP | [CCSEEGStudio-macos.zip](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-macos.zip) |
| Windows 10/11 | x64 installer | [CCSEEGStudio-Installer.exe](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-Installer.exe) |
| Debian / Ubuntu | amd64 DEB | [CCSEEGStudio-linux-amd64.deb](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-linux-amd64.deb) |
| RHEL / AlmaLinux / Rocky | x86_64 RPM | [CCSEEGStudio-linux-x86_64.rpm](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-linux-x86_64.rpm) |

Every release also includes
[`SHA256SUMS.txt`](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/SHA256SUMS.txt)
for download verification.

Once installed, choose **Updates** in the app's top bar to check, download, and launch the correct update package. On macOS the app verifies, replaces, and restarts itself; Windows and Linux hand the downloaded package to the native installer.

### Linux installation

Debian, Ubuntu, or Linux Mint:

```sh
sudo apt install ./CCSEEGStudio-linux-amd64.deb
```

RHEL, AlmaLinux, or Rocky Linux:

```sh
sudo dnf install ./CCSEEGStudio-linux-x86_64.rpm
```

The Linux installers register the desktop entry and the `ccseegstudio` command. RPM packages are smoke-tested in AlmaLinux before publication.

### macOS Gatekeeper

If macOS blocks an ad-hoc-signed development build after download, extract it and run:

```sh
xattr -rd com.apple.quarantine ~/Downloads/ccs_eeg_app.app
```

Move the app to `/Applications` before using in-app updates so it has a stable installation location.

---

## Architecture

CCS EEG Studio uses a compact Flutter + Rust architecture:

1. **Flutter UI**: Provides the recording loader panel, channel selector, extraction options, and progress/results views. Heavy computation is never performed on the main Dart thread.
2. **Rust Engine (`ccs-eeg-engine`)**: A standalone CLI binary launched as a subprocess by the Flutter layer via JSON job files. It owns preprocessing and high-throughput feature computation:
   - Multi-threaded epoch dispatch via **Rayon** parallel iterators.
   - Spectral analysis (Welch/Hamming PSD, Morlet wavelet, coherence, PLV) via **rustfft**.
   - Linear algebra for GEDAI / source localization via **nalgebra**.
   - Nonlinear metrics (Sample Entropy, Lempel-Ziv, Hurst) in native Rust.
   - FOOOF and IRASA aperiodic decomposition ported from `analyseNidra`.
3. **Dart analysis layer**: ERP statistics, topographic statistics, interactive
   visualization, and publication reports run in background isolates and share
   the same portable recording metadata.
4. **File-backed jobs**: JSON jobs reference recording paths and the Rust engine writes CSV rows directly, avoiding unnecessary UI-layer copies during extraction.
5. **No External Runtimes**: No Python, MATLAB, or R installation is required on the user's machine.

---

## 📂 Repository Layout

```
CCS_EEGStudio/
├── lib/                        # Flutter front-end
│   ├── main.dart               # App entry point
│   └── src/
│       ├── app.dart            # Root widget, navigation, theme
│       ├── eeg_viewer.dart     # Multi-channel EEG waveform preview
│       ├── extraction_service.dart  # Rust engine subprocess driver
│       ├── models.dart         # Shared data models (Recording, Options, Row)
│       ├── edf_loader.dart     # EDF/EDF+ file parser
│       ├── fif_loader.dart     # MNE FIF format parser
│       ├── fieldtrip_mat_loader.dart # FieldTrip MAT integration
│       ├── recording_loader.dart    # Unified loader dispatcher
│       ├── set_loader.dart     # EEGLAB SET/FDT format parser
│       ├── update_checker.dart # GitHub release updater
│       └── vhdr_loader.dart    # BrainVision VHDR/EEG/VMRK parser
├── bridge/                     # Rust computation engine
│   ├── Cargo.toml              # Rust package manifest
│   └── src/
│       ├── lib.rs              # Shared types, band definitions, module declarations
│       ├── main.rs             # Job dispatch and output writing
│       ├── fieldtrip_loader.rs # FieldTrip structs and trial conversion
│       ├── mat_v5.rs           # MATLAB v5 structs, cells, chars, numerics
│       ├── mne_fif.rs          # Raw + epoched MNE FIF loading
│       ├── microstates.rs      # Microstate analysis
│       └── stats.rs            # Statistical utilities
├── scripts/                    # Build & packaging helper scripts
│   ├── build_macos.sh          # Local macOS app bundle packaging
│   ├── package_linux_deb.sh    # Debian/Ubuntu .deb installer builder
│   ├── package_linux_rpm.sh    # RHEL/AlmaLinux .rpm installer builder
│   └── *.py                    # Parity validation and comparison scripts
├── .github/workflows/
│   └── build.yml               # GitHub Actions CI: build + release for all platforms
├── test/                       # Flutter unit and integration tests
├── parity_test/                # Python vs Rust numerical parity fixtures and data
├── screenshots/                # README screenshots (main, channel_selection, preprocessing_options, feature_extraction_options, batch_analysis)
└── pubspec.yaml                # Flutter dependency manifest
```

---

## 🖥️ Application Screenshots

| Main Window | Channel Selection |
|---|---|
| ![Main Window](screenshots/main.png) | ![Channel Selection](screenshots/channel_selection.png) |

| Preprocessing Options | Feature Extraction Options |
|---|---|
| ![Preprocessing Options](screenshots/preprocessing_options.png) | ![Feature Extraction Options](screenshots/feature_extraction_options.png) |

![Batch Analysis Pipeline](screenshots/batch_analysis.png)

---

## 🧭 Two Workflow Modes

The app has exactly two modes, and the split between them is strict:

| | **Single Recording** | **Batch** |
|---|---|---|
| Input | Exactly one file | A queue of many files |
| Waveform viewer | ✅ Yes | ❌ No |
| Run granularity | One button per stage — stop, inspect, continue | Per stage, or all stages in sequence |
| Channel types | Auto-detected, reviewable and overridable per channel | Auto-detected per file |
| Outputs | One CSV + PDF + plots for that recording | One CSV/PDF/plot folder **per file**, plus a pooled CSV and a group overlay plot |
| Use it for | Exploring data, checking cleaning quality, dialling in settings | Unattended production runs |

Both modes bind to the **same** analysis configuration object. Every option
(preprocessing, source localisation, all fourteen feature families, epoching,
duration mode, plotting) appears in both places, and a setting you tune on one
recording carries straight over to the batch queue.

Choose **Pipeline Batch** to give the batch workspace the full application
area. Each card contains a clearly marked **Batch parameters · shared with
Single Recording** section. Folders can be added recursively as well as
individual files. During execution, a SleepStudio-style progress window shows
the current recording, overall progress, per-file success/failure state, live
logs, and cancellation controls.

Feature extraction streams one recording at a time and appends to the pooled
CSV incrementally. Large corpora therefore do not require every recording to
fit in RAM, and one malformed file is reported without aborting the remaining
queue.

### Pipeline stages

Each stage has its own **Run** button and can be entered directly by loading a
file into it:

1. **Preprocessing** — downsample, filter, bad-channel detection, GEDAI, interpolation
2. **Source Space** *(optional)* — eLORETA projection to 68 cortical ROIs
3. **Feature Extraction** — epoching, feature families, CSV output
4. **Plots & Report** — topoplots, line plots, group overlays, PDF report

### Channel types

Non-EEG channels are **auto-detected from their labels** on load — ECG, EOG,
EMG, GSR, respiration, PPG, motion/accelerometer, references and trigger
channels are each recognised as their own kind. The **Channel Types** panel in
Single Recording mode lists every channel with its detected kind and lets you
override any of them; whatever you set is exactly what reaches the engine.

This matters because auxiliary channels must be removed *before* the common
average reference is computed, and before bad-channel detection compares
per-channel variance against the median — an ECG or GSR trace left in either
pool corrupts the result for every real EEG channel.

Detection is token- and prefix-based rather than substring-based, so labels like
`FT9`, `TP10` and `Fp1` are never mistaken for auxiliary channels. EGI-style
`E1…E256` electrodes are deliberately treated as EEG; if your recording uses
`E1`/`E2` as AASM eye channels, mark them by hand.

---

## 🔬 Features

### Recording Formats Supported
- **EDF / EDF+** — Standard European Data Format, including Annotations (TAL) channels.
- **EEGLAB SET / FDT** — Standalone embedded `.set` data or `.set` plus external float32 `.fdt`.
- **FieldTrip MAT** — MATLAB v5 `ftData` structs with continuous numeric trials or cell-array trials.
- **BrainVision VHDR / EEG / VMRK** — BrainProducts binary and ASCII formats.
- **MNE FIF** — Continuous raw and epoched MNE-Python FIF recordings.
- **CCS EEG JSON** — Portable preprocessed or epoched recordings produced by the app.

> MATLAB v7.3/HDF5 containers are detected but require a separate HDF5 loader; MATLAB v5 FieldTrip files are supported natively.

### Preprocessing
- **Re-referencing**: Common-average reference (CAR) or arbitrary reference channel subtraction.
- **Channel exclusion**: Auto-detection of non-EEG channels (ECG, EOG, EMG, GSR, respiration, PPG, motion, references, triggers), reviewable and overridable per channel — see [Channel types](#channel-types).
- **Duration modes**: Full recording, fixed interval (start/end seconds), fixed bin size, or the *middle two minutes* mode used by the CCS pipeline.
- **Accepted / rejected interval masks**: Restrict extraction to annotated clean segments.
- **GEDAI windows**: Explicitly configure the window/epoch size used for GEDAI,
  with memory-safe pre-epoching for long recordings.
- **Stimulus epochs**: Cut event-locked trials after filtering and before GEDAI,
  retain marker labels and epoch timing, and optionally apply baseline
  correction.

### ERP analysis

- Define conditions from marker chips or regular expressions.
- Plot condition means ± SEM and test temporal clusters by permutation.
- Compute component-window Welch tests, Cohen's d, and bootstrap confidence
  intervals.
- Map both a selected latency and a time-window average over the scalp for
  condition A, condition B, B−A, and Welch t.
- Mark electrodes passing Benjamini–Hochberg FDR correction.

### EEG microstates

- Four- to eight-state solutions with canonical A–G template assignment.
- GFP, occurrence, duration, coverage, GEV, spatial correlation, sequence
  complexity, entropy production, and transition summaries.
- Synchronized sequence, waveform, and state-similarity exploration with one
  absolute-time axis.

### Spectral Analysis
- **Relative Welch / Hamming PSD** across 7 frequency bands:

  | Band | Range |
  |------|-------|
  | Delta | 1 – 4 Hz |
  | Theta | 4 – 8 Hz |
  | ThetaAlpha | 6 – 10 Hz |
  | Alpha | 8 – 12 Hz |
  | Beta1 | 12 – 18 Hz |
  | Beta2 | 18 – 30 Hz |
  | Gamma1 | 30 – 40 Hz |

- **FOOOF** (Fitting Oscillations & One-Over-F): Native Rust Levenberg-Marquardt implementation — isolates true oscillatory peaks from the aperiodic 1/f slope. Ported from `analyseNidra`.
- **IRASA** (Irregularly Resampled Auto-Spectral Analysis): Separates fractal and oscillatory PSD components using the geometric resampling approach.

![Preprocessing Options Sidebar](screenshots/preprocessing_options.png)

### Nonlinear Metrics
Eight epoch-wise nonlinear complexity and entropy metrics per channel:
- Sample Entropy (SampEn)
- Approximate Entropy (ApEn)
- Hurst Exponent
- Lempel-Ziv Complexity
- Autocorrelation Window (ACW)
- Detrended Fluctuation Analysis (DFA) exponent
- Higuchi Fractal Dimension
- Katz Fractal Dimension


### Connectivity Analysis
Nine connectivity measures computed via Morlet wavelet cross-spectra at the same frequencies and cycle counts used by `mne-connectivity 0.8`:

| Measure | Description |
|---------|-------------|
| **MIC** | Maximized Imaginary Coherence |
| **MIM** | Multivariate Interaction Measure |
| **GC** | Granger Causality (25-lag VAR) |
| **GC-TR** | Time-reversed Granger Causality |
| **Coherence** | Magnitude-squared coherence |
| **PLV** | Phase-Locking Value |
| **ciPLV** | Corrected Imaginary PLV |
| **PLI** | Phase-Lag Index |
| **wPLI** | Weighted Phase-Lag Index |

![Feature Extraction Options](screenshots/feature_extraction_options.png)

### Output
- **Per-file CSV export**: `<recording>.features.csv` for every input, with one row per (epoch, channel, bin) and all enabled feature columns.
- **Combined CSV export**: `Batch_features.csv` pooling every recording, carrying `filename`, `subjid`, `sessn` and `condn` columns so rows stay attributable.
- Both are written by default in Batch mode; either can be switched off.
- Column names exactly match `ccstools.eegfeatures` output for drop-in pipeline compatibility.

### Plot output layout

Plots are segmented by source recording rather than pooled, because a batch of
files typically spans different subjects or sessions that must not be averaged
together:

```
<output dir>/
  subj01_rest/     ← topoplots + line plots for this recording only
  subj02_rest/
  subj03_rest/
  group/           ← one figure per feature, one colour-coded trace per
                     recording on a shared time axis, with a legend
```

A pooled `Batch_features.csv` is split back into its constituent recordings via
its `filename` column, so plotting the combined CSV gives the same layout as
plotting the per-file CSVs. A single-recording run writes straight into the
output directory with no subfolders.

![Batch Analysis Pipeline](screenshots/batch_analysis.png)

---

## ✅ Scientific validation

The Rust engine is continuously checked against the Python reference extractor
using deterministic fixtures and real recordings. PSD relative band power,
IRASA oscillatory band powers, nonlinear metrics, ACW, and the common bivariate
connectivity measures agree to floating-point precision on the reference
datasets.

The validation suite also records known numerical sensitivities instead of
hiding them:

- FOOOF peak selection can diverge when the Python and Rust candidate-peak
  finders choose different models.
- MIC eigenvectors can change orientation/order for nearly degenerate
  cross-spectral matrices even when the underlying MIM subspace agrees.
- Gamma1 connectivity is more sensitive to short-epoch wavelet estimation than
  lower-frequency bands.

ERP waveforms and statistics are regression-tested against the Python workflow,
and topographic interpolation/statistics have dedicated synthetic and real-data
tests. Morlet frequencies, cycles, epoch grouping, and 25-lag GC configuration
remain matched to the reference pipeline.


See [`scripts/compare_parity.py`](scripts/compare_parity.py) and [`scripts/run_parity_test.sh`](scripts/run_parity_test.sh) for instructions on running your own parity validation against a reference dataset.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+O` | Open a recording file |
| `Ctrl+E` | Start extraction with current settings |
| `Ctrl+S` | Save / export results CSV |
| `Ctrl+,` | Open settings / configuration panel |
| `Escape` | Cancel running extraction |

---

## 🚀 Running & Building Locally

### Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable) | UI framework | See link |
| [Rust Toolchain](https://www.rust-lang.org/tools/install) (`cargo`) | Computation engine | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| [Inno Setup](https://jrsoftware.org/isinfo.php) (`iscc`) | Windows installer | Windows only |

### 1. Build the Rust Engine

Compile the native `ccs-eeg-engine` binary for your platform:
```sh
cd bridge
cargo build --release
```

The release binary will be at `bridge/target/release/ccs-eeg-engine` (macOS/Linux) or `bridge\target\release\ccs-eeg-engine.exe` (Windows).

### 2. Run the App in Development Mode

```sh
# Install Flutter dependencies
flutter pub get

# Run on macOS
flutter run -d macos

# Run on Windows
flutter run -d windows

# Run on Linux
flutter run -d linux
```

The Flutter app automatically discovers the engine binary from the build tree during development. Ensure `cargo build --release` has been run first.

### 3. Package a Production Release

#### macOS (`.app`)
```sh
# Builds Rust engine + Flutter app and places engine inside the .app bundle
./scripts/build_macos.sh
```

The script produces `build/macos/Build/Products/Release/ccs_eeg_app.app`, ad-hoc signed and ready to distribute.

#### Windows (`.exe` Installer via Inno Setup)
```sh
# Build Flutter Windows release
flutter build windows --release

# Copy engine binary beside the Flutter executable
copy bridge\target\release\ccs-eeg-engine.exe build\windows\x64\runner\Release\

# Create installer (requires Inno Setup)
iscc windows\installer.iss
```

#### Linux (`.deb` Debian/Ubuntu)
```sh
flutter build linux --release

# Copy engine binary into the bundle
cp bridge/target/release/ccs-eeg-engine build/linux/x64/release/bundle/

# Build .deb package
bash scripts/package_linux_deb.sh \
  build/linux/x64/release/bundle \
  dist/CCSEEGStudio-linux-amd64.deb
```

#### Linux (`.rpm` RHEL/AlmaLinux)
```sh
flutter build linux --release

cp bridge/target/release/ccs-eeg-engine build/linux/x64/release/bundle/

bash scripts/package_linux_rpm.sh \
  build/linux/x64/release/bundle \
  dist/CCSEEGStudio-linux-x86_64.rpm
```

---

## 🧪 Running Tests

### Rust Engine Tests
```sh
cd bridge && cargo test
```

Unit tests cover the core spectral, connectivity, nonlinear, and aperiodic modules against deterministic fixtures.

### Flutter Tests
```sh
flutter analyze
flutter test

# Run sample-loader integration test with real EEG data
CCS_EEG_SAMPLE_DATA=/path/to/sampleData flutter test test/sample_loader_test.dart
```

### Parity Tests (Python vs Rust)
Parity scripts compare Rust engine output against the Python reference on real EDF and SET recordings:

```sh
# Full parity run (requires Python + ccstools + mne-connectivity installed)
bash scripts/run_parity_test.sh /path/to/recording.set /path/to/reference_output.csv

# GEDAI parity
bash scripts/run_gedai_parity_test.sh /path/to/recording.set

# Individual comparison scripts
python scripts/compare_parity.py
python scripts/compare_gedai_signals.py
```

---

## 🤖 Automated Builds (GitHub Actions)

Desktop installers are built on a `v*` tag, on a `main`/`master` commit carrying
`[build desktop]`, or via manual workflow dispatch. Tagged releases are
permanent; branch builds update the rolling `latest` prerelease.

**To trigger a build from a commit:**
```
git commit -m "feat: improve connectivity speed [build desktop]"
git push
```

The workflow (`.github/workflows/build.yml`) runs three parallel jobs:

| Job | Runner | Output |
|-----|--------|--------|
| `build-macos` | `macos-15` | `CCSEEGStudio-macos.zip` |
| `build-windows` | `windows-2022` | `CCSEEGStudio-Installer.exe` |
| `build-linux` | `ubuntu-22.04` | `CCSEEGStudio-linux-amd64.deb` + `CCSEEGStudio-linux-x86_64.rpm` |

Before compiling, CI verifies that the tag, `pubspec.yaml`, Windows installer
version, and matching `CHANGELOG.md` section agree. After all three platform
jobs complete, the release job assembles the installers, generates SHA-256
checksums, and publishes the exact changelog section as the release notes.

The Linux RPM is smoke-tested inside an **AlmaLinux 9** Docker container before upload to confirm library resolution on RHEL-family systems.

### Publishing a version

1. Set `version:` in `pubspec.yaml` and keep the Windows installer fallback at
   the same semantic version.
2. Add a detailed `## [x.y.z]` section to [`CHANGELOG.md`](CHANGELOG.md).
3. Commit the release and push the matching `vx.y.z` tag.

```sh
git tag -a v1.2.4 -m "CCS EEG Studio 1.2.4"
git push origin main v1.2.4
```

CI refuses mismatched tags or missing changelog sections. This helper shows
exactly what will become the GitHub Release description:

```sh
bash scripts/release_notes.sh 1.2.4
```

---

## 📋 Parity Validation Scripts Reference

| Script | Purpose |
|--------|---------|
| [`scripts/compare_parity.py`](scripts/compare_parity.py) | Full feature-by-feature comparison of Rust vs Python output CSVs |
| [`scripts/compare_filter.py`](scripts/compare_filter.py) | Filter kernel and output comparison |
| [`scripts/compare_gedai_signals.py`](scripts/compare_gedai_signals.py) | GEDAI source separation comparison |
| [`scripts/run_parity_test.sh`](scripts/run_parity_test.sh) | Shell driver: runs Rust engine + Python reference then compares |
| [`scripts/run_gedai_parity_test.sh`](scripts/run_gedai_parity_test.sh) | Shell driver for GEDAI-specific parity |
| [`scripts/python_extract_headlessly.py`](scripts/python_extract_headlessly.py) | Python reference extractor (headless, no GUI) |
| [`scripts/test_pipeline_steps.py`](scripts/test_pipeline_steps.py) | Step-by-step pipeline comparison |
| [`scripts/test_wavelet.py`](scripts/test_wavelet.py) | Morlet wavelet cross-spectra validation |
| [`scripts/test_gevd.py`](scripts/test_gevd.py) | Generalized eigenvalue decomposition validation |

---

## 🔗 Related Repositories

| Repository | Description |
|------------|-------------|
| [ScoringNidra](https://github.com/arunsasidharan84/ScoringNidra) | Sleep EEG visualization, manual scoring, automated staging, and AnalyseNidra quantitative reports |
| [CCS Sleep Studio](https://github.com/arunsasidharan84/CCS_SleepStudio) | Sleep recording review, scoring, preprocessing, batch analysis, and reporting |

---

## 📄 License

Proprietary — Centre for Consciousness Studies, NIMHANS, Bangalore, India.
All rights reserved.
