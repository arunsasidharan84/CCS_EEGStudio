<p align="center">
  <img src="screenshots/ccs_logo.png" width="160" alt="Centre for Consciousness Studies Logo">
</p>

<h1 align="center">CCS EEG Studio</h1>

<p align="center">
  <b>Native-speed EEG preprocessing, feature extraction, connectivity, statistics, and reporting</b>
</p>

<p align="center">
  A Research & Engineering Collaboration of<br>
  <b>Centre for Consciousness Studies (CCS)</b>, Department of Neurophysiology,<br>
  <b>National Institute of Mental Health and Neurosciences (NIMHANS)</b>, Bengaluru, India<br>
  🤝<br>
  <a href="https://axxonet.com/"><b>Axxonet</b></a>
</p>

<p align="center">
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/arunsasidharan84/CCS_EEGStudio?style=for-the-badge&color=2563eb&label=RELEASE"></a>
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/actions/workflows/build.yml"><img alt="Desktop build" src="https://img.shields.io/github/actions/workflow/status/arunsasidharan84/CCS_EEGStudio/build.yml?style=for-the-badge&label=BUILD"></a>
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/arunsasidharan84/CCS_EEGStudio/total?style=for-the-badge&color=16a34a&label=DOWNLOADS"></a>
</p>

<p align="center">
  <b>Current version: 1.2.16</b> ·
  <a href="CHANGELOG.md">Detailed changelog</a> ·
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/issues">Report a problem</a>
</p>

