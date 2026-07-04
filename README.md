# CCS EEG Feature Studio

Lightweight Flutter + Rust desktop application for extracting epoch-wise EEG
features from EDF and EEGLAB SET/FDT recordings. The UI and loaders are ported
from ScoringNidra, while the workflow follows
`extract_EEGfeatures_connectivity_20250902_Ver10.0.py`.

## Implemented

- EDF and MATLAB v5 EEGLAB SET loading, including external float32 FDT data.
- Decimated multi-channel preview (up to 12 visible channels).
- Full, interval, fixed-bin, and middle-two-minute duration modes.
- Optional removal of common non-EEG channels and common-average reference.
- Rust/Rayon background extraction and combined CSV export.
- Seven Python-compatible frequency bands and feature column names.
- Relative Welch/Hamming PSD, eight nonlinear metrics, and ACW.
- Native FOOOF and IRASA ported from analyseNidra.
- MIC, MIM, GC, GC-TR, coherence, PLV, ciPLV, PLI, and wPLI.

## Scientific parity status

The Rust spectral implementation is ported from analyseNidra and tested against
`ccstools.eegfeatures`. On the deterministic fixture, IRASA band-power errors are
below `3e-12`, FOOOF band-power errors below `8e-9`, and fitted parameter errors
below `1e-4` across 250 Hz and 1000 Hz fixtures.

Connectivity is tested against `mne-connectivity 0.8` using the same Morlet
frequencies, cycles, grouping, epoch reduction, and 25-lag GC configuration as
the Python extractor. Maximum frequency-bin errors are below `2e-15` for MIC,
MIM, coherence, PLV, ciPLV, PLI, and wPLI; below `2e-12` for GC and GC-TR.

## Build and run

```sh
cd bridge
cargo build --release
cd ..
flutter pub get
flutter run -d macos
```

For a packaged macOS build:

```sh
./scripts/build_macos.sh
```

The script places `ccs-eeg-engine` beside the Flutter executable inside the app
bundle. Equivalent Windows/Linux packaging should copy the release engine beside
the Flutter executable.

## Tests

```sh
cd bridge && cargo test
cd .. && flutter analyze && flutter test
CCS_EEG_SAMPLE_DATA=/path/to/sampleData flutter test test/sample_loader_test.dart
```

The repository sample data was verified with both
`EEG_RestEyesClosed.edf` and `AKNLTP014_REMED1_RCB.set/.fdt`.
