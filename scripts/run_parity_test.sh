#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$DIR/.."
ENGINE="$ROOT/bridge/target/release/ccs-eeg-engine"
if [ ! -f "$ENGINE" ]; then
    echo "Building ccs-eeg-engine..."
    cd "$ROOT/bridge" && cargo build --release
fi

SAMPLE_SET="/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/AKNLTP014_REMED1_RCB.set"
OUTPUT_DIR="$ROOT/parity_test"
mkdir -p "$OUTPUT_DIR"

if [ ! -f "$OUTPUT_DIR/AKNLTP014_REMED1_RCB_python_parity.csv" ]; then
    echo "Running Python extraction..."
    python3 "$DIR/python_extract_headlessly.py" --input "$SAMPLE_SET" --outdir "$OUTPUT_DIR"
else
    echo "Python extraction already exists, skipping."
fi

echo "Generating Rust engine job..."
INSPECT_JSON="$OUTPUT_DIR/inspect.json"
JOB_JSON="$OUTPUT_DIR/job.json"

cat <<EOF > "$JOB_JSON"
{
  "job_type": "inspect_set",
  "input": "$SAMPLE_SET",
  "output": "",
  "format": "set",
  "epoch_seconds": 2.0,
  "options": {
    "mode": "full",
    "start_seconds": 0.0,
    "end_seconds": 0.0,
    "bin_seconds": 0.0,
    "psd": true,
    "fooof": true,
    "irasa": true,
    "nonlinear": true,
    "acw": true,
    "connectivity": true,
    "coh": true,
    "plv": true,
    "ciplv": true,
    "pli": true,
    "wpli": true,
    "remove_non_eeg": true
  }
}
EOF

"$ENGINE" "$JOB_JSON" > "$INSPECT_JSON"

python3 -c "
import json
with open('$INSPECT_JSON', 'r') as f:
    meta = json.load(f)
with open('$JOB_JSON', 'r') as f:
    job = json.load(f)

job['job_type'] = 'extract'
job['output'] = '$OUTPUT_DIR/AKNLTP014_REMED1_RCB_rust_parity.csv'
job['data_path'] = '$SAMPLE_SET'.replace('.set', '.fdt')
job['sample_rate'] = meta['sample_rate']
job['labels'] = meta['labels']
job['sample_count'] = meta['sample_count']

if 'epoch_count' in job:
    del job['epoch_count']
if 'points_per_epoch' in job:
    del job['points_per_epoch']

with open('$JOB_JSON', 'w') as f:
    json.dump(job, f, indent=2)
"

echo "Running Rust extraction..."
"$ENGINE" "$JOB_JSON"

echo "Parity testing complete."
