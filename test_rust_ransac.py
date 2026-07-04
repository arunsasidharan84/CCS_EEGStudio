import numpy as np
from mne.channels.interpolation import _make_interpolation_matrix

# Try a very simple test case
pos_from = np.array([[1,0,0], [0,1,0], [0,0,1], [-1,0,0], [0,-1,0], [0,0,-1]], dtype=float)
pos_to = pos_from.copy()

subset = [0, 1, 2, 3]
pos_subset = pos_from[subset]

W = _make_interpolation_matrix(pos_subset, pos_to)
print("W shape:", W.shape)

mapping = np.zeros((6, 6))
mapping[subset, :] = W

data = np.random.randn(6, 10)
y_pred = data.T.dot(mapping)

print("y_pred shape:", y_pred.shape)
print("Mapping sum:", mapping.sum())
