# Changelog

All notable CCS EEG Studio changes are documented here. Version headings are
also the source for GitHub Release notes, so a tagged release is rejected when
its matching section is missing.

## [Unreleased]

## [1.2.17]

### Recording performance and processing feedback

- Move recording decoding and full-resolution display filtering off the Flutter UI isolate. Use typed buffers, reduce BrainVision/portable temporary copies, and pass existing portable files directly to native processing when possible.
- Show immediate loading feedback, progress activity and a visible Stop action. Stage native outputs before replacing a saved recording, and prevent restart races while cancellation completes.
- Report ICA iteration activity, reuse Infomax activation buffers and enable native thin LTO. Solver learning rules and convergence settings remain unchanged; Windows speed improvements have not yet been benchmarked.

### Recording formats and unambiguous filenames

- Add a persistent saved-recording format setting shared by preprocessing, crop/subepoch, source outputs and event epoching: **EDF+**, **FIF**, or **CCSEEG**. EDF+ is the default for fresh settings; an explicitly saved preference is retained.
- Write real binary EDF+ with per-channel 16-bit amplitude scaling and native float32 FIF for continuous and epoched recordings. Native CCSEEG retains its portable JSON contents under a dedicated `.ccseeg` extension; renaming is not compression.
- Store EDF/FIF application metadata in matching `.ccsmeta` companions. Preserve exact sample counts, padding information, original event timing, trial boundaries/labels, epoch zero, protocols and processing history. Keep the companion with its signal file. Fractional EDF rates use rational record durations; unsupported rates fail explicitly instead of changing the sample clock.
- Use distinct JSON-content extensions for reusable ERP protocols (`.ccsprotocol`), reopenable ERP results (`.ccserp`), native processing history (`.ccshistory`), legacy preparation history (`.ccspreparation`), and feature-analysis metadata (`.ccsanalysis`). Internal engine job files remain JSON.
- Accept legacy signal JSON, `.ccseeg.json`, protocol JSON, ERP-result JSON and old history companions. Hide non-recording metadata from signal pickers and strip repeated known signal extensions from new output names.
- Add **Settings → Organise legacy output filenames**: preview recognised renames, refuse collisions, update exact companion source-path references and retain a `.ccsmigration` manifest. Migration does not re-encode signal samples or rename raw vendor inputs. A dry-run/apply command-line tool is also included.

### Intuitive epoching and behavioral inclusion

- Replace independent output-epoch checkboxes with one **Saved data structure** choice: Continuous recording, Event-based trials (ERP), or Fixed-length windows. Event windows and fixed-window overlap settings remain separate.
- Increase waveform marker-line contrast while retaining event labels in their own lane.
- Group preprocessing parameters into collapsible Filter/notch, Bad channels/interpolation, GEDAI, Reference, ICA/ICLabel and ASR/muscle sections. Existing method icons open the corresponding section; ICA has its own parameter action.
- Persist response inclusion rules in reusable epoch/ERP protocols: all trials, correct-only, incorrect-only, or missed-only. Support explicit correct/incorrect feedback codes and stimulus-specific expected-button mappings such as `S20 = R1`, `S30 = R2`.
- Use the first recognised response inside the configured time window, stopping at the next selected stimulus. Unknown response codes are ignored; missing mappings are not guessed.

### Boundary-aware ICA and event timing

- Permit ICA to fit a shared decomposition across epoched data while retaining trial count, sample count, labels and event timing. High-pass filtering, blink detection and blink-training selections respect trial boundaries.
- Pool ICA training-copy ASR calibration statistics from within-trial covariance/RMS windows and reset ASR processing state at each trial. Rejected training samples do not shorten saved ERP trials. Insufficient calibration data are reported, with unrejected training data retained.
- For continuous input, run ICA/ASR before event extraction. Reject-ASR is refused with event extraction because deleting samples would invalidate event positions; Correct-ASR preserves time. Standalone ASR and standalone muscle cleaners remain continuous-input operations.
- Preserve original epoch protocols and parent processing provenance when cropping, subepoching, exporting and reopening saved recordings.
- Add selectable ERP electrode panel grids and clearer 0-ms / 0-µV references; retain native condition A/B channel waveforms and participant-weighted interactive review.

### Verification and practical limits

