#!/usr/bin/env python3
import json
import os
import sys
import argparse
from pathlib import Path
import numpy as np

sys.path.insert(0, "/Users/arunsasidharan/Code/Python_misc/fooof-main")
from specparam import SpectralModel
from specparam.bands import Bands

def compute_psd_welch(signal, sfreq):
    from scipy.signal import welch
    freqs, psd = welch(signal, fs=sfreq, nperseg=sfreq, window="hamming", scaling="density", average="median")
    return freqs, psd

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sfreq", type=int, default=250)
    args = parser.parse_args()
    sfreq = args.sfreq
    samples = sfreq * 15
    rng = np.random.default_rng(20260621)
    time = np.arange(samples) / sfreq
    signal = (
        1.8 * np.sin(2 * np.pi * 3 * time)
        + 2.6 * np.sin(2 * np.pi * 9.5 * time)
        + 1.1 * np.sin(2 * np.pi * 21 * time)
        + rng.standard_normal(samples) * 0.7
    )
    
    freqs, psd = compute_psd_welch(signal, sfreq)
    
    fm = SpectralModel(peak_width_limits=[1.0, 12.0], max_n_peaks=float("inf"), min_peak_height=0.0, peak_threshold=2.0, aperiodic_mode='fixed')
    fm.fit(freqs, psd, [1, 40])
    
    band_dict = {
        "Delta": (1, 4), "Theta": (4, 8), "ThetaAlpha": (6, 10),
        "Alpha": (8, 12), "Beta1": (12, 18), "Beta2": (18, 30),
        "Gamma1": (30, 40)
    }
    
    values = {}
    values["offset_FOOOF"] = float(fm.get_params('aperiodic')[0])
    values["exponent_FOOOF"] = float(fm.get_params('aperiodic')[1])
    values["error_FOOOF"] = float(fm.results.metrics['error_mae'].result)
    values["r_squared_FOOOF"] = float(fm.results.metrics['gof_rsquared'].result)
    
    peaks = fm.get_params('peak')
    if peaks.ndim == 1:
        peaks = peaks.reshape(1, -1) if len(peaks) > 0 else np.empty((0, 3))
    
    # Sort peaks by frequency (column 0) ascending
    if len(peaks) > 0:
        peaks = peaks[np.argsort(peaks[:, 0])]
        
    for i in range(2):
        if i < len(peaks):
            values[f"cf_{i}_FOOOF"] = float(peaks[i, 0])
            values[f"pw_{i}_FOOOF"] = float(peaks[i, 1])
            values[f"bw_{i}_FOOOF"] = float(peaks[i, 2])
        else:
            values[f"cf_{i}_FOOOF"] = float('nan')
            values[f"pw_{i}_FOOOF"] = float('nan')
            values[f"bw_{i}_FOOOF"] = float('nan')
            
    suffix = "" if sfreq == 250 else f"_{sfreq}hz"
    output = Path(__file__).with_name("reference") / f"spectral_specparam{suffix}.json"
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps({
        "sfreq": sfreq,
        "signal": signal.tolist(),
        "values": values,
    }, indent=2, sort_keys=True) + "\n")

if __name__ == "__main__":
    main()
