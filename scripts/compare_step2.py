import numpy as np, json
import mne
from ccstools.ccs_eeg.pipeline import run_ccs_pipeline

raw = mne.io.read_raw_edf('/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/EEG_MeditationEyesClosed.edf', preload=True)
montage = mne.channels.make_standard_montage('standard_1005')
raw.set_montage(montage, on_missing='warn', match_case=False)

cfg = {
    'steps': ['downsample', 'filter', 'badchannel', 'gedai'],
    'downsample_freq': 250,
    'filter_bandpass': (0.5, 40),
    'notch_freqs': (50,),
}
filtered_raw = run_ccs_pipeline(raw, output_dir='parity_test/step2', config=cfg)
py_gedai = filtered_raw.get_data() * 1e6

with open('parity_test/step2/rust_gedai.json') as f:
    ru_json = json.load(f)
ru_gedai = np.array(ru_json['channels'])

py_labels = filtered_raw.ch_names
ru_labels = ru_json['labels']

common = [ch for ch in py_labels if ch in ru_labels]
py_idx = [py_labels.index(ch) for ch in common]
ru_idx = [ru_labels.index(ch) for ch in common]

diff = py_gedai[py_idx] - ru_gedai[ru_idx]
print("GEDAI (no interp) RMS diff:", np.sqrt(np.mean(diff**2)))
print("GEDAI (no interp) Max diff:", np.max(np.abs(diff)))
