import os
import sys
import argparse
from pathlib import Path
import mne

sys.path.append("/Users/arunsasidharan/Code/ActiveProjects/ccs_toolbox")
from ccstools.ccs_eeg.pipeline import run_ccs_pipeline

def preprocess(filepath, output_dir):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    print(f"Loading {filepath} for preprocessing...")
    if filepath.endswith('.edf'):
        raw = mne.io.read_raw_edf(filepath, preload=True)
    else:
        raw = mne.io.read_raw_eeglab(filepath, preload=True, verbose=False)
        
    montage = mne.channels.make_standard_montage('standard_1005')
    raw.set_montage(montage, on_missing='warn', match_case=False)
    
    cfg = {
        'steps': ['downsample', 'filter', 'badchannel', 'gedai', 'interpolate', 'save'],
        'downsample_freq': 250,
        'filter_bandpass': (0.5, 40),
        'notch_freqs': (50,),
    }
    
    print("Running ccstools pipeline with GEDAI...")
    clean_raw = run_ccs_pipeline(raw, output_dir=str(output_dir), config=cfg)
    
    # Save the output to a standard numpy/JSON format so we can compare it easily
    out_npy = output_dir / "python_gedai_data.npy"
    out_json = output_dir / "python_gedai_meta.json"
    
    import numpy as np
    import json
    
    data = clean_raw.get_data()
    np.save(out_npy, data)
    
    meta = {
        "labels": clean_raw.ch_names,
        "sample_rate": clean_raw.info['sfreq']
    }
    with open(out_json, "w") as f:
        json.dump(meta, f)
        
    print(f"Saved Python GEDAI output to {out_npy}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Input EDF/.set file")
    parser.add_argument("--outdir", required=True, help="Output directory")
    args = parser.parse_args()
    
    preprocess(args.input, args.outdir)
