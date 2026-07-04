import os
import json
import numpy as np
import mne

def generate():
    print("Loading standard 10-05 montage...")
    montage = mne.channels.make_standard_montage('standard_1005')
    ch_names = montage.ch_names
    print(f"Total 10-05 channels in MNE: {len(ch_names)}")

    # Create dummy info at 1000 Hz
    info = mne.create_info(ch_names=ch_names, sfreq=1000, ch_types='eeg')
    info.set_montage(montage)

    # Paths
    fs_dir = os.path.join(mne.datasets.sample.data_path(), 'subjects', 'sample')
    subjects_dir = os.path.dirname(fs_dir)
    fname_src = os.path.join(fs_dir, 'bem', 'sample-oct-6-src.fif')
    fname_bem = os.path.join(fs_dir, 'bem', 'sample-5120-5120-5120-bem-sol.fif')

    print("Computing canonical forward solution (fixed=True, mindist=5.0)...")
    fwd = mne.make_forward_solution(
        info, trans='fsaverage', src=fname_src, bem=fname_bem,
        eeg=True, mindist=5.0, n_jobs=4
    )
    fwd_fixed = mne.convert_forward_solution(fwd, surf_ori=True, force_fixed=True, use_cps=True)
    
    leadfield = fwd_fixed['sol']['data'] # Shape: (n_channels, n_sources)
    valid_channels = fwd_fixed['info']['ch_names']
    print(f"Computed leadfield shape: {leadfield.shape} for {len(valid_channels)} valid channels.")

    # Get ROI labels
    print("Reading FreeSurfer aparc labels...")
    roi_labels = mne.read_labels_from_annot('sample', 'aparc', 'both', subjects_dir=subjects_dir)
    roi_labels = [lbl for lbl in roi_labels if 'unknown' not in lbl.name.lower()]
    print(f"Total valid ROI labels: {len(roi_labels)}")

    src = fwd_fixed['src']
    lh_vert_to_idx = {v: i for i, v in enumerate(src[0]['vertno'])}
    rh_vert_to_idx = {v: i + len(src[0]['vertno']) for i, v in enumerate(src[1]['vertno'])}

    rois_data = []
    for lbl in roi_labels:
        hemi = lbl.hemi
        mapping = lh_vert_to_idx if hemi == 'lh' else rh_vert_to_idx
        active_indices = []
        for v in lbl.vertices:
            if v in mapping:
                active_indices.append(mapping[v])
        
        rois_data.append({
            'name': lbl.name,
            'indices': active_indices
        })

    out_data = {
        'channels': valid_channels,
        'leadfield': np.round(leadfield, 6).tolist(),
        'rois': rois_data
    }

    out_path = os.path.join(os.path.dirname(__file__), '..', 'bridge', 'resources', 'fsaverage_1005_roi.json')
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    print(f"Saving to {out_path}...")
    with open(out_path, 'w') as f:
        json.dump(out_data, f)
    print("Done generating canonical leadfield!")

if __name__ == '__main__':
    generate()
