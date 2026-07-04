import numpy as np
import json

py_data = np.load('parity_test/py_filter.npy')
with open('parity_test/py_filter_labels.json') as f:
    py_labels = json.load(f)

with open('parity_test/rs_filter.json') as f:
    rs_full = json.load(f)
rs_data = np.array(rs_full['channels'])
rs_labels = rs_full['labels']

common = [ch for ch in py_labels if ch in rs_labels]
py_idx = [py_labels.index(ch) for ch in common]
rs_idx = [rs_labels.index(ch) for ch in common]

n = min(py_data.shape[1], rs_data.shape[1])
# Ignore first 2000 and last 2000 samples (edge effects)
a = py_data[py_idx, 2000:n-2000]
b = rs_data[rs_idx, 2000:n-2000]

diff = a - b
rms = float(np.sqrt(np.mean(diff**2)))
max_err = float(np.max(np.abs(diff)))

print(f"Middle RMS: {rms:.6f} µV")
print(f"Middle Max: {max_err:.6f} µV")
