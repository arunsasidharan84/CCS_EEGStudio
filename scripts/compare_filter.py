import numpy as np
import json
import argparse

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
a = py_data[py_idx, :n]
b = rs_data[rs_idx, :n]

diff = a - b
rms = float(np.sqrt(np.mean(diff**2)))
max_err = float(np.max(np.abs(diff)))

print("Filter Parity Results:")
print(f"RMS: {rms:.6f} µV")
print(f"Max: {max_err:.6f} µV")
