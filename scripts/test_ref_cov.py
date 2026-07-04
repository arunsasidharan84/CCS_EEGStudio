import json
import numpy as np
from ccstools.ccs_eeg.gedai.utils import load_leadfield, get_leadfield_cov
from ccstools.ccs_eeg.pipeline import run_ccs_pipeline
import mne

L = load_leadfield('/Users/arunsasidharan/miniconda3/lib/python3.12/site-packages/ccstools/ccs_eeg/resources/fsavLEADFIELD_4_GEDAI.mat')

raw = mne.io.read_raw_edf('/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/EEG_MeditationEyesClosed.edf')
eeg_chans = [ch for ch in raw.ch_names if not any(bad in ch.upper() for bad in ['GSR', 'ECG', 'EOG', 'EMG', 'RESP', 'X_DIR', 'Y_DIR', 'Z_DIR', 'STATUS', 'MARK'])]

ref_cov_py = get_leadfield_cov(L, eeg_chans)

with open('bridge/resources/gedai_leadfield.json') as f:
    lf_rs = json.load(f)

lookup = {label.lower(): i for i, label in enumerate(lf_rs['labels'])}
idx = [lookup[ch.lower()] for ch in eeg_chans]

ref_cov_rs = np.array([[lf_rs['gram_matrix_avref'][r][c] for c in idx] for r in idx])

diff = ref_cov_py - ref_cov_rs
print(f"Max difference in covariance: {np.max(np.abs(diff))}")
