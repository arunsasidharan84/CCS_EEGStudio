# EEG workflow improvements

## Prepare recordings

Load Raw, Preprocess, and Feature Extraction expose **Crop / subepoch and save**.
Crop using annotation endpoints, annotation start plus duration, time endpoints,
or time start plus duration. Cropping runs before sliding windows. The result is
saved as a reusable `.ccseeg.json` recording with annotations and provenance.
Native formats whose previews were decimated are exported at full resolution
through the Rust engine before preparation; mixed-rate channels require selection
or resampling rather than silent truncation.

Existing trials support either within-trial cropping or complete-epoch selection
on the stitched display timeline. Event-relative bounds are shown when available.
Subepochs never cross parent trial boundaries. Overlap is in seconds and must be
smaller than the window. Incomplete windows are dropped. Sample rounding determines
the exact hop. Saved epoch start coordinates and CSV start/end columns preserve
overlap timing. Time bins group overlapping windows by their centre; interval
selection keeps complete windows. Overlapping windows are not independent samples.

## References and parameters

Settings icons expose preprocessing and extraction parameters. Output referencing
supports retaining the cleaned reference, common average, or selected reference
channels. GEDAI retains its internal full-rank pseudo-average reference. Reference
channels must be available among EEG channels after auxiliary-channel removal.
Feature referencing is configured independently; choosing a new output reference
sets feature analysis to keep that input reference.

Parameters include centred Hamming FIR taps, forward/backward Butterworth order,
notch stop/transition widths, bad-channel variance ratio, spline stiffness and
regularization, GEDAI window/threshold, source SNR and atlas regions, Welch
mean/median estimation and window, frequency bands, FOOOF peak settings, IRASA
resampling factors, sample-entropy tolerance, Higuchi kmax, ACW crossing and GC lags.
FOOOF/IRASA use their 1-40 Hz fitting range. Connectivity uses its 4-40 Hz frequency
grid; lower bands are omitted. PSD can use higher bands up to Nyquist. Legacy
standard-band defaults retain their reference-compatible integration; custom
bands use trapezoidal integration. Relative power retains a 1-40 Hz normalization
range, extended for wider custom PSD bands.

Already epoched data hide continuous epoch-cutting controls. Existing parent
boundaries are respected. Reopened portable recordings recover preprocessing/source
completion from their saved provenance; legacy `_clean` recordings are recognized.
Adjacent feature CSVs and figure folders are recovered when available.

## Files and plots

File selection supports `*`, `?`, and semicolon-separated filename patterns. Folder
queues support the same filter. Plot sessions have earlier/later controls and a
hexadecimal line-color picker. Reordering changes display order without rerunning
permutation statistics or changing the selected baseline. Colors also apply to
exports. GC − GC-TR is available as a separately named contrast, computed from the
same forward and time-reversed GC fits. It is not labelled as net directional GC.

## Group statistics

The batch header and Full Pipeline include **Group Statistics**. Select feature CSV,
metadata CSV/XLSX, join key, subject ID, group, optional within-subject factor,
covariates and outcomes. The workbench adapts CCS_SleepStudio's local Python LMM/GLM
implementation. Original recording identity is retained when engine inputs are
temporary files. Metadata joins are validated as many-to-one; ambiguous or missing
matches stop analysis.

Epoch values are aggregated per recording/channel and meaningful epoch condition
before modeling. Recording-level multivariate connectivity does not become a separate
observation for every duplicated channel. LMM uses subject random intercepts;
GLM uses HC3 or subject-clustered covariance as applicable. Mixed-model failures do
not silently fall back to independent-observation OLS. Contrasts use model-adjusted
means/covariance. Selected-outcome correction covers post-hoc comparisons, with
omnibus and coefficient correction families recorded separately. Multiple subjects
and estimable designs are required; many epochs from one subject are not a group study.

The Python environment needs numpy, pandas, scipy, matplotlib and statsmodels.
XLSX imports additionally need openpyxl; Word/PDF reports use python-docx/reportlab.
An interpreter can be selected with `CCS_EEG_PYTHON`; otherwise standard installed
Python locations are checked. No external LLM service is used. Results include model
and contrast CSVs, plots, and reports when their optional dependencies are available.

## Provenance

Prepared recordings retain parent/window coordinates. Preprocessing writes a
`.preprocessing.json` sidecar containing source path, actual options, selection,
summary and mapped annotations. Extraction writes `.analysis.json` next to CSVs.
The vendored Rust backend exposes the new settings; source changes therefore require
rebuilding both the engine and Flutter app before distribution.
