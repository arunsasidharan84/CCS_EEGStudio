import numpy as np
import json
from ccstools.ccs_eeg.gedai.gedai_algo import gedai_per_band, clean_eeg
from ccstools.ccs_eeg.gedai.utils import load_leadfield, get_leadfield_cov
import scipy.linalg

py_data = np.load('parity_test/py_filter.npy')
with open('parity_test/py_filter_labels.json') as f:
    py_labels = json.load(f)

L = load_leadfield('/Users/arunsasidharan/miniconda3/lib/python3.12/site-packages/ccstools/ccs_eeg/resources/fsavLEADFIELD_4_GEDAI.mat')
ref_cov = get_leadfield_cov(L, py_labels)

epoch_samples = int(250 * 1.0)
n_epochs = py_data.shape[1] // epoch_samples
data = py_data[:, :n_epochs * epoch_samples]
epoched_1 = data.reshape(py_data.shape[0], epoch_samples, n_epochs, order='F')

cov_1 = np.zeros((n_epochs, py_data.shape[0], py_data.shape[0]))
for i in range(n_epochs):
    cov_1[i] = np.cov(epoched_1[:, :, i])

# Python GEVD
reg_lambda = 0.05
eig_ref = np.linalg.eigvalsh(ref_cov)
ref_cov_reg = (1 - reg_lambda) * ref_cov + reg_lambda * np.mean(eig_ref) * np.eye(py_data.shape[0])

v_py, e_py = scipy.linalg.eigh(cov_1[0], ref_cov_reg)
idx = np.argsort(v_py)[::-1]
v_py = v_py[idx]
e_py = e_py[:, idx]

# Rust GEVD logic
mean = np.mean(np.linalg.eigvalsh(ref_cov))
# Wait, rust does mean.max(1e-12)
mean = max(mean, 1e-12)
b = ref_cov * 0.95 + np.eye(py_data.shape[0]) * (0.05 * mean)
chol = np.linalg.cholesky(b) # L
l_inv = np.linalg.inv(chol)

z = l_inv @ cov_1[0] @ l_inv.T
z = (z + z.T) * 0.5
v_rust, q_rust = np.linalg.eigh(z)

# eigh returns ascending, sort descending
idx = np.argsort(v_rust)[::-1]
v_rust = v_rust[idx]
q_rust = q_rust[:, idx]

e_rust = l_inv.T @ q_rust

print("Max eigenvalue diff:", np.max(np.abs(v_py - v_rust)))
print("Max eigenvector diff:", np.max(np.abs(np.abs(e_py) - np.abs(e_rust))))

# Check threshold
_, _, _, broad_thresh_py = gedai_per_band(
    py_data, 250, 1.0, ref_cov, 'auto-', 'parabolic', False
)
print("Python auto- threshold:", broad_thresh_py)

