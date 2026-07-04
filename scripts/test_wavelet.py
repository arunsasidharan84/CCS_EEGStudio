import numpy as np
import json
from ccstools.ccs_eeg.gedai.utils import modwt_mra
import pywt

# Simple test signal
signal = np.sin(np.linspace(0, 10, 100)) + np.random.randn(100) * 0.1
mra = modwt_mra(signal, 'haar', 3)

with open('parity_test/py_wavelet.json', 'w') as f:
    json.dump([m.tolist() for m in mra], f)