> **Important in 1.2.16:** corrected preprocessing resampling/event alignment, including 256→250 Hz. Version 1.2.15 used an incorrect rate ratio that can shift response-locked samples and reverse an ERP contrast. Regenerate affected outputs from their original inputs; an application update cannot repair already-misaligned epochs. See [the diagnosis, validation and recovery guidance](docs/erp_workbench.md#resampling-correction-and-existing-results). Individual-trial measurement CSV export is now optional and off by default; use `erp_measurements.csv` for conventional ERP condition averages.

### ERP analysis and interactive batch review — 1.2.15

The ERP workspace now supports single-recording and batch ERP CORE analysis for **MMN, N170, N2pc, N400, P3, LRP and ERN**. Import a folder, inspect proposed marker assignments, review task-specific windows/ROIs, and run to obtain waveforms, peaks/mean amplitudes/AUC, participant-level statistics, topographical inference and a compact PDF. Custom event classes and per-task settings are editable. Interactive ERP uses the active saved trial file and asks for condition groups; all multi-recording work is under Batch Workspace profiles for EEG, ERP and Microstates.

Optional native Rust analyses include multichannel rERP, sparse continuous FIR overlap correction, shrinkage-LDA decoding and temporal generalization. Metadata-driven group models accept condition or difference-wave measurements. The FIR model implements a defined linear subset of Unfold; complete toolbox parity is not claimed. A 14-recording ERP CORE pilot matched independently reconstructed MNE/NumPy trial counts and ROI waveforms.

**Recommended ERP workflow:**

1. Open a recording and choose locking events, named condition groups, trial limits and baseline. **Epoch Events** and Preprocess share the same protocol.
2. For already-cleaned data, choose **Epoch only (keep existing cleaning)**; otherwise review the cleaners and run **Clean + epoch**. Saved files distinguish `-epo` from `-epo_clean`.
3. Select saved A/B conditions, component, ROI and measurement window, then **Average & analyse ERP**. Trials are reused, not cut a second time.
4. For multiple recordings, use **Batch Workspace → ERP**. Open **Interactive batch review** to select participants or individual recordings, overlay differences, adjust the measurement window, inspect scalp maps and view equal-participant grand averages with ±1 SEM.
5. Label participant cohorts, select CSV parameters, and export or open group statistics. Exported measurements use unsmoothed waveforms. Save/load protocols to reuse event definitions and analysis settings.

**Interpretation:** negative-up is a display convention; component polarity selects a peak and never flips voltages. The difference is always B−A. Conventional ERN comparison is A=Correct, B=Incorrect. Additional cleaning can change an ERP that was already cleaned upstream. Existing files are not silently repaired or inverted. Live window changes update descriptive measurements/maps; inferential tests require a new group-statistics run. Older ERP results need re-averaging for arbitrary-window scalp maps.

**Additional native methods:** MNE, dSPM, sLORETA and LCMV inverse operators, imported fixed-orientation forward/atlas models, Gaussian-copula MI, within-epoch lagged-time transfer entropy, and configurable graph summaries. HCPex requires a compatible user-supplied atlas/forward model; atlas data are not bundled. See [source methods, graph definitions, estimator scope and references](docs/source_information_graph.md) and [event-preserving feature exports](docs/feature_event_markers.md).

See [ERP workflow, methods, references, numerical validation and limitations](docs/erp_workbench.md). Version 1.2.15 includes these workflows. Open **Updates** to download the release for your platform.

<p align="center">
  <a href="#-quick-download"><b>📥 Download App</b></a> &nbsp;•&nbsp;
  <a href="#about"><b>About</b></a> &nbsp;•&nbsp;
  <a href="#-features"><b>Features</b></a> &nbsp;•&nbsp;
  <a href="#-running--building-locally"><b>Build from Source</b></a> &nbsp;•&nbsp;
  <a href="CHANGELOG.md"><b>Release Notes</b></a> &nbsp;•&nbsp;
  <a href="https://github.com/arunsasidharan84/CCS_EEGStudio/issues"><b>Report Issue</b></a>
</p>

---

### 📥 Quick Download

Pre-built standalone desktop installers and application bundles are published through GitHub Releases:

| Platform | Package Type | Extracted App / Binary | Direct Download Link |
| :--- | :--- | :--- | :--- |
| **macOS** | Apple Silicon ZIP (macOS 12+) | **`CCS EEG Studio.app`** | [CCSEEGStudio-macos.zip](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-macos.zip) |
| **Windows** | 64-bit installer (Windows 10/11) | `CCSEEGStudio-Installer.exe` | [CCSEEGStudio-Installer.exe](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-Installer.exe) |
| **Linux (Debian / Ubuntu)** | amd64 DEB package | `ccseegstudio` | [CCSEEGStudio-linux-amd64.deb](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-linux-amd64.deb) |
| **Linux (RHEL / AlmaLinux)** | x86_64 RPM package | `ccseegstudio` | [CCSEEGStudio-linux-x86_64.rpm](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/CCSEEGStudio-linux-x86_64.rpm) |

> 📦 **All Releases & Checksums:** Every release includes [`SHA256SUMS.txt`](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest/download/SHA256SUMS.txt) for cryptographic verification. View all packages on the **[GitHub Releases Page](https://github.com/arunsasidharan84/CCS_EEGStudio/releases/latest)**.  
> 🔄 **In-App Upgrades:** Once installed, choose **Updates** in the app's top bar to check, download, and apply the correct update package automatically.

#### 🍏 First-Time Launch for macOS Users (Gatekeeper Setup)

When you download and unzip **`CCSEEGStudio-macos.zip`**, macOS extracts **`CCS EEG Studio.app`** into your `~/Downloads` folder. Because development releases are ad-hoc signed, macOS Gatekeeper blocks opening them by default.

To enable the app, run the following in **Terminal**:

```sh
# 1. Clear Gatekeeper quarantine on the downloaded app:
xattr -rd com.apple.quarantine ~/Downloads/CCS\ EEG\ Studio.app

# 2. Move to Applications folder:
mv ~/Downloads/CCS\ EEG\ Studio.app /Applications/
```

> **Tip (Finder alternative):** In Finder, **Right-click (or Control-click)** `CCS EEG Studio.app` → select **Open** → click **Open** on the security confirmation prompt. You only need to do this once.

#### 🐧 Multi-User Linux Server Setup (AlmaLinux / RHEL / Ubuntu / Debian)

To install or update CCS EEG Studio across all current and future user accounts on an Enterprise Linux or Ubuntu/Debian multi-user server (with executable desktop shortcuts in `/serverdata/ccshome/*/Desktop`, `/etc/skel/Desktop/`, and the Applications menu):

```bash
# Automated multi-user installation:
curl -fsSL https://raw.githubusercontent.com/arunsasidharan84/CCS_EEGStudio/main/scripts/install_linux.sh | sudo bash
```

Once installed, administrators or sudo users can update the server to the newest release anytime with a single command:
```bash
sudo update-ccs-eeg-studio
```

<p align="center">
  <img src="screenshots/main.png" width="920" alt="CCS EEG Studio Main Window">
</p>

---

## About

**CCS EEG Studio** turns research EEG recordings into reproducible, analysis-ready outputs without requiring Python or MATLAB on the end user's computer. A Flutter desktop interface orchestrates a native Rust engine for preprocessing, source projection, epoch-wise features, functional connectivity, ERP analysis, microstates, topographic statistics, plots, and PDF reports.

> The algorithms are ported from [`ccs_toolbox`](https://github.com/arunsasidharan84/ccs_toolbox) and continuously validated against Python reference implementations and MNE Connectivity.

### Why CCS EEG Studio?

| | Capability |
| :---: | :--- |
| ⚡ | Native Rust processing with parallel epoch dispatch via Rayon |
| 🧠 | Spectral, aperiodic, nonlinear, connectivity, ERP, source-space, and microstate analysis |
| 📊 | Channel-level CSVs, scalp maps, statistics, plots, and publication-ready PDF reports |
| 📁 | EDF/EDF+, EEGLAB SET/FDT, MNE FIF, FieldTrip MAT, BrainVision, and portable CCS EEG files |
| 〰️ | SleepStudio-style light waveform canvas with uniform traces and EEGLAB-style stitched epoch scrolling |
| 🧹 | Configurable GEDAI window/epoch size for continuous and memory-safe preprocessing |
| 🔁 | Single-recording exploration and unattended batch pipelines share one configuration |
| ⬆️ | Built-in update checker downloads and installs verified packages directly from GitHub Releases |

---

## 🌟 What's New in Version 1.2.14

- **Stacked Multi-Group Plots & Reports**: Compare multiple recordings, subjects, or experimental days stacked vertically in the TopoStats view. Includes `+ Add group` folder/CSV actions, active group sidebar selection, synchronized zoom, and multi-page PDF reporting.
- **MMN ERP Stimulus Epoching Fix**: Preserved stimulus-locked trials (`source_epoch_samples > 0`) during preprocessing by preventing continuous sliding-window overlap slicing on epoched datasets. Re-verified multi-session MMN analysis parity across all recording days.
- **Lateral Spread Reduction & Width Controls**: Quick width presets (`Compact 0.35"`, `Medium 0.5"`, `Wide 0.8"`) and responsive layout recalculation to easily compress wide plots for long recordings without re-running statistical permutations.
- **Group Statistics & Mixed Model Workbench**: Aligned pooled CSV columns by name, robust numeric imports, searchable bounded recording lists, and advisory short-window DFA/fE:I checks.

> 📜 See the complete **[CHANGELOG.md](CHANGELOG.md)** for detailed feature notes across all releases.

---

## 🧭 Two Workflow Modes

The app provides two dedicated operating modes sharing a unified configuration engine:

| | **Single Recording** | **Batch Pipeline** |
| :--- | :--- | :--- |
| **Input** | Exactly one file | A queue of many files or recursive directory |
| **Waveform viewer** | ✅ Yes, real-time inspection | ❌ No, optimized for throughput |
| **Run granularity** | One button per stage — stop, inspect, continue | Per stage, or all stages in sequence |
| **Channel types** | Auto-detected, reviewable and overridable per channel | Auto-detected per file |
| **Outputs** | One CSV + PDF + plots for that recording | One CSV/PDF/plot folder **per file**, plus pooled CSV and group overlay plot |
| **Use case** | Exploring data, tuning cleaning settings, dialling in parameters | Unattended production and cohort processing |

Both modes bind to the **same** analysis configuration object. Every option (preprocessing, source localisation, all fourteen feature families, epoching, duration mode, plotting) appears in both places, and a setting tuned on one recording carries directly over to the batch queue.

### Pipeline Stages
1. **Preprocessing** — downsampling, zero-phase filtering, bad-channel detection, GEDAI artifact removal, interpolation.
2. **Source Space** *(optional)* — MNE, dSPM, sLORETA, or LCMV projection using bundled fsaverage/Desikan–Killiany or an imported forward/atlas model.
3. **Feature Extraction** — epoching, multi-domain feature families, CSV outputs.
4. **Plots & Reports** — topoplots, time-series plots, group overlays, publication-grade PDF report.

### Recording preparation and advanced settings

Use **Crop / subepoch and save** before analysis to select marker or time bounds,
then optionally create sliding windows with overlap. Already epoched recordings
support within-trial crops or complete-trial selection; subwindows never cross
parent boundaries. Save the prepared recording for later reuse. Settings icons
expose output/feature references, filter design, interpolation, source SNR/regions,
Welch estimation, custom frequency bands, nonlinear parameters, and GC lags.
File selectors support `*`, `?`, and semicolon-separated filename patterns.

Plots support manual session ordering and line colors. Reopening saved cleaned
recordings recovers preprocessing/source history and adjacent analysis outputs.
See [workflow details and analysis conventions](docs/workflow_improvements.md).

### Preprocessed dataset batches

**Version 1.2.13** fixes continuous FieldTrip files appearing as one saved epoch
and failing extraction. A one-cell continuous FieldTrip trial now remains
continuous; full-resolution engine samples are kept separate from waveform previews.

To test a subset: enable **Already preprocessed: start with features**, enter 10
under **Folder import: first N subjects**, then import the folder in the feature
stage. Set the epoch length and overlap; enable **Subepoch existing trials** only
when existing parent trials should be subdivided. Saved preprocessing overlap is
formed after cleaning so each source sample is cleaned once. Stage 4 opens the
metadata/model workbench after the feature/plot stages when requested.

Use **Infer metadata from filenames…** to preview BIDS Subject/Session/Task/Run/
Acquisition fields or a custom named-group pattern, then save the reviewed CSV.
Unknown fields stay blank. Choose the subject ID, factors and outcomes before
running group inference. Two-second fE:I remains available for bands/windows that
pass its validity checks; the window warning is advisory.


Batch Workspace can start directly with features for already-cleaned data, limit
folder imports by subject count, create overlapping analysis windows and hand the
successful outputs to Stage 4 group statistics. Filename metadata inference has a
review/save preview and custom named-group patterns. See the
[psiconnect workflow and pilot checks](docs/psiconnect_batch_workflow.md).

### Easier results selection

Plotting has a results-folder button, a bounded searchable recording list and
bulk comparison controls. Group Statistics accepts a folder or multiple feature
CSVs, aligns pooled columns, normalizes numeric imports, and shows a clear run
control after inspection. The Continuous EEG sidebar includes Group Statistics.
See the [results workflow](docs/intuitive_results_workflow.md) for channel-scope
choices, where reports are saved, and the separately labeled short-epoch
### Adjusting Plots and Reducing Lateral Spread

When analyzing recordings with long durations (e.g. 60–90 minute sessions) or many sessions, plotting topomaps for every 2-minute window can create a very wide horizontal aspect ratio (e.g., 50+ inches). You can easily adjust and compress the lateral spread:

1. **Width Presets (`Topo width`)**: Under **TOPOMAPS** in the sidebar, click the **`Compact (0.35")`** or **`Medium (0.5")`** preset pills (or enter a custom value such as `0.3` and press Enter). This instantly scales down the width of every topomap column without having to re-run the permutation statistics.
2. **Window Duration (`Window`)**: Under **WINDOWS & LINE PLOT**, increase **`Window`** from `2.0 min` to `5.0 min` or `10.0 min`. This decreases the number of topomap columns by 2.5× to 5×, yielding a balanced, publication-ready figure width.
3. **Fit View in Canvas**: Click **`Fit`** in the top toolbar to automatically fit the entire figure width into the current window, eliminating horizontal scrolling.
4. **Stacked Multi-Group Display**: When comparing multiple days or recordings, use **`Add group`** to load them as separate stacked plot groups rather than stringing all sessions into a single wide plot.

### Metadata and group statistics

Open **Group Statistics** from the batch workspace or Full Pipeline. Join feature
CSVs to metadata CSV/XLSX and select subject ID, group, optional within-subject
factor, covariates, and outcomes. The SleepStudio-derived workbench provides LMM
with subject random intercepts and GLM with robust/clustered covariance,
model-adjusted contrasts, and multiple-comparison correction. Epochs are aggregated
per recording/channel/condition before modeling; multiple subjects are required.

This optional feature needs a local Python environment:

```sh
python3 -m venv .venv-group-stats
.venv-group-stats/bin/python -m pip install -r assets/requirements-group-stats.txt
# Launch the app from a shell with this interpreter configured:
export CCS_EEG_PYTHON="$PWD/.venv-group-stats/bin/python"
```

On Windows, use the environment's `Scripts/python.exe` and set `CCS_EEG_PYTHON`
accordingly. The requirements file includes optional XLSX and Word/PDF dependencies.
No external LLM service is used. Failed mixed models are reported without a silent
OLS fallback. See [1.2.10 release notes](CHANGELOG.md#1210) for compatibility details.

### Channel Types
Non-EEG channels are **auto-detected from their labels** on load — ECG, EOG, EMG, GSR, respiration, PPG, motion/accelerometer, references and trigger channels are each recognized as their own kind. The **Channel Types** panel in Single Recording mode lists every channel with its detected kind and lets you override any of them; whatever you set is exactly what reaches the engine.

---

## 🔬 Features

### Recording Formats Supported
- **EDF / EDF+** — Standard European Data Format, including Annotations (TAL) channels.
- **EEGLAB SET / FDT** — Standalone embedded `.set` data or `.set` plus external float32 `.fdt`.
- **FieldTrip MAT** — MATLAB v5 `ftData` structs with continuous numeric trials or cell-array trials.
- **BrainVision VHDR / EEG / VMRK** — BrainProducts binary and ASCII formats.
- **MNE FIF** — Continuous raw and epoched MNE-Python FIF recordings.
- **CCS EEG JSON** — Portable preprocessed or epoched recordings produced by the app.

### Preprocessing
- **Re-referencing**: Common-average reference (CAR) or arbitrary reference channel subtraction.
- **Channel exclusion**: Auto-detection of non-EEG channels (ECG, EOG, EMG, GSR, respiration, PPG, motion, references, triggers), reviewable and overridable per channel.
- **Duration modes**: Full recording, fixed interval (start/end seconds), fixed bin size, or the *middle two minutes* mode used by the CCS pipeline.
- **Accepted / rejected interval masks**: Restrict extraction to annotated clean segments.
- **GEDAI windows**: Explicitly configure the window/epoch size used for GEDAI, with memory-safe pre-epoching for long recordings.
- **Stimulus epochs**: Cut event-locked trials after filtering and before GEDAI, retain marker labels and epoch timing, and optionally apply baseline correction.

### ICA, ASR and muscle cleaning

Preprocess offers opt-in **Infomax/runica or Picard ICA**, blink and second-stage
ICLabel removal, **ASR Correct/Reject** with selectable variants, and **BSS-CCA,
iCanClean or wavelet ICA**. Parameters are exposed through the settings icon.
The processing order is bad-channel detection → ICA → muscle cleaner → ASR →
fixed-window epoching/GEDAI → interpolation → output reference/source projection.
ICA requires at least 8 good located 10-05 channels and 20 seconds of continuous
input. These cleaners skip already epoched data, including stimulus trials cut
before this stage. ASR Reject changes the timeline; Correct preserves its length.

Standard/Riemannian ASR, runica/Picard, ICLabel, BSS-CCA, iCanClean and wICA have
specific numerical reference checks. Adaptive ASR is our EMA design; E-ASR and
mode-based ASR combinations are experimental adaptations without original-code
parity. They are not interchangeable implementations of every similarly named
published algorithm. See [method references and scoped validation](docs/methods_and_validation.md)
for parameter conventions, evidence and limits.

### ERP Analysis
- Define conditions from marker chips or regular expressions.
- Plot condition means ± SEM and test temporal clusters by permutation.
- Compute component-window Welch tests, Cohen's d, and bootstrap confidence intervals.
- Map both a selected latency and a time-window average over the scalp for condition A, condition B, B−A, and Welch t.
- Mark electrodes passing Benjamini–Hochberg FDR correction.

### EEG Microstates
- Four- to eight-state solutions with canonical A–G template assignment.
- GFP, occurrence, duration, coverage, GEV, spatial correlation, sequence complexity, entropy production, and transition summaries.
- Synchronized sequence, waveform, and state-similarity exploration with one absolute-time axis.

### Spectral Analysis
- **Relative Welch / Hamming PSD** across 7 frequency bands:
  - Delta (1–4 Hz), Theta (4–8 Hz), ThetaAlpha (6–10 Hz), Alpha (8–12 Hz), Beta1 (12–18 Hz), Beta2 (18–30 Hz), Gamma1 (30–40 Hz).
- **FOOOF** (Fitting Oscillations & One-Over-F): Native Rust Levenberg-Marquardt implementation — isolates true oscillatory peaks from the aperiodic 1/f slope.
- **IRASA** (Irregularly Resampled Auto-Spectral Analysis): Separates fractal and oscillatory PSD components using geometric resampling.

### Nonlinear Metrics
Eight epoch-wise nonlinear complexity and entropy metrics per channel:
- Sample Entropy (SampEn), Approximate Entropy (ApEn), Hurst Exponent, Lempel-Ziv Complexity, Autocorrelation Window (ACW), Detrended Fluctuation Analysis (DFA) exponent, Higuchi Fractal Dimension, Katz Fractal Dimension.

### Compact reports and DFA/fE:I context

Analysis PDFs now default to a compact summary, one representative waveform page,
scalp maps with fitted head outlines/contours, selected time courses and key statistics.
Detailed reports remain selectable. Waveform scaling accounts for decimated previews
and keeps shown peaks inside their rows on shared raw/cleaned scales.

DFA/fE:I can use a separate source context (UI default 60 s; zero means epoch only)
without enlarging PSD or other feature epochs. Context cannot cross saved trial
boundaries. Its actual bounds are written to CSV metadata. Missing DFA no longer
passes the fE:I qualification gate. See the [report/context guide](docs/report_and_dfa_context.md)
for method references, the five-second-data explanation and scoped validation.

### Feature windows and output defaults

Before extraction, the app warns about short selected-feature windows: DFA/fE:I
below the practical 60-second full-band recommendation, FOOOF/IRASA below one
second, a Welch window longer than the epoch, or too few samples for the GC lag
count. Saved parent-epoch lengths take precedence over the extraction control.
Choose **Change settings** or explicitly continue with limited/missing results;
batch runs ask once for each distinct warning. The app never merges trials silently.

The 60-second DFA/fE:I recommendation accommodates the implementation's long
fit scales; it is not a universal paper-prescribed minimum or a guarantee that
fE:I passes its validity criteria. For two-second windows, lower-band estimates
may be missing even though Gamma1 DFA is available. See the method references
below and the [window/output guide](docs/output_files.md).

Defaults now retain per-recording CSVs, analysis PDFs, and combined plots PDFs
with statistics tables. A pooled CSV and individual high-resolution PNGs are
optional exports. Disabling the plots PDF generates PNGs instead. New summary
reports use `.analysis_report.pdf`. Cleaned recordings and provenance companions
remain; existing output files are not automatically deleted.

### Band-limited DFA and fE:I

The optional DFA/fE:I family estimates amplitude-envelope scaling and a functional
excitation/inhibition index in each selected band. It follows Hardstone et al.
(2012) and Bruining et al. (2020), with windows clamped to available samples and
missing values for bands that cannot fit. Short epochs do not establish long-range
correlations at the literature's timescales. Method papers and implementation
conventions are listed below and in the [validation guide](docs/methods_and_validation.md).

### Connectivity Analysis
Nine connectivity measures computed via Morlet wavelet cross-spectra matching `mne-connectivity 0.8`:
- **MIC** (Maximized Imaginary Coherence), **MIM** (Multivariate Interaction Measure), **GC** (Granger Causality 25-lag VAR), **GC-TR** (Time-reversed GC), **GC − GC-TR contrast**, **Coherence**, **PLV**, **ciPLV**, **PLI**, **wPLI**.

### Outputs & Plot Layout

See the [output file guide](docs/output_files.md) for compact defaults, report names,
provenance companions, optional exports and short-window warnings.

- **Per-file CSV export**: `<recording>.features.csv` for every input, with one row per (epoch, channel, bin) and all enabled feature columns.
- **Optional combined CSV export**: `Batch_features.csv` pooling every recording with provenance metadata (`subjid`, `sessn`, `condn`).
- **Publication-grade PDF reports & Scalp Maps**: High-resolution vector visualizations and executive summaries.

---

### Time-aligned feature annotations

Feature CSVs now retain time-aligned annotations in `event_markers`; feature line plots display event labels and duration shading, including exports made with overlapping epochs. See [event marker format and timeline support](docs/feature_event_markers.md).

### Source, information connectivity, and graphs

Source settings now select **MNE, dSPM, sLORETA, or LCMV**, with a bundled fsaverage model or an imported fixed-orientation forward/atlas model. HCPex grid-mapping tooling supports compatible supplied volumetric models. The old “eLORETA” label described a minimum-norm implementation and has been corrected.

Features add **GCMI**, **within-epoch temporal TE**, and **pair / graph / combined exports** for information and selected spectral connectivity. Graph summaries work on electrode or ROI inputs. See [methods, reference tests, atlas import, and supported parity scope](docs/source_information_graph.md) before interpreting these measures.

### ERP preparation and protocol reuse

**Epoch Events** and Preprocess share event groups, trial windows and baseline settings. Direct epoching saves `-epo.ccseeg.json`; preprocessing saves `-epo_clean.ccseeg.json` when the output contains trials. Continue with **Next: average and analyse saved trials**, select saved A/B conditions, review the component/ROI/window, then **Average & analyse ERP**. Original and processed recordings remain available when switching.

Use **Save protocol / Load protocol** to reuse epoching and averaging settings interactively or in the ERP Batch Workspace. Hover over the protocol help icon for the sequence. Review event/group matches on each dataset. See the [ERP workflow and protocol guide](docs/erp_workbench.md#reusable-epoching-and-averaging-protocols).

### Interactive ERP batch comparisons

After averaging, open **Interactive batch review** to search/select participants, inspect individual recordings or participant averages, overlay differences, and view equal-participant grand averages with ±1 SEM shading. Adjust measurement windows to update descriptive measurements and scalp maps live. Optional smoothing affects display only. Label participant cohorts and export selected ERP metrics to CSV or open group statistics. See the [review guide](docs/erp_workbench.md#interactive-batch-review-smoothing-and-cohort-labels).

For already-cleaned recordings, **Epoch only (keep existing cleaning)** preserves the supplied signal while preparing trials. A/B subtraction and negative-up display are labelled explicitly; unexpected ERP polarity is not automatically inverted.

## 🖥️ Application Screenshots

| Main Workspace | Channel Selection & Overrides |
| :---: | :---: |
| ![Main Window](screenshots/main.png) | ![Channel Selection](screenshots/channel_selection.png) |

| Preprocessing Configuration | Feature Extraction Families |
| :---: | :---: |
| ![Preprocessing Options](screenshots/preprocessing_options.png) | ![Feature Extraction Options](screenshots/feature_extraction_options.png) |

| Batch Analysis Pipeline |
| :---: |
| ![Batch Analysis Pipeline](screenshots/batch_analysis.png) |

---

## ⚡ Architecture

CCS EEG Studio uses a decoupled Flutter + Rust architecture:

1. **Flutter UI**: Provides recording navigation, channel selection, parameter tuning, progress visualization, and report generation.
2. **Rust Engine (`ccs-eeg-engine`)**: A standalone CLI binary launched as a subprocess via structured JSON job files:
   - Parallel epoch computation via **Rayon** multi-threading.
   - Spectral analysis (Welch PSD, Morlet wavelets, coherence, PLV) via **rustfft**.
   - Linear algebra for GEDAI and source localization via **nalgebra**.
   - Native implementations of FOOOF, IRASA, and nonlinear metrics.
3. **Dart Analysis Layer**: ERP statistics, permutation clustering, topographic interpolation, and PDF reporting in background isolates.
4. **Core analysis**: EEG preprocessing, extraction, ERP, microstates, and plotting run without Python, MATLAB, or R. The optional group-statistics workbench uses a local Python environment.

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
├── test/                       # Flutter unit and integration tests
├── parity_test/                # Python vs Rust numerical parity fixtures
└── screenshots/                # Application documentation screenshots
```

---

## ✅ Scientific Validation

The Rust engine is continuously verified against Python reference implementations (`ccstools.eegfeatures`, MNE-Python, and `mne-connectivity`):
* PSD relative band powers, IRASA oscillatory powers, nonlinear metrics, ACW, and bivariate connectivity agree to floating-point precision on reference datasets.
* ERP waveforms and permutation cluster statistics are regression-tested against reference pipelines.
* Topographic scalp interpolation and FDR significance tests have dedicated synthetic and empirical test suites.

See [`scripts/compare_parity.py`](scripts/compare_parity.py) and [`scripts/run_parity_test.sh`](scripts/run_parity_test.sh) for instructions on running parity validation suites.

---

## 📚 Method references

| App method | Paper or original implementation | Studio convention |
| :--- | :--- | :--- |
| Infomax ICA / runica | Bell & Sejnowski (1995), [doi:10.1162/neco.1995.7.6.1129](https://doi.org/10.1162/neco.1995.7.6.1129); [EEGLAB source](https://github.com/sccn/eeglab) | Native runica/pop_runica port; fixed seed; two-stage CCS component selection. |
| Picard | Ablin, Cardoso & Gramfort (2018), [doi:10.1109/TSP.2018.2844203](https://doi.org/10.1109/TSP.2018.2844203); [original code](https://github.com/mind-inria/picard) | Port of python-picard 0.8. |
| ICLabel | Pion-Tonachini, Kreutz-Delgado & Makeig (2019), [doi:10.1016/j.neuroimage.2019.05.026](https://doi.org/10.1016/j.neuroimage.2019.05.026); [classifier source](https://github.com/sccn/ICLabel) | Default network; dynamic class thresholds; recognized scalp positions required. |
| ASR | [EEGLAB clean_rawdata documentation](https://eeglab.org/plugins/clean_rawdata/); [reference ASR source](https://github.com/sccn/clean_rawdata/blob/master/readme-asr.txt) | Native calibration/reconstruction/window rejection; Studio uses its own channel detector and 1 Hz fitting copy. |
| Riemannian ASR | Blum et al. (2019), [doi:10.3389/fnhum.2019.00141](https://doi.org/10.3389/fnhum.2019.00141) | EEGLAB Riemannian port; 30-second Studio processing blocks. |
| BSS-CCA | De Clercq et al. (2006), [doi:10.1109/TBME.2006.879459](https://doi.org/10.1109/TBME.2006.879459); [mne-denoise method](https://mne.tools/mne-denoise/dev/bss_cca.html) | Lagged-signal CCA; configurable component count or correlation threshold. |
| iCanClean | Downey & Ferris, [arXiv:2201.11798](https://arxiv.org/abs/2201.11798); [reference estimator](https://mne.tools/mne-denoise/stable/generated/mne_denoise.icanclean.ICanClean.html) | Pseudo-reference from a zero-phase fourth-order Butterworth band-stop filter. |
| wICA | Gabard-Durnam et al. (2018), [doi:10.3389/fnins.2018.00097](https://doi.org/10.3389/fnins.2018.00097); [HAPPE source](https://github.com/lcnhappe/happe) | Extended runica, coif5 SWT, ddencmp soft threshold; default 5 levels. |
| GEDAI | [GEDAI author implementation](https://github.com/Marco-Congedo/Gedai); [method tutorial](https://neuroimage.usc.edu/brainstorm/Tutorials/Gedai) | CCS port with standard leadfield covariance; explicitly warns on identity fallback. |
| Amplitude-envelope DFA | Hardstone et al. (2012), [doi:10.3389/fphys.2012.00450](https://doi.org/10.3389/fphys.2012.00450) | Band-specific fit scales; insufficient samples yield missing values. |
| fE:I | Bruining et al. (2020), [doi:10.1038/s41598-020-65500-4](https://doi.org/10.1038/s41598-020-65500-4) | Native CCS Python-method port; short-window adaptations are identified in the guide. |
| FOOOF / spectral parameterization | Donoghue et al. (2020), [doi:10.1038/s41593-020-00744-x](https://doi.org/10.1038/s41593-020-00744-x) | Native fit, configurable peaks; 1–40 Hz fitting range. |
| IRASA | Wen & Liu (2016), [original article](https://pmc.ncbi.nlm.nih.gov/articles/PMC4706469/) | Native resampling/spectral separation; configurable factors, 1–40 Hz fit range. |
| Connectivity / GC / GC-TR | [MNE-Connectivity spectral connectivity API](https://mne.tools/mne-connectivity/stable/generated/mne_connectivity.spectral_connectivity_epochs.html) | Morlet grid 4–40 Hz; native GC/GC-TR fits and their separately named difference. |

The [method and validation guide](docs/methods_and_validation.md) distinguishes
paper references, source ports, upstream numerical checks and release regression
tests. A numerical match on selected fixtures is not a claim of universal artifact
removal accuracy. Adaptive/embedding/mode-based ASR limits are documented there.

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Ctrl+O` | Open a recording file |
| `Ctrl+E` | Start extraction with current settings |
| `Ctrl+S` | Save / export results CSV |
| `Ctrl+,` | Open settings / configuration panel |
| `Escape` | Cancel running extraction |

---

## 🚀 Running & Building Locally

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel)
* [Rust Toolchain](https://www.rust-lang.org/tools/install) (`cargo` and `rustc`)
* For Windows installer: [Inno Setup](https://jrsoftware.org/isinfo.php) (`iscc` compiler)

### 1. Build the Rust Engine
Compile the native `ccs-eeg-engine` binary:
```sh
cd bridge
cargo build --release
cd ..
```

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

### 3. Package Production Release
```sh
# macOS (.app bundle)
./scripts/build_macos.sh

# Windows (.exe Installer via Inno Setup)
flutter build windows --release
copy bridge\target\release\ccs-eeg-engine.exe build\windows\x64\runner\Release\
iscc windows\installer.iss

# Linux Debian/Ubuntu (.deb)
flutter build linux --release
cp bridge/target/release/ccs-eeg-engine build/linux/x64/release/bundle/
bash scripts/package_linux_deb.sh build/linux/x64/release/bundle dist/CCSEEGStudio-linux-amd64.deb

# Linux RHEL/AlmaLinux (.rpm)
flutter build linux --release
cp bridge/target/release/ccs-eeg-engine build/linux/x64/release/bundle/
bash scripts/package_linux_rpm.sh build/linux/x64/release/bundle dist/CCSEEGStudio-linux-x86_64.rpm
```

### macOS Gatekeeper
If macOS blocks an ad-hoc-signed build after extraction, run:
```sh
xattr -rd com.apple.quarantine ~/Downloads/CCS\ EEG\ Studio.app
```

---

## 🧪 Running Tests

```sh
# Rust Engine Tests
cd bridge && cargo test && cd ..

# Flutter Analyzer & Tests
flutter analyze
flutter test

# Python vs Rust Parity Tests
bash scripts/run_parity_test.sh /path/to/recording.set /path/to/reference_output.csv
```

---

## 🤝 Research Collaboration & Acknowledgments

**CCS EEG Studio** is developed as a joint research and neurotechnology engineering collaboration by:

* **Centre for Consciousness Studies (CCS)**  
  *Department of Neurophysiology*,  
  **National Institute of Mental Health and Neurosciences (NIMHANS)**, Bengaluru, India.  
  *Pioneering neurophysiology research into consciousness, cognitive states, meditation, and computational EEG analytics.*

* **Axxonet** ([https://axxonet.com/](https://axxonet.com/))  
  *Pioneering medical technology, EEG & neurophysiology instrumentation, and cognitive research solutions.*

---

## 🔗 Related Repositories

| Repository | Description |
| :--- | :--- |
| [CCS Sleep Studio](https://github.com/arunsasidharan84/CCS_SleepStudio) | Sleep EEG visualization, manual staging, 9 automated AI models, and AnalyseNidra quantitative reports |
| [CCS Mobile Studio](https://github.com/arunsasidharan84/CCS_MobileStudio) | Mobile/desktop neurophysiology acquisition, stimulation, ANGEL ERP, and cognitive experiments |
| [CCS PPG Studio](https://github.com/arunsasidharan84/CCS_PPGStudio) | Clinical and research photoplethysmography analytics, gapless quality ribbon, and HRV dynamics |

---

## 📄 License

Proprietary — Centre for Consciousness Studies, NIMHANS, Bengaluru, India. All rights reserved.
