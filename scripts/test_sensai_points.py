import numpy as np
import json
from ccstools.ccs_eeg.gedai.gedai_algo import sensai, clean_eeg
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

reg_lambda = 0.05
eig_ref = np.linalg.eigvalsh(ref_cov)
ref_cov_reg = (1 - reg_lambda) * ref_cov + reg_lambda * np.mean(eig_ref) * np.eye(py_data.shape[0])

def compute_gevd(cov_mat, ref_mat):
    vals, vecs = scipy.linalg.eigh(cov_mat, ref_mat)
    idx = np.argsort(vals)[::-1]
    return vals[idx], vecs[:, idx]

evals_1 = np.zeros((n_epochs, py_data.shape[0]))
evecs_1 = np.zeros((n_epochs, py_data.shape[0], py_data.shape[0]))

for i in range(n_epochs):
    v, e = compute_gevd(cov_1[i], ref_cov_reg)
    evals_1[i] = np.real(v)
    evecs_1[i] = e

print("Sensai at t=3.0:", sensai(epoched_1, 250, 1.0, 3.0, ref_cov, evals_1, evecs_1, 6)[2])
print("Sensai at t=5.0:", sensai(epoched_1, 250, 1.0, 5.0, ref_cov, evals_1, evecs_1, 6)[2])
