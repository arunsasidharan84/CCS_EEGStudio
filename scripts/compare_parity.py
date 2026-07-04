import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import argparse
from pathlib import Path
import math

def compare_results(python_csv, rust_csv, out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    
    print(f"Loading Python CSV: {python_csv}")
    df_py = pd.read_csv(python_csv)
    print(f"Loading Rust CSV: {rust_csv}")
    df_rs = pd.read_csv(rust_csv)
    
    # We want to match rows based on Epoch and Chan
    # But wait, in python script the column might be 'Chan' but let's check its name. 
    # Usually it's 'Chan' and 'Epoch'.
    # If the python script names them 'Chan' and 'Epoch', great.
    # The rust engine uses 'Chan' and 'Epoch'.
    
    df_py['Epoch'] = df_py['Epoch'].astype(int)
    df_rs['Epoch'] = df_rs['Epoch'].astype(int)
    
    # In python ccstools, the channel column is "Chan" (with index or string) or "channels" depending on how it's saved.
    # Let's hope it's "Chan" for both. Actually ccstools uses "Chan".
    
    df_py['Chan'] = df_py['Chan'].astype(str)
    df_rs['Chan'] = df_rs['Chan'].astype(str)
    
    # Set index
    df_py.set_index(['Epoch', 'Chan'], inplace=True)
    df_rs.set_index(['Epoch', 'Chan'], inplace=True)
    
    # Find common columns
    numeric_cols = df_rs.select_dtypes(include=[np.number]).columns
    common_cols = [c for c in numeric_cols if c in df_py.columns and c not in ['bin_idx', 'bin_start_s', 'bin_end_s', 'mode']]
    
    if not common_cols:
        print("No common numeric columns found!")
        return
        
    print(f"Found {len(common_cols)} common features to compare.")
    
    metrics = []
    
    # Plot settings
    plt.style.use('dark_background')
    
    for col in common_cols:
        try:
            # Join data to ensure exact matching
            joined = df_py[[col]].join(df_rs[[col]], lsuffix='_py', rsuffix='_rs').dropna()
            if len(joined) == 0:
                print(f"Skipping {col}: No matching non-NaN data.")
                continue
                
            y_py = joined[f"{col}_py"].values
            y_rs = joined[f"{col}_rs"].values
            
            # calculate pearson r
            if np.std(y_py) == 0 or np.std(y_rs) == 0:
                r = np.nan
            else:
                r = np.corrcoef(y_py, y_rs)[0, 1]
                
            mse = np.mean((y_py - y_rs)**2)
            mae = np.mean(np.abs(y_py - y_rs))
            max_err = np.max(np.abs(y_py - y_rs))
            
            metrics.append({
                "Feature": col,
                "r": r,
                "MAE": mae,
                "MaxError": max_err
            })
            
            # Plot
            fig, ax = plt.subplots(figsize=(6, 6))
            ax.scatter(y_py, y_rs, alpha=0.5, s=10, color='cyan')
            
            # Add identity line
            min_val = min(np.min(y_py), np.min(y_rs))
            max_val = max(np.max(y_py), np.max(y_rs))
            if math.isfinite(min_val) and math.isfinite(max_val):
                ax.plot([min_val, max_val], [min_val, max_val], 'r--', lw=2, label='y=x')
            
            ax.set_xlabel("Python / MATLAB")
            ax.set_ylabel("Dart / Rust Engine")
            ax.set_title(f"{col}\n$r$ = {r:.4f}, Max Err = {max_err:.4e}")
            ax.legend()
            ax.grid(True, alpha=0.2)
            
            fig.tight_layout()
            out_file = out_dir / f"{col}.png"
            fig.savefig(out_file, dpi=100)
            plt.close(fig)
            
        except Exception as e:
            print(f"Error plotting {col}: {e}")
            
    df_metrics = pd.DataFrame(metrics)
    metrics_csv = out_dir / "metrics_summary.csv"
    df_metrics.to_csv(metrics_csv, index=False)
    print(f"Metrics saved to {metrics_csv}")
    print("All plots generated!")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--py", required=True, help="Python CSV output")
    parser.add_argument("--rs", required=True, help="Rust CSV output")
    parser.add_argument("--outdir", required=True, help="Output directory for snapshots")
    args = parser.parse_args()
    
    compare_results(args.py, args.rs, args.outdir)