- Local Flutter regression suite: **201 passed, 6 skipped**. Static analysis and macOS release compilation passed. Native checks cover saved-trial ERP parity, epoched ICA, blink-window boundaries, and time-zero alignment after 1000→250 and 256→250 Hz resampling with filtering on/off.
- Independent MNE reads validate EDF/FIF signals, channel labels, annotations, epoch anchors and EDF quantization bounds. Export itself does not require Python or MNE.
- Read-only Pallavi audit: 1,156,520 raw samples at 1000 Hz map to 289,130 saved samples at 250 Hz; five local checks found zero sample lag. All 483 saved Pz epochs match their cleaned continuous-source slices after baseline adjustment. Oscillatory morphology is also present in independently filtered raw-data averages; this does not certify an artifact-free ERP or determine unknown behavioral marker meanings.
- The epoched ASR training-copy adapter is an application extension, not a claim of full clean_rawdata parity on epoched inputs. Existing outputs already misaligned by releases before 1.2.16 still require regeneration from the original data; filename migration cannot repair sample timing.
- macOS packages are ad-hoc signed. Platform installers and `SHA256SUMS.txt` are supplied by the desktop release workflow for the in-app updater.

### Guides and method references

- [Recording formats, performance checks and independent format validation](https://github.com/arunsasidharan84/CCS_EEGStudio/blob/v1.2.17/docs/pallavi_performance_and_files.md)
- [Pallavi ERP timing review, boundary-aware ICA, response rules and filename migration](https://github.com/arunsasidharan84/CCS_EEGStudio/blob/v1.2.17/docs/pallavi_erp_review.md)
- [ERP methods, references, parity and recovery guidance](https://github.com/arunsasidharan84/CCS_EEGStudio/blob/v1.2.17/docs/erp_workbench.md)
- [EEGLAB ICA workflow](https://eeglab.org/tutorials/06_RejectArtifacts/RunICA.html), [EEGLAB filtering guidance](https://eeglab.org/tutorials/05_Preprocess/Filtering.html), [EDF specifications](https://www.edfplus.info/specs/edf.html), [EDF+ specifications](https://www.edfplus.info/specs/edfplus.html)

## [1.2.16]

### Critical resampling/event-alignment correction

- Fixed rational resampling ratios in preprocessing: 256→250 Hz previously used 244/250 while labelling output as 250 Hz, shifting samples relative to unchanged event times. The corrected ratio is 125/128. Rates are formed at millihertz precision and the actual generated sample rate is retained.
- Fixed saved-trial sample counts to use the resampler's actual ceiling length rather than rounding, preventing boundaries from slipping across resampled trials.
- Added late-impulse alignment and independent-trial resampling regression tests. Reconstructed the supplied ERN stage by stage: the earlier sign reversal appears at downsampling alone; corrected downsampling preserves the negative response. Previously affected epoched files must be regenerated from the original input; changing labels or display polarity cannot repair them.
- Made `erp_trial_measurements.csv` an optional advanced export, disabled by default. `erp_measurements.csv` remains the conventional participant/condition-average measurement export. Existing files are retained.

### ERP reconstruction and validation

For the supplied already-cleaned ERN recording, using identical correct/error classes (319/82 trials), FCz, baseline −400…−200 ms and measurement window 0…100 ms:

| Processing route | Incorrect − Correct mean |
|---|---:|
| Epoch-only, original 256 Hz signal | −9.68 µV |
| Old 256→250 Hz resampling, no filter or cleaner | +12.16 µV |
| Corrected 256→250 Hz resampling, no filter or cleaner | −9.65 µV |
| Corrected resampling + filtering | −10.47 µV |
| Corrected complete GEDAI/interpolation configuration | −5.50 µV |

The sign reversal was caused by sample/event misalignment, not display orientation or swapping condition labels. GEDAI still attenuates the response on this already-cleaned input; epoch-only avoids additional processing. Existing outputs are retained for audit and must be regenerated where affected.

- Regression validation: **178 Flutter tests passed, 5 skipped**; **26 affected native tests passed**, including late-event alignment, per-trial output length, all-seven ERP reuse, optional CSV output, preprocessing and ICA/ASR tests.
- Independent MNE/SciPy reconstruction validates the corrected real-data resampling ratio and condition waveforms. Diagnostic scripts and output descriptions are in [the ERP guide](docs/erp_workbench.md#resampling-correction-and-existing-results).
- Version metadata is aligned across the app, engine and installer. The release supplies macOS, Windows, Debian and RPM update packages with checksums.

### Which ERP export to use

- **Conventional ERP:** `erp_measurements.csv` measures the participant/recording condition averages and their difference. Use the interactive review's participant-level CSV for chosen windows, parameters and cohort labels.
- **Optional trial-level work:** enable **Advanced analyses → Export individual-trial measurements** for `erp_trial_measurements.csv`. Rows contain per-event ROI measurements, not averaged ERPs and not complete trial waveforms. Trial-level models need participant-aware inference. Averaging trial peaks does not equal measuring the peak of the average ERP.
- The checkbox is off by default and saved in reusable analysis protocols. Disabling it does not delete previously exported trial files.

## [1.2.15]

### ERP waveform review and measurement export

- Added interactive batch review with searchable participant selection, individual recording/participant views, difference overlays, cohort labels and equal-participant grand averages with ±1 SEM for A/B and paired differences.
- Added optional display smoothing without changing exported measurements, live measurement-window controls and full-resolution channel difference outputs for exact scalp-map updates.
- Added selectable participant-level CSV metrics and a handoff to group statistics with cohort labels and reviewed window metadata.
- Made subtraction direction and display polarity explicit; added an epoch-only route for already-cleaned data.
- Restored continuous portable ERP event loading from preprocessing sidecars only when original timing was preserved.

### Connected ERP preparation and reusable protocols

- Connected waveform event epoching and preprocessing through shared event/group, baseline and timing settings; direct epoching now saves a real portable trial file before opening ERP analysis.
- Added reusable epoching/averaging protocol JSON import/export in interactive preprocessing, ERP analysis and the ERP Batch Workspace; compatible sidecars restore epoch settings on reopen.
- Distinguished new `-epo` and `-epo_clean` outputs, retained original event onsets and cleaning history, and prevented repeated derived-name suffixes.
- Preserved processed recordings when switching to raw; added an explicit saved-trial handoff, averaging action, contextual tooltips and trial-fitted waveform displays.

### Unified batch profiles and saved-trial ERP workflow

- Consolidated multi-recording entry points in Batch Workspace with EEG, ERP and Microstates profiles; removed the competing guided/legacy ERP selector and Microstates batch toggle from interactive analysis.
- Interactive ERP automatically loads the active prepared trial file and compares saved condition groups. Existing epoch boundaries/onsets are reused, and task-specific guides cover all seven ERP CORE components.
- Extended the native ERP engine to saved epochs, preserving trial layout rather than cutting around markers again. Behavioral response selection is not silently repeated on prepared trials; continuous FIR deconvolution is omitted for saved epochs.
- Added optional task-comparison reconstruction from original saved locking codes, allowing a different factor to be compared without re-epoching. The supplied ERN file's Congruent/Incongruent labels can thus produce the correct/error comparison (319/82 trials).
- Recognized ERP CORE `(uncorr) HEOG/VEOG` labels as auxiliary eye channels, preventing them from entering GEDAI montage lookup on future preprocessing runs. Existing outputs are not rewritten.
- Added all-seven-task saved-trial regression coverage and an independent NumPy waveform check for the user's prepared ERN recording.


### Event epoching and waveform navigation

- Compacted the waveform toolbar, collapsed full controls by default, reduced overview height and sized event lanes to occupied rows. Added independent panel toggles and a waveform focus/restore button; panel choices and navigation time survive collapsing.

- Added named event groups in preprocessing and the direct Epoch Events dialog: combine codes under editable condition labels while preserving original annotations and source times.
- Moved regex matching into an advanced section, removed implicit MMN marker defaults and synchronized shared panel controls. Direct epoching now matches normalized codes exactly (12 does not select 112).
- Added a clickable/draggable whole-recording amplitude/event overview with time ticks and viewport highlighting, plus separate collision-free event label lanes and full-label/time tooltips.
- Moved event/fixed-window choices before cleaning controls. Event trials suppress fixed-window epoching and its overlap; GEDAI's internal processing window is shown only where applicable. Added a preflight prompt for unmatched event selections.

### Guided ERP workbench

- Added single-recording and batch ERP workflows with recursive folder discovery, cleaned/raw duplicate preference, participant pilot limits and reviewable file lists.
- Added editable ERP CORE presets for MMN, N170, N2pc, N400, P3, LRP and ERN, searchable marker assignment, custom component definitions and saved per-task settings for mixed batches.
- Preserved supplied seconds-based event sidecars; audited source timing against EDF Status events and exposed sidecar markers in the raw viewer.
- Added native Rust peak, mean, signed/positive/negative AUC, fractional-area latency and fractional-peak onset measurements, with participant/condition and event-indexed trial exports.
- Added native multichannel rERP, sparse continuous FIR overlap correction with solver diagnostics, and training-fold-only shrinkage LDA with purged blocked CV and optional temporal generalization. The FIR implementation is a linear Unfold-style subset, not the entire toolbox.
- Added participant-level paired tests/FDR, channel and channel×time max-|t| FWER inference, paired normalized-map TANOVA-style testing, GFP exports and rERP class-beta inference. Single-participant outputs remain descriptive.
- Added channel/predictor model inspection, corrected-map masking, reopenable results, metadata/group-model handoff, compact PDF reports and tidy waveform/model CSVs. Optional-model failures retain conventional ERP results.
- Validated all seven paradigms in 14 cleaned ERP CORE recordings against an independent MNE/NumPy reconstruction; checked numerical kernels and real-data OLS/FIR coefficients against NumPy/SciPy. See `docs/erp_workbench.md` for exact methods, scope and references.


### Source, temporal information connectivity and graph summaries

- Corrected the former eLORETA label to the actual minimum-norm method; added MNE, dSPM, sLORETA and LCMV operators under the documented fixed-orientation assumptions.
- Added imported JSON/gzip forward-plus-atlas models and a coordinate-aware atlas conversion tool. HCPex is supported through a compatible user-provided mixed/volumetric forward and atlas; HCPex data and Rust BEM/FEM solvers are not bundled.
- Added Gaussian-copula MI and lagged-time conditional-information TE within each epoch, with configurable temporal embeddings. This is time-sample directed connectivity, not across-trial TE.
- Added configurable connectivity pair/graph-summary output choices and graph metrics. Estimator conventions, rank/tie behavior, graph definitions and attribution are documented in `docs/source_information_graph.md`; full toolbox parity is not claimed.

### Event-preserving feature plots and robustness

- Feature CSVs carry time-aligned `event_markers` JSON through retained preprocessing timelines and overlapping subepochs. Feature plots deduplicate repeated annotations and display onset labels and duration spans.
- Updated report/topography and group-statistics handling alongside the expanded analysis settings. Existing feature CSVs require re-extraction to obtain event annotations.

### Upgrade and workflow notes

- Use **Updates** in the toolbar for the platform package, or download the macOS ZIP, Windows installer, Debian package or RPM below. Versioned packages include SHA-256 checksums.
- All multi-recording EEG, ERP and Microstates entry points are under **Batch Workspace**; interactive ERP uses the active saved trials.
- For already-cleaned recordings, choose **Epoch only** to retain the supplied signal rather than applying the cleaners again. Original and derived recordings remain available when switching.
- Smoothing is display-only. Grand averages give participants equal weight after averaging their repeated recordings; uncertainty shadows are ±1 SEM across participants and are omitted for a single participant.
- Use **Interactive batch review → Label groups → CSV parameters → Export CSV / Group statistics**. CSV rows contain participant/condition measurements, cohort labels, ROI/window metadata and selected metrics. Live measurement-window changes do not silently recalculate inferential p-values.
- New results retain full-resolution channel differences for live scalp maps. Re-average older results for arbitrary-window topographies. Previously generated data are not overwritten by installing this update.
- macOS packages are ad-hoc signed, as in prior releases; initial launch may require the documented Gatekeeper steps. The macOS artifact targets the CI runner architecture, currently Apple Silicon.

### Validation, methods and limitations

- Local validation: **178 Flutter tests passed, 5 skipped**; **12 native ERP parity/regression tests passed**. Static analysis was clean and the macOS release bundle compiled and passed signature verification.
- Independent MNE/NumPy reconstruction matched the supplied cleaned EDF's 319 Correct / 82 Incorrect ERN waveforms with **0 µV discrepancy**. Independent NumPy reconstruction of the saved processed epochs also matched with **0 µV discrepancy**. An epoch-only preservation test matched the original cleaned EDF within 0.00001 µV.
- A prior 14-recording ERP CORE pilot covered all seven components; native numerical fixtures exercise measurements, regression, FIR solving, decoding and permutation logic. Source/information-connectivity fixtures check their documented supported formulas/subsets. Tests do not establish full parity with every upstream toolbox option or universal scientific validity for every dataset.
- Full workflow, measurement definitions, numerical checks and method references: [ERP workbench](docs/erp_workbench.md), [source/information/graph methods](docs/source_information_graph.md), [feature event timing](docs/feature_event_markers.md), and the [README method references](README.md#-method-references).

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

### Event-aligned feature plots (unreleased)
- Export raw annotations as structured `event_markers` metadata with exact source onsets and durations.
- Preserve duration annotations through overlapping subepochs, including annotations starting before a window.
- Draw deduplicated onset labels and shaded annotation intervals on feature line plots; exclude marker metadata from numeric outcomes.

### Source models and connectivity graphs (unreleased)
- Correct the former eLORETA label to MNE; add fixed-orientation dSPM, sLORETA, and unit-gain LCMV inverse choices.
- Import validated custom forward/atlas models; provide an explicit MNI-grid mapping utility for supplied HCPex or other volumetric atlases. No cortical-only model is presented as a complete HCPex reconstruction.
- Add native univariate GCMI and within-epoch temporal Gaussian-copula TE with configurable lag/history embedding, finite-sample bias correction and pinned Frites CMI numerical fixtures. Overlapping windows are supported; no across-trial estimator is exposed.
- Export raw node pairs, graph summaries, or both for GCMI, TE, coherence, PLV, ciPLV, PLI, and wPLI; support electrode and ROI inputs.
- Add positive-density thresholding, in/out strength, degree, weighted clustering, nodal/global efficiency, and realized density; document directed and symmetric-graph conventions.
- Recognize graph outcomes in group statistics, stop source processing on invalid model imports, and document supported mathematical parity separately from unimplemented full-toolbox options.
