import json
import numpy as np

py_data = np.load('parity_test/py_filter.npy')
with open('parity_test/py_filter_labels.json') as f:
    py_labels = json.load(f)

# Save as JSON to pass to Rust test
with open('parity_test/py_data_for_rust.json', 'w') as f:
    json.dump({'data': py_data.tolist(), 'labels': py_labels}, f)
