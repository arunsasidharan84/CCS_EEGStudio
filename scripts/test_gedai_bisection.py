import numpy as np
import json
from ccstools.ccs_eeg.gedai.gedai_algo import gedai_per_band
from ccstools.ccs_eeg.gedai.utils import load_leadfield, get_leadfield_cov

py_data = np.load('parity_test/py_filter.npy')
with open('parity_test/py_filter_labels.json') as f:
    py_labels = json.load(f)

L = load_leadfield('/Users/arunsasidharan/miniconda3/lib/python3.12/site-packages/ccstools/ccs_eeg/resources/fsavLEADFIELD_4_GEDAI.mat')
ref_cov = get_leadfield_cov(L, py_labels)

# We just run one gedai_per_band (broadband) with threshold auto-
print("Running Python gedai_per_band on py_data...")
broadband_data_py, _, broad_sensai_py, broad_thresh_py = gedai_per_band(
    py_data, 250, 1.0, ref_cov, 'auto-', 'parabolic', False
)

print(f"Py Threshold: {broad_thresh_py}, Sensai: {broad_sensai_py}")
np.save('parity_test/py_broadband.npy', broadband_data_py)
