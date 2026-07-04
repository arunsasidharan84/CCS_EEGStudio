import json
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path
import argparse
import sys

def compare_gedai(py_npy, py_json, rs_json, outdir):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    
    print(f"Loading Python GEDAI output from {py_npy}...")
    py_data = np.load(py_npy)
    with open(py_json, "r") as f:
        py_meta = json.load(f)
    py_labels = py_meta["labels"]
    py_rate = py_meta["sample_rate"]
    
    # MNE loads data in Volts. Convert to microvolts to match Rust EEGLAB loader
    py_data = py_data * 1e6
    
    print(f"Loading Rust GEDAI output from {rs_json}...")
    with open(rs_json, "r") as f:
        rs_full = json.load(f)
    rs_data = np.array(rs_full["channels"])
    rs_labels = rs_full["labels"]
    rs_rate = rs_full["sample_rate"]
    
    # We only care about intersecting channels for metrics
    common = [ch for ch in py_labels if ch in rs_labels]
    py_idx = [py_labels.index(ch) for ch in common]
    rs_idx = [rs_labels.index(ch) for ch in common]
    
    # Trim to shortest length
    n = min(py_data.shape[1], rs_data.shape[1], int(py_rate * 300))  # Max 300s compare
    a = py_data[py_idx, :n]
    b = rs_data[rs_idx, :n]
    diff = a - b
    
    rms_uv = float(np.sqrt(np.mean(diff**2)))
    max_uv = float(np.max(np.abs(diff)))
    
    print(f"\n==============================")
    print(f"GEDAI Signal Parity Results:")
    print(f"Channels compared: {len(common)}")
    print(f"Samples compared: {n}")
    print(f"RMS Error: {rms_uv:.6f} µV")
    print(f"Max Absolute Error: {max_uv:.6f} µV")
    if "sensai_score" in rs_full:
        print(f"Rust SENSAI Score: {rs_full['sensai_score']}")
    print(f"==============================\n")
    
    summary = {
        "rms_uv": rms_uv,
        "max_uv": max_uv,
        "channels": common
    }
    with open(outdir / "gedai_parity_summary.json", "w") as f:
        json.dump(summary, f, indent=2)
        
    print("Generating signal snapshots...")
    
    time_ax = np.arange(n) / py_rate
    
    # Plot first 8 channels
    plot_channels = common[:8]
    fig, axes = plt.subplots(len(plot_channels), 1, figsize=(12, 2 * len(plot_channels)), sharex=True)
    if len(plot_channels) == 1:
        axes = [axes]
        
    # We plot the first 10 seconds
    plot_samples = int(10 * py_rate)
    time_plot = time_ax[:plot_samples]
    
    for i, ch in enumerate(plot_channels):
        ax = axes[i]
        py_ch_idx = py_labels.index(ch)
        rs_ch_idx = rs_labels.index(ch)
        
        y_py = py_data[py_ch_idx, :plot_samples]
        y_rs = rs_data[rs_ch_idx, :plot_samples]
        
        ax.plot(time_plot, y_py, color='blue', alpha=0.7, label='Python/MATLAB', linewidth=1.5)
        ax.plot(time_plot, y_rs, color='orange', alpha=0.7, label='Rust', linewidth=1.5, linestyle='--')
        
        ax.set_ylabel(ch)
        ax.legend(loc='upper right')
        ax.grid(True, alpha=0.3)
        
    axes[-1].set_xlabel("Time (seconds)")
    fig.suptitle("GEDAI Preprocessed Output Comparison (First 10 Seconds)", fontsize=16)
    fig.tight_layout()
    fig.savefig(outdir / "gedai_waveforms_10s.png", dpi=150)
    plt.close(fig)
    print("Snapshot saved: gedai_waveforms_10s.png")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--py_npy", required=True)
    parser.add_argument("--py_json", required=True)
    parser.add_argument("--rs_json", required=True)
    parser.add_argument("--outdir", required=True)
    args = parser.parse_args()
    
    compare_gedai(args.py_npy, args.py_json, args.rs_json, args.outdir)
