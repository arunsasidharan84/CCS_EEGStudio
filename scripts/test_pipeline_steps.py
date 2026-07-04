import numpy as np
import json
import mne
from ccstools.ccs_eeg.pipeline import run_ccs_pipeline

raw = mne.io.read_raw_edf('/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/EEG_MeditationEyesClosed.edf', preload=True)
montage = mne.channels.make_standard_montage('standard_1005')
raw.set_montage(montage, on_missing='warn', match_case=False)

# Step 1: Filter
cfg = {
    'steps': ['downsample', 'filter'],
    'downsample_freq': 250,
    'filter_bandpass': (0.5, 40),
    'notch_freqs': (50,),
}
filtered_raw = run_ccs_pipeline(raw, output_dir='parity_test/step1', config=cfg)
py_filter = filtered_raw.get_data() * 1e6

with open('parity_test/gedai/rust_preprocessed.ccseeg.json') as f:
    ru_json = json.load(f)

# Wait, rust_preprocessed.ccseeg.json is AFTER GEDAI.
# Let's run rust engine with ONLY filter!
