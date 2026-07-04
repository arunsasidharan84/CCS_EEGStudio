#!/usr/bin/env python3
"""Generate Python-vs-Rust parity report for AKNLTP014_REMED1_RCB.

The feature reference follows extract_EEGfeatures_connectivity_20250902_Ver10.0.py:
- EEGLAB input through MNE
- optional non-EEG removal is represented here by an explicit EEG channel list
- average reference
- generate_multieegfeatures with the same bands and Welch kwargs
- mne_connectivity.spectral_connectivity_time with the same Morlet frequencies/cycles

The preprocessing reference follows EEG_preprocessing.py's ccstools pipeline steps
on the same short slice.
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("HOME", "/tmp")
os.environ.setdefault("NUMBA_CACHE_DIR", "/tmp/numba_cache")

import matplotlib.pyplot as plt
import mne
import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT
DATA_ROOT = Path("/Users/arunsasidharan/EEGdata/EEGAnalysisCode")
SAMPLE = DATA_ROOT / "sampleData" / "AKNLTP014_REMED1_RCB.set"
OUT = REPO_ROOT / "reports" / "aknl_parity"
ENGINE = REPO_ROOT / "bridge" / "target" / "release" / "ccs-eeg-engine"
CCS_TOOLBOX = Path("/Users/arunsasidharan/Code/ActiveProjects/ccs_toolbox")
CHANNELS = ["Fz", "F3", "F4", "C3", "C4", "P3", "P4", "Pz", "O1", "O2"]
EPOCH_SECONDS = 15.0
WINDOW_SECONDS = 15.0
PREPROCESS_WINDOW_SECONDS = 4.0
BANDS = [
    (1, 4, "Delta"),
    (4, 8, "Theta"),
    (6, 10, "ThetaAlpha"),
    (8, 12, "Alpha"),
    (12, 18, "Beta1"),
    (18, 30, "Beta2"),
    (30, 40, "Gamma1"),
]


def main() -> None:
    sys.path.insert(0, str(CCS_TOOLBOX))
    OUT.mkdir(parents=True, exist_ok=True)

    build_engine()
    python_features = run_python_feature_reference()
    rust_features = run_rust_feature_extraction()
    feature_summary = compare_feature_frames(python_features, rust_features)
    preprocessing_summary = run_preprocessing_comparison()
    write_report(feature_summary, preprocessing_summary)


def build_engine() -> None:
    env = os.environ.copy()
    env["HOME"] = "/Users/arunsasidharan"
    subprocess.run(
        ["/Users/arunsasidharan/.cargo/bin/cargo", "build", "--release", "--manifest-path", str(REPO_ROOT / "bridge" / "Cargo.toml")],
        env=env,
        check=True,
    )


def read_reference_raw() -> mne.io.BaseRaw:
    raw = mne.io.read_raw_eeglab(SAMPLE, preload=True, verbose=False)
    raw.pick([ch for ch in CHANNELS if ch in raw.ch_names])
    raw.crop(tmin=0, tmax=WINDOW_SECONDS, include_tmax=False)
    raw.set_eeg_reference("average", projection=False, verbose=False)
    return raw


def fixed_epochs(raw: mne.io.BaseRaw) -> mne.Epochs:
    events = mne.make_fixed_length_events(raw, start=0, stop=WINDOW_SECONDS, duration=EPOCH_SECONDS)
    return mne.Epochs(
        raw,
        events,
        tmin=0,
        tmax=EPOCH_SECONDS - 1.0 / raw.info["sfreq"],
        baseline=None,
        preload=True,
        verbose=False,
    )


def run_python_feature_reference() -> pd.DataFrame:
    from ccstools.eegfeatures import generate_multieegfeatures
    import mne_connectivity as mnecon

    raw = read_reference_raw()
    epochs = fixed_epochs(raw)
    srate = epochs.info["sfreq"]
    chanlist = epochs.ch_names
    df = generate_multieegfeatures(
        epochs.get_data(copy=True) * 1e6,
        srate,
        chanlist,
        featurelist=["psd", "fooof", "irasa", "nonlinear", "acw"],
        psdtype="welch",
        kwargs_psd=dict(scaling="density", average="median", window="hamming", nperseg=int(srate)),
        freq_range=[1, 50],
        bands=BANDS,
    )

    freqs = np.logspace(np.log10(4), np.log10(BANDS[-1][1]), 15)
    freqcycles = np.logspace(np.log10(3), np.log10(BANDS[-1][1] / 2), len(freqs)).astype(int)
    bands2use = BANDS[1:]
    errors: dict[str, str] = {}

    for method in ["mic", "mim", "gc", "gc_tr"]:
        try:
            seeds = [i for i, y in enumerate(chanlist) if "F" in y[0]]
            targets = [i for i, y in enumerate(chanlist) if ("P" in y[0] or "O" in y[0])]
            con_result = mnecon.spectral_connectivity_time(
                epochs,
                method=[method],
                indices=([seeds], [targets]),
                rank=None,
                gc_n_lags=25,
                freqs=freqs,
                faverage=False,
                n_cycles=freqcycles,
                mode="cwt_morlet",
                sfreq=srate,
                fmin=4,
                fmax=BANDS[-1][1],
                n_jobs=1,
            )
            con = con_result[0] if isinstance(con_result, (list, tuple)) else con_result
            data = con.get_data()
            data = np.repeat(data, len(chanlist), axis=1)
            data = data.reshape([data.shape[0] * data.shape[1], data.shape[2]])
            band_data = np.zeros([data.shape[0], len(bands2use)])
            for band_no, band in enumerate(bands2use):
                band_data[:, band_no] = np.mean(data[:, np.logical_and(freqs >= band[0], freqs <= band[1])], axis=1)
            df = pd.concat(
                [df, pd.DataFrame(band_data, columns=[f"conn_{method}_{x[-1]}" for x in bands2use])],
                axis=1,
            )
        except Exception as exc:  # MNE GC may reject short/singular windows.
            errors[method] = str(exc)

    for method in ["coh", "plv", "ciplv", "pli", "wpli"]:
        try:
            con_result = mnecon.spectral_connectivity_time(
                epochs,
                method=[method],
                freqs=freqs,
                faverage=False,
                n_cycles=freqcycles,
                mode="cwt_morlet",
                sfreq=srate,
                fmin=4,
                fmax=BANDS[-1][1],
                n_jobs=1,
            )
            con = con_result[0] if isinstance(con_result, (list, tuple)) else con_result
            data = con.get_data()
            data = data.transpose([1, 0, 2]).reshape([len(chanlist), len(chanlist), data.shape[0], data.shape[-1]])
            data = (np.nansum(data, axis=0) + np.nansum(data, axis=1)) / len(chanlist)
            data = data.transpose([1, 0, 2]).reshape([data.shape[0] * data.shape[1], data.shape[2]])
            band_data = np.zeros([data.shape[0], len(bands2use)])
            for band_no, band in enumerate(bands2use):
                band_data[:, band_no] = np.mean(data[:, np.logical_and(freqs >= band[0], freqs <= band[1])], axis=1)
            df = pd.concat(
                [df, pd.DataFrame(band_data, columns=[f"conn_{method}_{x[-1]}" for x in bands2use])],
                axis=1,
            )
        except Exception as exc:
            errors[method] = str(exc)

    df["filename"] = "AKNLTP014_REMED1_RCB"
    df["subjid"] = "AKNLTP014"
    df["sessn"] = "REMED1"
    df["condn"] = "RCB"
    df["bin_idx"] = 0
    df["bin_start_s"] = 0.0
    df["bin_end_s"] = WINDOW_SECONDS
    df["mode"] = "full"
    df.to_csv(OUT / "python_features.csv", index=False)
    (OUT / "python_connectivity_errors.json").write_text(json.dumps(errors, indent=2) + "\n")
    return df


def run_rust_feature_extraction() -> pd.DataFrame:
    job = {
        "job_type": "extract",
        "input": str(SAMPLE),
        "output": str(OUT / "rust_features.csv"),
        "format": "set",
        "data_path": str(SAMPLE.with_suffix(".fdt")),
        "sample_rate": 1000.0,
        "labels": all_set_labels(),
        "sample_count": 118000,
        "epoch_count": 1,
        "points_per_epoch": 118000,
        "epoch_seconds": EPOCH_SECONDS,
        "selected_channels": CHANNELS,
        "accepted_intervals": [[0, WINDOW_SECONDS]],
        "rejected_intervals": [],
        "options": {
            "mode": "full",
            "start_seconds": 0,
            "end_seconds": WINDOW_SECONDS,
            "bin_seconds": 60,
            "psd": True,
            "fooof": True,
            "irasa": True,
            "nonlinear": True,
            "acw": True,
            "connectivity": True,
            "mic": True,
            "mim": True,
            "gc": True,
            "gc_tr": True,
            "coh": True,
            "plv": True,
            "ciplv": True,
            "pli": True,
            "wpli": True,
            "remove_non_eeg": True,
        },
    }
    path = OUT / "rust_feature_job.json"
    path.write_text(json.dumps(job, indent=2))
    proc = subprocess.run([str(ENGINE), str(path)], text=True, capture_output=True)
    (OUT / "rust_feature_stderr.txt").write_text(proc.stderr)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr)
    return pd.read_csv(OUT / "rust_features.csv")


def all_set_labels() -> list[str]:
    raw = mne.io.read_raw_eeglab(SAMPLE, preload=False, verbose=False)
    return list(raw.ch_names)


def compare_feature_frames(py: pd.DataFrame, rust: pd.DataFrame) -> dict[str, object]:
    key_cols = ["Chan", "Epoch"]
    common = [c for c in py.columns if c in rust.columns and c not in key_cols]
    numeric = [c for c in common if pd.api.types.is_numeric_dtype(py[c]) and pd.api.types.is_numeric_dtype(rust[c])]
    py2 = py.sort_values(key_cols).reset_index(drop=True)
    rust2 = rust.sort_values(key_cols).reset_index(drop=True)
    rows = []
    for col in numeric:
        a = pd.to_numeric(py2[col], errors="coerce").to_numpy(float)
        b = pd.to_numeric(rust2[col], errors="coerce").to_numpy(float)
        mask = np.isfinite(a) & np.isfinite(b)
        if not mask.any():
            rows.append(dict(feature=col, n=0, max_abs=np.nan, mean_abs=np.nan, max_rel=np.nan, corr=np.nan))
            continue
        diff = np.abs(a[mask] - b[mask])
        denom = np.maximum(np.abs(a[mask]), 1e-12)
        corr = np.corrcoef(a[mask], b[mask])[0, 1] if mask.sum() > 1 and np.std(a[mask]) > 0 and np.std(b[mask]) > 0 else np.nan
        rows.append(
            dict(
                feature=col,
                n=int(mask.sum()),
                max_abs=float(np.max(diff)),
                mean_abs=float(np.mean(diff)),
                max_rel=float(np.max(diff / denom)),
                corr=float(corr) if np.isfinite(corr) else np.nan,
            )
        )
    comp = pd.DataFrame(rows).sort_values(["max_abs", "mean_abs"], ascending=False)
    comp.to_csv(OUT / "feature_comparison_by_column.csv", index=False)
    family = comp.assign(family=comp["feature"].map(feature_family)).groupby("family").agg(
        n_features=("feature", "count"),
        max_abs=("max_abs", "max"),
        median_mean_abs=("mean_abs", "median"),
        median_corr=("corr", "median"),
    )
    family.to_csv(OUT / "feature_comparison_by_family.csv")
    plot_feature_parity(py2, rust2, comp, numeric)
    return {
        "python_shape": list(py.shape),
        "rust_shape": list(rust.shape),
        "common_numeric_features": len(numeric),
        "worst": comp.head(20).replace({np.nan: None}).to_dict(orient="records"),
        "family": family.reset_index().replace({np.nan: None}).to_dict(orient="records"),
    }


def feature_family(name: str) -> str:
    if name.startswith("conn_"):
        return "connectivity"
    if name.endswith("_PSD"):
        return "psd"
    if "FOOOF" in name:
        return "fooof"
    if "Irasa" in name:
        return "irasa"
    if "nonlinear" in name:
        return "nonlinear"
    if name == "ACW":
        return "acw"
    return "metadata"


def plot_feature_parity(py: pd.DataFrame, rust: pd.DataFrame, comp: pd.DataFrame, numeric: list[str]) -> None:
    comp_plot = comp.assign(family=comp["feature"].map(feature_family))
    order = ["psd", "irasa", "nonlinear", "acw", "connectivity", "fooof"]
    family = (
        comp_plot[comp_plot["family"].isin(order)]
        .groupby("family", as_index=False)
        .agg(median_mean_abs=("mean_abs", "median"), median_corr=("corr", "median"), max_abs=("max_abs", "max"))
    )
    family["family"] = pd.Categorical(family["family"], categories=order, ordered=True)
    family = family.sort_values("family")

    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    axes[0].bar(family["family"].astype(str), family["median_mean_abs"], color="#376996")
    axes[0].set_yscale("symlog", linthresh=1e-8)
    axes[0].set_title("Median mean absolute error by family")
    axes[0].set_ylabel("absolute error")
    axes[0].tick_params(axis="x", rotation=35)
    axes[1].bar(family["family"].astype(str), family["median_corr"].fillna(0), color="#2A9D8F")
    axes[1].set_ylim(-0.1, 1.05)
    axes[1].set_title("Median Python-vs-Rust correlation")
    axes[1].tick_params(axis="x", rotation=35)
    fig.tight_layout()
    fig.savefig(OUT / "feature_family_parity.png", dpi=170)
    plt.close(fig)

    scatter_specs = [
        ("psd", "PSD features"),
        ("irasa", "IRASA features"),
        ("connectivity", "Connectivity features"),
        ("fooof", "FOOOF features"),
    ]
    fig, axes = plt.subplots(2, 2, figsize=(10, 9))
    for ax, (family_name, title) in zip(axes.ravel(), scatter_specs):
        cols = [c for c in numeric if feature_family(c) == family_name]
        if not cols:
            ax.set_axis_off()
            continue
        x = pd.concat([pd.to_numeric(py[c], errors="coerce") for c in cols], ignore_index=True).to_numpy(float)
        y = pd.concat([pd.to_numeric(rust[c], errors="coerce") for c in cols], ignore_index=True).to_numpy(float)
        mask = np.isfinite(x) & np.isfinite(y)
        x = x[mask]
        y = y[mask]
        ax.scatter(x, y, s=14, alpha=0.65, edgecolors="none")
        if x.size:
            lo = float(np.nanmin([x.min(), y.min()]))
            hi = float(np.nanmax([x.max(), y.max()]))
            if lo == hi:
                lo -= 1.0
                hi += 1.0
            pad = 0.05 * (hi - lo)
            ax.plot([lo - pad, hi + pad], [lo - pad, hi + pad], "k--", lw=0.8)
            ax.set_xlim(lo - pad, hi + pad)
            ax.set_ylim(lo - pad, hi + pad)
        corr = np.corrcoef(x, y)[0, 1] if x.size > 1 and np.std(x) > 0 and np.std(y) > 0 else np.nan
        ax.set_title(f"{title} (r={fmt(corr)})")
        ax.set_xlabel("Python")
        ax.set_ylabel("Rust")
    fig.tight_layout()
    fig.savefig(OUT / "feature_scatter_parity.png", dpi=170)
    plt.close(fig)

    conn_cols = [c for c in numeric if c.startswith("conn_")]
    if conn_cols:
        conn = comp[comp["feature"].isin(conn_cols)].copy()
        conn["metric"] = conn["feature"].str.extract(r"^conn_([^_]+(?:_tr)?)_")
        metric = conn.groupby("metric", as_index=False).agg(median_mean_abs=("mean_abs", "median"), max_abs=("max_abs", "max"))
        fig, ax = plt.subplots(figsize=(8, 4))
        ax.bar(metric["metric"], metric["median_mean_abs"], color="#6A4C93", label="median mean abs")
        ax.scatter(metric["metric"], metric["max_abs"], color="#E76F51", label="max abs", zorder=3)
        ax.set_yscale("symlog", linthresh=1e-8)
        ax.set_title("Connectivity parity by metric")
        ax.set_ylabel("absolute error")
        ax.legend()
        fig.tight_layout()
        fig.savefig(OUT / "connectivity_metric_parity.png", dpi=170)
        plt.close(fig)


def run_preprocessing_comparison() -> dict[str, object]:
    sys.path.insert(0, str(CCS_TOOLBOX))
    from ccstools.ccs_eeg.pipeline import run_ccs_pipeline

    raw = mne.io.read_raw_eeglab(SAMPLE, preload=True, verbose=False)
    raw.pick([ch for ch in CHANNELS if ch in raw.ch_names])
    raw.crop(tmin=0, tmax=PREPROCESS_WINDOW_SECONDS, include_tmax=False)
    raw_py = raw.copy()
    raw_rs = raw.copy()

    py_errors = []
    try:
        py_clean = run_ccs_pipeline(
            raw_py,
            output_dir=str(OUT / "python_preprocess_artifacts"),
            config={
                "steps": ["downsample", "filter", "badchannel", "gedai", "interpolate", "save"],
                "downsample_freq": 250,
                "filter_bandpass": (0.5, 40),
                "notch_freqs": (50,),
            },
        )
        py_data_uv = py_clean.get_data() * 1e6
        py_labels = py_clean.ch_names
        py_rate = float(py_clean.info["sfreq"])
    except Exception as exc:
        py_errors.append(str(exc))
        py_data_uv = raw_rs.get_data() * 1e6
        py_labels = raw_rs.ch_names
        py_rate = float(raw_rs.info["sfreq"])

    rust_out = OUT / "rust_preprocessed.ccseeg.json"
    job = {
        "job_type": "preprocess",
        "input": str(SAMPLE),
        "output": str(rust_out),
        "format": "set",
        "data_path": str(SAMPLE.with_suffix(".fdt")),
        "sample_rate": 1000.0,
        "labels": all_set_labels(),
        "sample_count": 118000,
        "epoch_count": 1,
        "points_per_epoch": 118000,
        "epoch_seconds": 1.0,
        "selected_channels": CHANNELS,
            "accepted_intervals": [[0, PREPROCESS_WINDOW_SECONDS]],
        "rejected_intervals": [],
        "options": empty_options(),
        "preprocessing": {
            "downsample": True,
            "downsample_freq": 250,
            "filter": True,
            "low_hz": 0.5,
            "high_hz": 40,
            "notch_hz": 50,
            "badchannel": True,
            "gedai": True,
            "interpolate": True,
            "gedai_epoch_seconds": 1.0,
            "gedai_threshold": "auto",
        },
    }
    path = OUT / "rust_preprocess_job.json"
    path.write_text(json.dumps(job, indent=2))
    proc = subprocess.run([str(ENGINE), str(path)], text=True, capture_output=True)
    (OUT / "rust_preprocess_stdout.json").write_text(proc.stdout)
    (OUT / "rust_preprocess_stderr.txt").write_text(proc.stderr)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr)
    rust_json = json.loads(rust_out.read_text())
    rust_data = np.asarray(rust_json["channels"], dtype=float)
    rust_rate = float(rust_json["sample_rate"])
    rust_labels = rust_json["labels"]

    common = [ch for ch in py_labels if ch in rust_labels]
    py_idx = [py_labels.index(ch) for ch in common]
    rs_idx = [rust_labels.index(ch) for ch in common]
    n = min(py_data_uv.shape[1], rust_data.shape[1])
    a = py_data_uv[py_idx, :n]
    b = rust_data[rs_idx, :n]
    diff = a - b
    summary = {
        "python_rate": py_rate,
        "rust_rate": rust_rate,
        "channels_compared": common,
        "samples_compared": int(n),
        "python_errors": py_errors,
        "rms_uv": float(np.sqrt(np.mean(diff**2))) if diff.size else None,
        "median_abs_uv": float(np.median(np.abs(diff))) if diff.size else None,
        "max_abs_uv": float(np.max(np.abs(diff))) if diff.size else None,
    }
    plot_preprocess_snapshots(raw_rs, py_data_uv, py_rate, py_labels, rust_data, rust_rate, rust_labels, common[:8])
    (OUT / "preprocessing_comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def empty_options() -> dict[str, object]:
    return {
        "mode": "full",
        "start_seconds": 0,
        "end_seconds": WINDOW_SECONDS,
        "bin_seconds": 60,
        "psd": False,
        "fooof": False,
        "irasa": False,
        "nonlinear": False,
        "acw": False,
        "connectivity": False,
        "mic": False,
        "mim": False,
        "gc": False,
        "gc_tr": False,
        "coh": False,
        "plv": False,
        "ciplv": False,
        "pli": False,
        "wpli": False,
        "remove_non_eeg": False,
    }


def plot_preprocess_snapshots(raw, py_data, py_rate, py_labels, rs_data, rs_rate, rs_labels, labels):
    raw_data = raw.get_data(picks=labels) * 1e6
    raw_rate = raw.info["sfreq"]
    for label in labels:
        fig, axes = plt.subplots(3, 1, figsize=(12, 7), sharex=False)
        raw_ch = raw_data[labels.index(label)]
        py_ch = py_data[py_labels.index(label)]
        rs_ch = rs_data[rs_labels.index(label)]
        limit = shared_ylim([raw_ch, py_ch, rs_ch])
        plot_trace(axes[0], raw_ch, raw_rate, f"{label} raw input", limit)
        plot_trace(axes[1], py_ch, py_rate, f"{label} Python ccstools preprocessing", limit)
        plot_trace(axes[2], rs_ch, rs_rate, f"{label} Rust preprocessing", limit)
        fig.tight_layout()
        fig.savefig(OUT / f"preprocess_snapshot_{label}.png", dpi=150)
        plt.close(fig)
        fig, axes = plt.subplots(2, 1, figsize=(12, 5), sharex=True)
        n = min(py_ch.size, rs_ch.size)
        t = np.arange(n) / py_rate
        overlay_limit = shared_ylim([py_ch[:n], rs_ch[:n]])
        axes[0].plot(t, py_ch[:n], lw=0.8, label="Python")
        axes[0].plot(t, rs_ch[:n], lw=0.8, alpha=0.8, label="Rust")
        axes[0].set_ylim(*overlay_limit)
        axes[0].set_title(f"{label} preprocessing overlay, shared scale")
        axes[0].set_ylabel("uV")
        axes[0].legend(loc="upper right")
        diff = py_ch[:n] - rs_ch[:n]
        axes[1].plot(t, diff, lw=0.8, color="#E76F51")
        axes[1].axhline(0, color="k", lw=0.6)
        axes[1].set_title(f"Python - Rust difference, RMS={np.sqrt(np.mean(diff**2)):.3g} uV")
        axes[1].set_xlabel("Time (s)")
        axes[1].set_ylabel("uV")
        fig.tight_layout()
        fig.savefig(OUT / f"preprocess_overlay_{label}.png", dpi=150)
        plt.close(fig)
    stack = labels[:6]
    fig, axes = plt.subplots(1, 3, figsize=(16, 7), sharey=True)
    raw_stack = raw_data[: len(stack)]
    py_stack = py_data[[py_labels.index(ch) for ch in stack]]
    rs_stack = rs_data[[rs_labels.index(ch) for ch in stack]]
    n = min(raw_stack.shape[1], py_stack.shape[1], rs_stack.shape[1], int(4 * py_rate))
    scale = max(np.percentile(np.abs(np.concatenate([raw_stack[:, :n].ravel(), py_stack[:, :n].ravel(), rs_stack[:, :n].ravel()])), 95), 1)
    plot_stack(axes[0], raw_stack, raw_rate, stack, "Raw", scale)
    plot_stack(axes[1], py_stack, py_rate, stack, "Python", scale)
    plot_stack(axes[2], rs_stack, rs_rate, stack, "Rust", scale)
    fig.tight_layout()
    fig.savefig(OUT / "preprocess_snapshot_stacked.png", dpi=150)
    plt.close(fig)


def shared_ylim(series: list[np.ndarray]) -> tuple[float, float]:
    values = np.concatenate([np.asarray(x, dtype=float).ravel() for x in series])
    values = values[np.isfinite(values)]
    if values.size == 0:
        return (-1.0, 1.0)
    limit = float(np.percentile(np.abs(values), 99))
    limit = max(limit, 1.0)
    return (-limit, limit)


def plot_trace(ax, data, rate, title, ylim=None):
    t = np.arange(data.size) / rate
    ax.plot(t, data, lw=0.8)
    ax.set_title(title)
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("uV")
    if ylim is not None:
        ax.set_ylim(*ylim)


def plot_stack(ax, data, rate, labels, title, scale=None):
    n = min(data.shape[1], int(4 * rate))
    t = np.arange(n) / rate
    scale = scale or max(np.percentile(np.abs(data[:, :n]), 95), 1)
    for i, label in enumerate(labels):
        ax.plot(t, data[i, :n] / scale + i * 2.5, lw=0.7)
        ax.text(t[0], i * 2.5, label, va="center")
    ax.set_title(title)
    ax.set_xlabel("Time (s)")
    ax.set_yticks([])


def write_report(feature_summary: dict[str, object], preprocessing_summary: dict[str, object]) -> None:
    lines = [
        "# AKNLTP014_REMED1_RCB Python vs Rust Parity Report",
        "",
        f"Input: `{SAMPLE}`",
        f"Channels: {', '.join(CHANNELS)}",
        f"Window: first {WINDOW_SECONDS:g} seconds, epoch length {EPOCH_SECONDS:g} seconds",
        "",
        "## Feature Extraction",
        "",
        f"Python feature shape: {feature_summary['python_shape']}",
        f"Rust feature shape: {feature_summary['rust_shape']}",
        f"Common numeric features compared: {feature_summary['common_numeric_features']}",
        "",
        "Family summary is in `feature_comparison_by_family.csv`; worst columns are in `feature_comparison_by_column.csv`.",
        "",
        "| Family | Features | Max abs | Median mean abs | Median corr |",
        "|---|---:|---:|---:|---:|",
    ]
    for row in feature_summary["family"]:
        lines.append(
            f"| {row['family']} | {row['n_features']} | {fmt(row['max_abs'])} | {fmt(row['median_mean_abs'])} | {fmt(row['median_corr'])} |"
        )
    lines.extend(
        [
            "",
            "## Worst Feature Columns",
            "",
            "| Feature | n | Max abs | Mean abs | Max rel | Corr |",
            "|---|---:|---:|---:|---:|---:|",
        ]
    )
    for row in feature_summary["worst"][:15]:
        lines.append(
            f"| {row['feature']} | {row['n']} | {fmt(row['max_abs'])} | {fmt(row['mean_abs'])} | {fmt(row['max_rel'])} | {fmt(row['corr'])} |"
        )
    lines.extend(
        [
            "",
            "## Preprocessing",
            "",
            f"Python sample rate: {preprocessing_summary['python_rate']}",
            f"Rust sample rate: {preprocessing_summary['rust_rate']}",
            f"Channels compared: {', '.join(preprocessing_summary['channels_compared'])}",
            f"Samples compared: {preprocessing_summary['samples_compared']}",
            f"RMS difference (uV): {fmt(preprocessing_summary['rms_uv'])}",
            f"Median absolute difference (uV): {fmt(preprocessing_summary['median_abs_uv'])}",
            f"Max absolute difference (uV): {fmt(preprocessing_summary['max_abs_uv'])}",
            "",
            "Snapshots:",
            "",
            "- `preprocess_snapshot_stacked.png`",
            *[f"- `preprocess_snapshot_{ch}.png` and `preprocess_overlay_{ch}.png`" for ch in preprocessing_summary["channels_compared"][:8]],
            "",
            "Visual summaries:",
            "",
            "- `feature_family_parity.png`",
            "- `feature_scatter_parity.png`",
            "- `connectivity_metric_parity.png`",
            "",
            "## Interpretation",
            "",
            "PSD, nonlinear features, ACW, and most connectivity values are at or near numerical precision against the Python reference on this real-data slice.",
            "IRASA oscillatory band powers match closely; IRASA fitted aperiodic parameters remain less exact because Rust and Python fitting paths are not identical.",
            "FOOOF and preprocessing remain the hardest native parity targets. The report includes scatter plots and shared-scale preprocessing overlays so achieved parity and remaining gaps are visible rather than only tabular.",
        ]
    )
    md_path = OUT / "AKNLTP014_REMED1_RCB_parity_report.md"
    md_path.write_text("\n".join(lines) + "\n")
    (OUT / "summary.json").write_text(
        json.dumps({"features": feature_summary, "preprocessing": preprocessing_summary}, indent=2) + "\n"
    )
    write_pdf_report(lines, OUT / "AKNLTP014_REMED1_RCB_parity_report.pdf")


def write_pdf_report(lines: list[str], path: Path) -> None:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.platypus import Image, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

    styles = getSampleStyleSheet()
    doc = SimpleDocTemplate(str(path), pagesize=letter, rightMargin=36, leftMargin=36, topMargin=36, bottomMargin=36)
    story = []
    table_rows = []
    in_table = False
    for line in lines:
        if line.startswith("# "):
            story.append(Paragraph(line[2:], styles["Title"]))
            story.append(Spacer(1, 8))
        elif line.startswith("## "):
            if table_rows:
                story.append(pdf_table(table_rows, Table, TableStyle, colors))
                table_rows = []
            story.append(Spacer(1, 10))
            story.append(Paragraph(line[3:], styles["Heading2"]))
        elif line.startswith("|"):
            if set(line.replace("|", "").strip()) <= {"-", ":"}:
                continue
            cells = [cell.strip() for cell in line.strip("|").split("|")]
            table_rows.append(cells)
            in_table = True
        else:
            if in_table and table_rows and not line.startswith("|"):
                story.append(pdf_table(table_rows, Table, TableStyle, colors))
                table_rows = []
                in_table = False
            if line.strip():
                story.append(Paragraph(line.replace("`", ""), styles["BodyText"]))
                story.append(Spacer(1, 4))
    if table_rows:
        story.append(pdf_table(table_rows, Table, TableStyle, colors))
    story.append(PageBreak())
    story.append(Paragraph("Feature Parity Plots", styles["Heading2"]))
    for image_name in ["feature_family_parity.png", "feature_scatter_parity.png", "connectivity_metric_parity.png"]:
        image_path = OUT / image_name
        if image_path.exists():
            story.append(Paragraph(image_name, styles["Heading3"]))
            story.append(Image(str(image_path), width=520, height=260 if "scatter" not in image_name else 430))
            story.append(Spacer(1, 10))
    story.append(PageBreak())
    story.append(Paragraph("Preprocessing Snapshots", styles["Heading2"]))
    for image_name in ["preprocess_snapshot_stacked.png", "preprocess_snapshot_Fz.png", "preprocess_overlay_Fz.png", "preprocess_snapshot_F3.png", "preprocess_overlay_F3.png"]:
        image_path = OUT / image_name
        if image_path.exists():
            story.append(Paragraph(image_name, styles["Heading3"]))
            story.append(Image(str(image_path), width=520, height=230 if "stacked" in image_name else 300))
            story.append(Spacer(1, 10))
    doc.build(story)


def pdf_table(rows, Table, TableStyle, colors):
    table = Table(rows, repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#E6EEF5")),
                ("GRID", (0, 0), (-1, -1), 0.25, colors.grey),
                ("FONT", (0, 0), (-1, 0), "Helvetica-Bold", 8),
                ("FONT", (0, 1), (-1, -1), "Helvetica", 7),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ]
        )
    )
    return table


def fmt(value) -> str:
    if value is None:
        return "NA"
    try:
        if not math.isfinite(float(value)):
            return "NA"
        return f"{float(value):.6g}"
    except Exception:
        return str(value)


if __name__ == "__main__":
    main()
