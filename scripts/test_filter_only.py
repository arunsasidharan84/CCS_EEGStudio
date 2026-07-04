import mne
import numpy as np
import json
from pathlib import Path
from ccstools.ccs_eeg.pipeline import run_ccs_pipeline

raw = mne.io.read_raw_edf('/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/EEG_MeditationEyesClosed.edf', preload=True)
montage = mne.channels.make_standard_montage('standard_1005')
raw.set_montage(montage, on_missing='warn', match_case=False)

cfg = {
    'steps': ['downsample', 'filter'],
    'downsample_freq': 250,
    'filter_bandpass': (0.5, 40),
    'notch_freqs': (50,),
}
clean_raw = run_ccs_pipeline(raw, output_dir=None, config=cfg)
np.save('parity_test/py_filter.npy', clean_raw.get_data() * 1e6)
with open('parity_test/py_filter_labels.json', 'w') as f:
    json.dump(clean_raw.ch_names, f)
