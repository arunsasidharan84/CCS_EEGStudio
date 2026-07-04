import numpy as np
import json
import mne
from ccstools.ccs_eeg.pipeline import run_ccs_pipeline
from ccstools.ccs_eeg.gedai.gedai_algo import gedai, gedai_per_band
from ccstools.ccs_eeg.gedai.utils import load_leadfield, get_leadfield_cov

raw = mne.io.read_raw_edf('/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/EEG_MeditationEyesClosed.edf', preload=True)
montage = mne.channels.make_standard_montage('standard_1005')
raw.set_montage(montage, on_missing='warn', match_case=False)

cfg = {
    'steps': ['downsample', 'filter'],
    'downsample_freq': 250,
    'filter_bandpass': (0.5, 40),
    'notch_freqs': (50,),
}
filtered_raw = run_ccs_pipeline(raw, output_dir=None, config=cfg)
data = filtered_raw.get_data() # in VOLTS

L = load_leadfield('/Users/arunsasidharan/miniconda3/lib/python3.12/site-packages/ccstools/ccs_eeg/resources/fsavLEADFIELD_4_GEDAI.mat')

res = gedai(data, 250, filtered_raw.ch_names, ref_matrix_type='precomputed', leadfield_path='/Users/arunsasidharan/miniconda3/lib/python3.12/site-packages/ccstools/ccs_eeg/resources/fsavLEADFIELD_4_GEDAI.mat')

print("Py gedai clean[:5] * 1e6:", res['clean_data'][0, :5] * 1e6)
print("Py thresholds:", res['thresholds'])

