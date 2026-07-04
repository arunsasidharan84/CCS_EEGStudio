#!/usr/bin/env python3
"""Generate deterministic ccstools FOOOF/IRASA reference values."""

import json
import os
import sys
import argparse
from pathlib import Path

import numpy as np

toolbox = os.environ.get("CCS_TOOLBOX")
if toolbox:
    sys.path.insert(0, toolbox)

from ccstools.eegfeatures import generate_multieegfeatures


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
    bands = [
        (1, 4, "Delta"), (4, 8, "Theta"), (6, 10, "ThetaAlpha"),
        (8, 12, "Alpha"), (12, 18, "Beta1"), (18, 30, "Beta2"),
        (30, 40, "Gamma1"),
    ]
    frame = generate_multieegfeatures(
        signal[np.newaxis, np.newaxis],
        sfreq,
        ["Fz"],
        featurelist=["fooof", "irasa"],
        psdtype="welch",
        kwargs_psd=dict(
            scaling="density", average="median", window="hamming", nperseg=sfreq
        ),
        freq_range=[1, 40],
        bands=bands,
    )
    values = {
        key: float(value)
        for key, value in frame.iloc[0].items()
        if key not in ("Chan", "Epoch")
    }
    suffix = "" if sfreq == 250 else f"_{sfreq}hz"
    output = Path(__file__).with_name("reference") / f"spectral_ccstools{suffix}.json"
    output.write_text(json.dumps({
        "sfreq": sfreq,
        "signal": signal.tolist(),
        "values": values,
    }, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
