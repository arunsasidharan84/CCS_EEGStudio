#!/usr/bin/env python3
"""Generate deterministic mne-connectivity 0.8 reference values for Rust tests."""

import json
from pathlib import Path

import numpy as np
from mne_connectivity import spectral_connectivity_time


def main():
    sfreq = 100.0
    samples = 400
    rng = np.random.default_rng(20260621)
    noise = rng.standard_normal((4, samples)) * 0.12
    data = np.zeros((4, samples), dtype=np.float64)
    for t in range(2, samples):
        data[0, t] = 0.72 * data[0, t - 1] - 0.18 * data[0, t - 2] + noise[0, t]
        data[1, t] = 0.55 * data[1, t - 1] + 0.30 * data[0, t - 1] + noise[1, t]
        data[2, t] = 0.48 * data[2, t - 1] + 0.42 * data[0, t - 2] + noise[2, t]
        data[3, t] = 0.35 * data[3, t - 1] + 0.38 * data[1, t - 1] + noise[3, t]
    time = np.arange(samples) / sfreq
    data += np.array([
        np.sin(2 * np.pi * 7 * time),
        np.sin(2 * np.pi * 7 * time + 0.55),
        0.7 * np.sin(2 * np.pi * 11 * time + 0.9),
        0.5 * np.sin(2 * np.pi * 19 * time + 1.1),
    ])
    epochs = data[np.newaxis]
    freqs = np.logspace(np.log10(4), np.log10(40), 15)
    cycles = np.logspace(np.log10(3), np.log10(20), len(freqs)).astype(int)

    bivariate = spectral_connectivity_time(
        epochs,
        method=["coh", "plv", "ciplv", "pli", "wpli"],
        freqs=freqs,
        faverage=False,
        n_cycles=cycles,
        mode="cwt_morlet",
        sfreq=sfreq,
        fmin=4,
        fmax=40,
        n_jobs=1,
        verbose=False,
    )
    bivariate_reduced = {}
    for metric, result in zip(["coh", "plv", "ciplv", "pli", "wpli"], bivariate):
        values = result.get_data()[0].reshape(4, 4, len(freqs))
        reduced = (np.nansum(values, axis=0) + np.nansum(values, axis=1)) / 4
        bivariate_reduced[metric] = reduced.tolist()

    multivariate = spectral_connectivity_time(
        epochs,
        method=["mic", "mim", "gc", "gc_tr"],
        indices=([[0, 1]], [[2, 3]]),
        rank=None,
        gc_n_lags=25,
        freqs=freqs,
        faverage=False,
        n_cycles=cycles,
        mode="cwt_morlet",
        sfreq=sfreq,
        fmin=4,
        fmax=40,
        n_jobs=1,
        verbose=False,
    )
    multivariate_values = {
        metric: result.get_data()[0, 0].tolist()
        for metric, result in zip(["mic", "mim", "gc", "gc_tr"], multivariate)
    }
    Path(__file__).with_name("reference").mkdir(exist_ok=True)
    Path(__file__).with_name("reference").joinpath("connectivity_mne_0_8.json").write_text(
        json.dumps({
            "sfreq": sfreq,
            "labels": ["F1", "F2", "P1", "O1"],
            "data": data.tolist(),
            "frequencies": freqs.tolist(),
            "bivariate": bivariate_reduced,
            "multivariate": multivariate_values,
        }, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
