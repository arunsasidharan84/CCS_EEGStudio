import mne
import numpy as np
from autoreject import Ransac

raw = mne.io.read_raw_edf('/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/EEG_MeditationEyesClosed.edf', preload=True)
standard_montage = mne.channels.make_standard_montage('standard_1005')
std_names = standard_montage.ch_names
lookup = {name.lower(): name for name in std_names}
rename_dict = {}
keep_channels = []    
for ch in raw.ch_names:
    if ch in std_names:
        keep_channels.append(ch)
    elif ch.lower() in lookup:
        standard_name = lookup[ch.lower()]
        rename_dict[ch] = standard_name
        keep_channels.append(standard_name)

raw.rename_channels(rename_dict)
raw.set_montage('standard_1005', on_missing='ignore')

events = mne.make_fixed_length_events(raw, duration=1.0)
epochs = mne.Epochs(raw, events, tmin=0, tmax=1.0, baseline=None, preload=True, verbose=False)

rsc = Ransac(n_jobs=1, min_corr=0.75, verbose=False)
rsc.fit(epochs)

print('Mappings shape:', rsc.mappings_.shape)
print('Bad channels:', rsc.bad_chs_)
