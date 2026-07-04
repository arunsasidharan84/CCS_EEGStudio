#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$DIR/.."
ENGINE="$ROOT/bridge/target/release/ccs-eeg-engine"

# We use the raw EDF file for preprocessing
SAMPLE_RAW="/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/EEG_MeditationEyesClosed.edf"
OUTPUT_DIR="$ROOT/parity_test/gedai"
mkdir -p "$OUTPUT_DIR"

echo "Running Python/MATLAB Preprocessing (GEDAI)..."
python3 "$DIR/python_preprocess_headlessly.py" --input "$SAMPLE_RAW" --outdir "$OUTPUT_DIR"

echo "Generating Rust Engine Preprocess Job..."
JOB_JSON="$OUTPUT_DIR/job_preprocess.json"
cat <<EOF > "$JOB_JSON"
{
  "job_type": "preprocess",
  "input": "$SAMPLE_RAW",
  "output": "$OUTPUT_DIR/rust_preprocessed.ccseeg.json",
  "format": "edf",
  "epoch_seconds": 1.0,
  "options": {
    "mode": "full",
    "start_seconds": 0.0,
    "end_seconds": 0.0,
    "bin_seconds": 0.0,
    "psd": false,
    "fooof": false,
    "irasa": false,
    "nonlinear": false,
    "acw": false,
    "connectivity": false,
    "remove_non_eeg": true
  },
  "preprocessing": {
    "downsample": true,
    "downsample_freq": 250.0,
    "filter": true,
    "low_hz": 0.5,
    "high_hz": 40.0,
    "notch_hz": 50.0,
    "badchannel": true,
    "gedai": true,
    "interpolate": true,
    "gedai_epoch_seconds": 1.0,
    "gedai_threshold": "auto"
  }
}
EOF

echo "Running Rust Preprocessing (GEDAI)..."
"$ENGINE" "$JOB_JSON"

echo "Comparing GEDAI Signals..."
python3 "$DIR/compare_gedai_signals.py" \
  --py_npy "$OUTPUT_DIR/python_gedai_data.npy" \
  --py_json "$OUTPUT_DIR/python_gedai_meta.json" \
  --rs_json "$OUTPUT_DIR/rust_preprocessed.ccseeg.json" \
  --outdir "/Users/arunsasidharan/.gemini/antigravity/brain/87c2a503-d862-42fd-a484-3f44ab50b721/snapshots/gedai"

echo "Preprocess testing complete!"
