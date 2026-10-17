# Pallavi ERP review and preprocessing controls

## Timing investigation

`tools/audit_pallavi_erp.py` independently reads the original BrainVision recording
with MNE and compares it with the saved ICA-cleaned recording. The originals are
read only; figures and numerical results go to `output/pallavi_timing_audit/`.

- Original: 1,156,520 samples at 1000 Hz. Saved: 289,130 samples at 250 Hz.
- Local cross-correlation at 30, 300, 600, 900 and 1100 seconds: zero-sample lag.
- All 483 saved Pz epochs match their continuous-source slices after baseline
  removal (minimum correlation 0.9999999999999988).
- Independently averaged trials reproduce the oscillatory morphology before ICA:
  Standard 280, Neutral 41, Pleasant 39, Unpleasant 40.
- The epoch file also contains 83 S50 events. These are not one of the four named
  conditions. Their behavioral meaning is not inferred from the numeric code.

These checks do **not** establish an artifact-free ERP or validate the experiment's
behavioral mappings. They provide evidence against a sample-clock drift or
saved-epoch misalignment in this recording. The independent filter-only and
ICA-cleaned averages are available together in `raw_vs_cleaned_erp.png`.
Synthetic tests also check impulse alignment at time zero after 1000→250 and
256→250 Hz resampling, with filtering both enabled and disabled.

## Preprocessing controls

- **Saved data structure** chooses continuous data, event-based trials, or fixed
  windows. These are mutually exclusive output structures. Fixed-window settings
  do not silently override ERP trial definitions.
- Marker lines have higher contrast; event labels remain in their separate lane.
- Preprocessing parameters are grouped into collapsible Filter/notch, Bad
  channels/interpolation, GEDAI, Reference, ICA/ICLabel, and ASR/muscle sections.
  The corresponding settings icons open the relevant section.
- For continuous input, ICA/ASR cleaning precedes event extraction. ASR reject is
  refused with event extraction because deleting samples would invalidate event
  positions; ASR correct preserves time.
- ICA can fit one shared decomposition across saved trials. High-pass filtering,
  blink detection and blink-training windows respect parent trial boundaries.
- Internal ASR training-copy calibration pools within-trial statistics; covariance
  blocks and RMS windows do not cross trials. ASR processing state resets for
  each trial. Only training samples can be removed; saved trial count, length,
  labels and event timing are retained. Insufficient calibration data are reported
  and the unrejected fit copy is retained.
- Standalone ASR and standalone muscle cleaners continue to require continuous
  data in this implementation. They are explicitly skipped on epoched input.

ICA on epoched data is supported by [EEGLAB's ICA workflow](https://eeglab.org/tutorials/06_RejectArtifacts/RunICA.html).
Filtering continuous data before epoch extraction remains preferable when the
continuous recording is available; [EEGLAB's filtering guidance](https://eeglab.org/tutorials/05_Preprocess/Filtering.html)
also describes independent filtering of existing epochs. The new boundary-aware
training-copy adapter is an application extension; it is not a claim of complete
clean_rawdata parity on epoched inputs.

## Response inclusion

Each condition can use explicit correct/incorrect feedback markers, or specify
expected button codes for individual stimulus markers. For example:

```
S20 = R1
S30 = R2
```

Select all recognised button codes in the correct/incorrect code lists as needed.
The expected mapping determines correctness for that stimulus; another recognised
button is incorrect. Unrecognised event codes are ignored. The first recognised
response within the time window is used, stopping at the next selected stimulus.
Correct-only, incorrect-only, missed-only and all-trial inclusion are available.
Rules persist in reusable ERP protocols.

## Output identities and legacy conversion

EDF+ is the default for fresh settings; an explicitly saved format preference is
retained. FIF and native CCSEEG remain selectable.

| Role | Current name | Legacy accepted |
| --- | --- | --- |
| Native signal | `recording.ccseeg` | `.ccseeg.json`, signal `.json` |
| EDF/FIF app metadata | `recording.edf.ccsmeta` / `recording.fif.ccsmeta` | Existing files remain readable |
| Native preprocessing history | `recording.ccseeg.ccshistory` | `.preprocessing.json` |
| Legacy preparation history | `.ccspreparation` | `.preparation.json` |
| Feature analysis metadata | `features.csv.ccsanalysis` | Existing `.analysis.json` files can be renamed |
| Reusable ERP protocol | `erp.ccsprotocol` | `.protocol.json`, protocol `.json` |
| Reopenable ERP result | `erp_results.ccserp` | `erp_results.json` |

These metadata/protocol/result extensions retain JSON contents. Their role is
visible before opening a file. New signal naming strips repeated known recording
extensions, preventing names such as `.ccseeg.ccseeg`.

**Settings → Organise legacy output filenames** previews recognised renames,
refuses collisions, updates exact source-path references in companion metadata,
and writes `legacy_names.ccsmigration`. No signal samples are re-encoded. Raw
BrainVision/EDF vendor input files and unknown JSON files are left alone. The
manifest records old and new paths for recovery. Reopen migrated files using their
new names. The same preview is available from:

```
python3 tools/migrate_legacy_outputs.py /path/to/output
```

Add `--apply` to perform the reviewed migration. Do not rename only one member of
a signal/metadata pair manually.
