"""Independent MNE validation of fixtures from storage_export_fixtures_test.dart.
Run: python tools/validate_recording_exports.py [/tmp/ccs-storage-reference]
This tool reads exports only; MNE is a validation dependency, not an app runtime dependency.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault('NUMBA_DISABLE_JIT', '1')
os.environ.setdefault('_MNE_FAKE_HOME_DIR', str(Path(tempfile.gettempdir()) / 'ccs-mne-validation'))
os.environ.setdefault('MNE_DONTWRITE_HOME', 'true')
os.environ.setdefault('MPLCONFIGDIR', str(Path(tempfile.gettempdir()) / 'ccs-mpl-cache'))
import mne
import numpy as np

root = Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/ccs-storage-reference')
report = {}
for name in ['raw', 'epochs']:
    reference = json.loads((root / f'{name}.ccseeg').read_text())
    expected = np.asarray(reference['channels'])
    if name == 'raw':
        obj = mne.io.read_raw_fif(root / 'raw.fif', preload=True, verbose='ERROR')
        actual = obj.get_data() * 1e6
    else:
        obj = mne.read_epochs(root / 'epochs.fif', preload=True, proj=False, verbose='ERROR')
        actual = obj.get_data(copy=False).transpose(1, 0, 2).reshape(len(expected), -1) * 1e6
        assert obj.event_id == {'Target': 1, 'Standard': 2}
        assert abs(obj.times[0] - reference['epoch_tmin']) < 1e-9
        anchors = np.rint(np.asarray(reference['epoch_onsets']) * reference['sample_rate']).astype(int)
        np.testing.assert_array_equal(obj.events[:, 0], anchors)
    assert obj.ch_names == reference['labels']
    np.testing.assert_allclose(actual, expected, rtol=2e-7, atol=1e-6)
    report[f'{name}_fif'] = {'maximum_error_uv': float(np.max(np.abs(actual - expected)))}
    raw = mne.io.read_raw_edf(root / f'{name}.edf', preload=True, verbose='ERROR')
    actual = raw.get_data()[:, :expected.shape[1]] * 1e6
    metadata = json.loads((root / f'{name}.edf.ccsmeta').read_text())
    bounds = np.asarray(metadata['encoding']['quantization_step_uv']) / 2 + 1e-9
    assert np.all(np.max(np.abs(actual - expected), axis=1) <= bounds)
    assert 'S 10' in raw.annotations.description
    if name == 'epochs':
        assert 'EDGE boundary' in raw.annotations.description
    report[f'{name}_edf'] = {'maximum_error_uv': float(np.max(np.abs(actual - expected)))}
print(json.dumps(report, indent=2))
