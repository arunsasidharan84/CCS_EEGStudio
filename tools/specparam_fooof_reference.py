#!/usr/bin/env python3
"""FOOOF/specparam reference helper.

This uses the local `/Users/arunsasidharan/Code/Python_misc/fooof-main` checkout and
emits CCS-compatible FOOOF columns for a JSON payload:

{
  "sfreq": 1000.0,
  "signals": [[...], ...],
  "bands": [[1, 4, "Delta"], ...]
}

The helper is intentionally separate from the Rust engine: exact FOOOF parity
requires the canonical scipy/specparam optimizer. The Rust native path remains
available for lightweight execution, but this helper is the reference path for
auditing or exact-parity runs.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
from scipy import integrate
from scipy.signal import welch

FOOOF_MAIN = Path("/Users/arunsasidharan/Code/Python_misc/fooof-main")
sys.path.insert(0, str(FOOOF_MAIN))

from specparam.models import SpectralModel  # noqa: E402


def bandpower_from_psd(psd: np.ndarray, freqs: np.ndarray, bands):
    total = integrate.simpson(psd[(freqs >= 1) & (freqs <= 40)], x=freqs[(freqs >= 1) & (freqs <= 40)])
    out = {}
    for low, high, name in bands:
        mask = (freqs >= low) & (freqs <= high)
        out[f"{name}_FOOOF"] = float(integrate.simpson(psd[mask], x=freqs[mask]) / total) if total else np.nan
    return out


def fractional_edge(values: np.ndarray, freqs: np.ndarray) -> float:
    clipped = np.maximum(values, 0)
    total = clipped.sum()
    if total <= 0:
        return 0.0
    idx = int(np.searchsorted(np.cumsum(clipped), total / 2.0))
    return float(freqs[min(idx, len(freqs) - 1)])


def main():
    payload = json.load(sys.stdin)
    sfreq = float(payload["sfreq"])
    signals = np.asarray(payload["signals"], dtype=float)
    bands = payload.get(
        "bands",
        [
            [1, 4, "Delta"],
            [4, 8, "Theta"],
            [6, 10, "ThetaAlpha"],
            [8, 12, "Alpha"],
            [12, 18, "Beta1"],
            [18, 30, "Beta2"],
            [30, 40, "Gamma1"],
        ],
    )
    freqs, psds = welch(
        signals,
        fs=sfreq,
        axis=-1,
        scaling="density",
        average="median",
        window="hamming",
        nperseg=int(sfreq),
    )
    rows = []
    for idx, psd in enumerate(psds):
        row = {}
        fm = SpectralModel(verbose=False)
        fm.fit(freqs, psd, [1, 40])
        fit_freqs = fm.data.freqs
        ap = 10 ** fm.results.model._ap_fit
        peaks = 10 ** (fm.results.model._peak_fit + fm.results.model._ap_fit) - ap
        peaks = np.maximum(peaks, 0)
        row.update(bandpower_from_psd(peaks, fit_freqs, bands))
        ap_params = fm.results.params.aperiodic.params
        row["offset_FOOOF"] = float(ap_params[0]) if len(ap_params) > 0 else np.nan
        row["exponent_FOOOF"] = float(ap_params[1]) if len(ap_params) > 1 else np.nan
        peaks_params = np.asarray(fm.results.params.periodic.params, dtype=float)
        for peak_idx in range(2):
            if peaks_params.ndim == 2 and peak_idx < peaks_params.shape[0]:
                row[f"cf_{peak_idx}_FOOOF"] = float(peaks_params[peak_idx, 0])
                row[f"pw_{peak_idx}_FOOOF"] = float(peaks_params[peak_idx, 1])
                row[f"bw_{peak_idx}_FOOOF"] = float(peaks_params[peak_idx, 2])
            else:
                row[f"cf_{peak_idx}_FOOOF"] = np.nan
                row[f"pw_{peak_idx}_FOOOF"] = np.nan
                row[f"bw_{peak_idx}_FOOOF"] = np.nan
        metrics = fm.results.get_results().metrics
        row["error_FOOOF"] = float(metrics.get("error_mae", np.nan))
        row["r_squared_FOOOF"] = float(metrics.get("gof_rsquared", np.nan))
        row["auc_FOOOF"] = float(integrate.simpson(peaks - ap, x=fit_freqs))
        row["oscspectraledge_FOOOF"] = fractional_edge(peaks, fit_freqs)
        rows.append(row)
    json.dump(rows, sys.stdout, allow_nan=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
