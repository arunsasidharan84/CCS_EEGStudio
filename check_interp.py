import numpy as np
from mne.channels.interpolation import _make_interpolation_matrix
pos = np.array([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]])
to_pos = np.array([[-1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.0, 0.0, -1.0]])
W_mne = _make_interpolation_matrix(pos, to_pos)
print('W_mne shape:', W_mne.shape)
