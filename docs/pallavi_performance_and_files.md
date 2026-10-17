# Large recordings, ERP response rules and saved files

These changes are under development after v1.2.16; they are not in the published installer yet.

## Recording files versus settings

Open any processing **Settings** dialog (gear icon) and choose **Saved recording format (all workflows)**. The preference is saved across launches and applies to preprocessing/source outputs, direct event-epoch saves, crop/subepoch saves, and batch outputs.

| Setting | Signal file | Additional app metadata |
|---|---|---|
| CCSEEG | `recording.ccseeg` | Embedded JSON metadata/provenance |
| FIF | `recording.fif` | `recording.fif.ccsmeta` |
| EDF+ (fresh-settings default) | `recording.edf` | `recording.edf.ccsmeta` |

The `.ccsmeta` companions contain human-readable JSON with a dedicated extension. They store original channel/condition labels, markers and durations, parent epoch boundaries, original event anchors, exact sampling rate/sample count, completed stages and processing/epoch protocols. Keep each companion beside its signal file with the same basename. The loader checks the schema, file size and signal dimensions before applying it. Save replacement restores the preceding data file if replacing its companion fails.

Legacy `.ccseeg.json` and plain `.json` signal recordings remain supported. Recording pickers omit settings/protocol/results/metadata files. A legacy JSON signal must identify itself with `"format":"ccseeg-v1"` in the header. Originals are not renamed or deleted.

CCSEEG currently retains JSON samples; its extension change is not compression. FIF writes standard float32 signal buffers (raw or native epoched FIF), annotations, event classes and long channel names. EDF+ writes per-channel 16-bit scaled samples with annotations; epoched data is concatenated with labelled trial/boundary annotations and its exact structure restored from `.ccsmeta`. Quantization steps and end padding are recorded in the companion. Fractional sampling rates use exact rational record durations where representable; longer EDF records can add padding to short inputs, which the app trims on reopening. These are valid binary exports, not renamed JSON. FIF writing/EDF writing run in a worker and require no Python installation. Compressed FIF/GZIP export is not part of this setting.

FIF is a better interchange choice for rich analysis objects, epochs and floating-point signals; MNE also supports `.fif.gz`. EDF/EDF+ is widely supported, but standard signals use 16-bit integers with digital/physical scaling, and EDF does not store a full electrode montage or application protocol. Smaller EDF exports can therefore reflect quantization rather than compression. Full native protocols still need to be preserved separately when exchanging data.

References: [EDF specification](https://www.edfplus.info/specs/edf.html), [EDF+ annotations](https://www.edfplus.info/specs/edfplus.html), [MNE external export limitations](https://github.com/mne-tools/mne-python/blob/main/mne/export/_export.py), [MNE compressed FIF reading](https://mne.tools/stable/generated/mne.io.read_raw_fif.html).

## Loading and responsiveness

File decoding and full-recording display filtering run in worker isolates. BrainVision loading allocates typed channel buffers directly, avoiding growing double lists followed by another complete copy. Existing portable files go directly to the native engine instead of being serialized to another temporary JSON signal. In-memory signals are serialized in a worker. The Infomax activation buffer is reused across training blocks; convergence criteria, random draws and learning rules are unchanged. Native release builds use thin LTO and one code-generation unit across platforms.

On the development Mac, explicit read-only tests with the supplied files measured:

| Input | Full-resolution content | Import time |
|---|---|---:|
| Pallavi_Task_Pre_2.vhdr plus 278 MB EEG | 63 × 1,156,520 samples at 1,000 Hz | 1.65 s |
| P300_v01.json, approximately 267 MB | 61 × 241,983 samples at 250 Hz | 1.87 s |

The UI-isolate heartbeat continued during both loads. These measurements exclude display filtering and are not Windows benchmarks. The PPGStudio comparison informed moving work off the UI isolate; a 63-channel 1-kHz ICA workload is substantially different from a single PPG channel.

ICA repeatedly visits training samples and remains expensive at 1 kHz. The UI provides guidance to consider 250–500 Hz for conventional ERP work, subject to the needed frequencies. Downsampling is an explicit choice. Picard is another available ICA solver, not a promise of identical Infomax decompositions. No trials or channels are silently omitted to speed up fitting.

Progress appears immediately, uses an indeterminate bar before a numerical estimate exists, and includes native stage/ICA iteration messages. Stop terminates the active engine and keeps restart controls disabled until cleanup finishes. Native preprocessing writes into a temporary staging path; cancellation cannot replace a previously saved output with a partial engine file. Cancellation during a worker import discards the result when it finishes. Batch queues check cancellation after importing a file before starting its native job.

## Correct and incorrect responses in custom tasks

In Event-based trials, create named stimulus conditions, then open **Trial correctness / response rules**. For each condition, choose All trials, Correct responses only, or Incorrect responses only. Select correct and incorrect response/feedback markers and set the earliest/latest response delay in seconds. These are explicit experimental definitions, not inferred from numeric trigger values.

The first mapped response within the delay window is used; the next selected locking event ends the search. Missing/late responses are excluded from response-filtered groups. Rules apply before epoch extraction and are shared by direct event epoching and preprocessing, and saved in the reusable protocol. Existing already-epoched files must be regenerated from continuous data to change inclusion rules.

The supplied Pallavi protocol names Standard (S 10), Neutral (S 20), Pleasant (S 30), and Unpleasant (S 40). The raw inventory includes S 50 (83), S 60 (6), and S 70 (311), but their behavioral meaning is not defined in that protocol. No correctness mapping was guessed or applied to the original data.

## ERP electrode panels and zero references

Electrode panels provide selectable channels and a 1–4-column grid in the results and batch review. Each electrode has its own panel rather than being stacked on other channels. New native results include both condition-average waveforms per channel as well as their difference. For older results, only stored differences are available; re-running ERP averaging supplies A/B waveforms. Grand averages use equal participant weights, including repeated recordings, with participant SEM when possible. Display smoothing remains separate from measurements.

The event reference has a strong vertical line labelled **0 ms · event**; the voltage reference has a strong horizontal line labelled **0 µV**. Negative-up remains a display orientation and never changes the samples or condition subtraction.

## Validation

Final validation: 198 Flutter tests passed (6 skipped), 24 native library/ERP tests passed, static analysis clean, full-size Pallavi loading and display-worker checks passed, and the macOS release app compiled successfully. A separate ERP rerun in `output/pallavi_validation` reproduced 280 Standard / 40 Unpleasant trials and validated all 61 channel A/B/difference arrays. Originals were untouched. No GitHub release has been published for these changes.

Storage validation additionally exercises all three formats, persisted preferences, companion replacement rollback, fractional EDF rates and native ERP/preprocessing reuse. `tools/validate_recording_exports.py` independently reads the generated FIF/EDF+ files with MNE and checks voltages, events, epoch anchors, condition labels and full FIF channel names.

FIF interchange layout follows the public [MNE FIFF writer](https://github.com/mne-tools/mne-python/blob/main/mne/_fiff/write.py), [epoch writer](https://github.com/mne-tools/mne-python/blob/main/mne/epochs.py), and [annotation writer](https://github.com/mne-tools/mne-python/blob/main/mne/annotations.py). Signals remain float32 on disk, with standard SI units; the companion preserves app-specific semantics.
