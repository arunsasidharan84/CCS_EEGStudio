#!/usr/bin/env python3
"""Run the bundled EDF fixtures and verify the sequences.py parity contract.

This deliberately recomputes LZ, shuffled normalization, duration variance,
global transition probabilities, and entropy production with NumPy + antropy,
using the formulas in EEG_Microstates/sequences.py rather than engine helpers.
"""

from __future__ import annotations

import argparse
import itertools
import json
import struct
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from antropy import lziv_complexity


def _fields(data: bytes, offset: int, count: int, width: int) -> list[str]:
    return [
        data[offset + i * width : offset + (i + 1) * width]
        .decode("ascii", "ignore")
        .strip()
        for i in range(count)
    ]


def read_edf(path: Path) -> dict:
    data = path.read_bytes()
    header_bytes = int(data[184:192])
    record_count = int(data[236:244])
    record_seconds = float(data[244:252])
    signal_count = int(data[252:256])
    offset = 256
    labels = _fields(data, offset, signal_count, 16)
    offset += signal_count * 16 + signal_count * 80
    dimensions = _fields(data, offset, signal_count, 8)
    offset += signal_count * 8

    def numbers() -> list[float]:
        nonlocal offset
        result = [float(x.replace(",", ".")) for x in _fields(data, offset, signal_count, 8)]
        offset += signal_count * 8
        return result

    physical_min, physical_max = numbers(), numbers()
    digital_min, digital_max = numbers(), numbers()
    offset += signal_count * 80
    samples_per_record = [int(x) for x in _fields(data, offset, signal_count, 8)]
    keep = [i for i, label in enumerate(labels) if "annotation" not in label.lower() and "status" not in label.lower()]
    channels = [[0.0] * (record_count * samples_per_record[i]) for i in keep]
    keep_index = {source: target for target, source in enumerate(keep)}
    cursor = header_bytes
    for record in range(record_count):
        for channel in range(signal_count):
            gain = (physical_max[channel] - physical_min[channel]) / (digital_max[channel] - digital_min[channel])
            intercept = physical_min[channel] - gain * digital_min[channel]
            for sample in range(samples_per_record[channel]):
                digital = struct.unpack_from("<h", data, cursor)[0]
                cursor += 2
                if channel in keep_index:
                    value = digital * gain + intercept
                    if dimensions[channel].lower() == "v":
                        value *= 1e6
                    channels[keep_index[channel]][record * samples_per_record[channel] + sample] = value
    return {
        "format": "ccseeg-v1",
        "sample_rate": samples_per_record[keep[0]] / record_seconds,
        "labels": [labels[i] for i in keep],
        "channels": channels,
    }


def reference_metrics(sequence: list[int]) -> dict[str, float | int]:
    seq_arr = np.ravel(sequence).astype(int)
    shuffled = seq_arr.copy()
    np.random.shuffle(shuffled)
    lz_actual = int(lziv_complexity("".join(map(str, seq_arr))))
    lz_shuffled = int(lziv_complexity("".join(map(str, shuffled))))
    durations = np.fromiter(
        (sum(1 for _ in group) for _, group in itertools.groupby(seq_arr)), dtype=int
    )
    _, mapped = np.unique(seq_arr, return_inverse=True)
    count = int(np.max(mapped)) + 1
    matrix = np.zeros((count, count))
    np.add.at(matrix, (mapped[:-1], mapped[1:]), 1)
    matrix /= mapped.size - 1
    mask = (matrix > 0) & (matrix.T > 0)
    return {
        "lz_complexity": lz_actual,
        "shuffled_lz_complexity": lz_shuffled,
        "normalized_lz": lz_actual / lz_shuffled if lz_shuffled else 0,
        "duration_variance_samples2": float(np.var(durations)) if durations.size else 0,
        "entropy_production": float(np.sum(matrix[mask] * np.log(matrix[mask] / matrix.T[mask]))),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", type=Path, default=Path("/Users/arunsasidharan/EEGdata/EEG_Microstates"))
    parser.add_argument("--engine", type=Path, default=Path("bridge/target/release/ccs-eeg-engine"))
    parser.add_argument("--output", type=Path, default=Path("build/microstate_parity"))
    args = parser.parse_args()
    edfs = sorted(args.fixtures.glob("*.edf"))
    if not edfs:
        raise SystemExit(f"No EDF fixtures in {args.fixtures}")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ccs_microstate_parity_") as temp_name:
        temp = Path(temp_name)
        inputs = []
        for index, edf in enumerate(edfs):
            path = temp / f"input_{index}.ccseeg.json"
            path.write_text(json.dumps(read_edf(edf)))
            inputs.append(str(path))
        job = {
            "job_type": "microstates",
            "input": inputs[0],
            "output": str(args.output.resolve()),
            "format": "ccseeg",
            "epoch_seconds": 2,
            "options": {
                "mode": "full", "start_seconds": 0, "end_seconds": 0, "bin_seconds": 60,
                "psd": False, "fooof": False, "irasa": False, "nonlinear": False,
                "acw": False, "connectivity": False, "mic": False, "mim": False,
                "gc": False, "gc_tr": False, "coh": False, "plv": False,
                "ciplv": False, "pli": False, "wpli": False, "remove_non_eeg": False,
                "exclusions": [], "non_eeg_channels": [],
            },
            "microstate_inputs": inputs,
            "microstate_names": [x.name for x in edfs],
            "microstate_options": {},
        }
        job_path = temp / "job.json"
        job_path.write_text(json.dumps(job))
        run = subprocess.run([str(args.engine.resolve()), str(job_path)], check=True, capture_output=True, text=True)
        native = json.loads(run.stdout)

    np.random.seed(12345)
    comparisons = []
    passed = True
    for recording in native["recordings"]:
        reference = reference_metrics(recording["sequence"])
        checks = {}
        for key, expected in reference.items():
            actual = recording["sequence_metrics"][key]
            tolerance = 0 if isinstance(expected, int) else 1e-12
            ok = abs(actual - expected) <= tolerance
            checks[key] = {"native": actual, "python": expected, "absolute_error": abs(actual - expected), "pass": ok}
            passed &= ok
        comparisons.append({"filename": recording["filename"], "samples": len(recording["sequence"]), "gev_total": recording["gev_total"], "checks": checks})
    report = {
        "passed": passed,
        "fixtures": [str(x) for x in edfs],
        "selected_states": native["selected_states"],
        "state_labels": native["state_labels"],
        "canonical_resource": "MetaMaps_2023_06.set",
        "canonical_correlations": native["canonical_correlations"],
        "canonical_remapping": "Perrin spherical spline (m=4, Legendre orders 1-7), matching accs_splint2.m",
        "model_fits": native["model_fits"],
        "comparisons": comparisons,
        "note": "Sequence metrics independently recomputed with the supplied sequences.py formulas and antropy.",
    }
    (args.output / "parity_report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
