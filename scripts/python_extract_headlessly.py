import os
import pandas as pd
import mne
import numpy as np
import sys
import argparse
from pathlib import Path

# Set the path to where ccstools is located
sys.path.append("/Users/arunsasidharan/Code/ActiveProjects/ccs_toolbox")
from ccstools.eegfeatures import generate_multieegfeatures

def extract(filepath, output_dir):
    filepath = str(filepath)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    name_noext = Path(filepath).stem
    outfilename = output_dir / f"{name_noext}_python_parity.csv"
    
    selected_features = ["psd", "fooof", "irasa", "nonlinear", "acw"]
    Freq_Bands = [(1, 4, 'Delta'), (4, 8, 'Theta'), (6, 10, 'ThetaAlpha'),
                  (8, 12, 'Alpha'), (12, 18, 'Beta1'), (18, 30, 'Beta2'), (30, 40, 'Gamma1')]

    try:
        print(f"Loading {filepath} in MNE...")
        try:
            epochs = mne.io.read_epochs_eeglab(filepath, verbose=False)
        except ValueError:
            raw = mne.io.read_raw_eeglab(filepath, preload=True, verbose=False)
            epochs = mne.make_fixed_length_epochs(raw, duration=2.0, preload=True, verbose=False)
            
        non_eeg_channels = ["GSR", "ECG", "EOG", "EMG", "RESP", "X_DIR", "Y_DIR", "Z_DIR"]
        to_remove = [ch for ch in epochs.ch_names if any(x in ch.upper() for x in non_eeg_channels)]
        if to_remove:
            epochs.drop_channels(to_remove)
            
        epochs.set_eeg_reference(verbose=False)
        srate = epochs.info.get("sfreq")
        chanlist = epochs.ch_names
        
        epoch_len = (epochs.tmax - epochs.tmin)
        n_epochs_total = len(epochs)
        
        # Use full recording mode
        epoch_indices_groups = [np.arange(n_epochs_total)]
        bin_meta = [(0, 0.0, n_epochs_total * epoch_len)]
        
        all_features = pd.DataFrame()
        
        for g_idx, idx_group in enumerate(epoch_indices_groups):
            ep_sel = epochs[idx_group]
            print(f"Extracting features for {len(idx_group)} epochs...")
            
            df = generate_multieegfeatures(
                ep_sel._data * 1e6, srate, chanlist,
                featurelist=selected_features,
                psdtype="welch",
                kwargs_psd=dict(scaling="density", average="median", window="hamming",
                                nperseg=int(srate * 1)),
                freq_range=[1, 50],
                bands=Freq_Bands
            )
            
            # Connectivity Extraction
            import mne_connectivity as mnecon
            con_m_types = ['mic', 'mim', 'gc', 'gc_tr']
            con_u_types = ['coh', 'plv', 'ciplv', 'pli', 'wpli']
            
            fmin, fmax = 4, Freq_Bands[-1][1]
            freqs = np.logspace(np.log10(fmin), np.log10(fmax), 15)
            freqcycles = np.logspace(np.log10(3), np.log10(fmax / 2), len(freqs)).astype(int)

            # Multivariate
            seeds = [x for x, y in enumerate(chanlist) if 'F' in y[0]]
            targets = [x for x, y in enumerate(chanlist) if ('P' in y[0] or 'O' in y[0])]
            multivar_indices = ([seeds], [targets])

            df1 = pd.DataFrame()
            try:
                con_m = mnecon.spectral_connectivity_time(
                    ep_sel, method=con_m_types, indices=multivar_indices,
                    rank=None, gc_n_lags=25, freqs=freqs,
                    faverage=False, n_cycles=freqcycles, mode='cwt_morlet',
                    sfreq=srate, fmin=fmin, fmax=fmax, n_jobs=1
                )

                for con_no, mtype in enumerate(con_m_types):
                    con_dataall = con_m[con_no].get_data()
                    con_dataall = np.repeat(con_dataall, len(chanlist), axis=1)
                    con_dataall = con_dataall.reshape([con_dataall.shape[0] * con_dataall.shape[1], con_dataall.shape[2]])
                    bands2use = Freq_Bands[1:]
                    con_databand = np.zeros([con_dataall.shape[0], len(bands2use)])
                    for band_no, band in enumerate(bands2use):
                        con_databand[:, band_no] = np.mean(
                            con_dataall[:, np.logical_and(freqs >= band[0], freqs <= band[1])], axis=1
                        )
                    df_part = pd.DataFrame(data=con_databand, columns=[f'conn_{mtype}_{x[-1]}' for x in bands2use])
                    df1 = df_part if df1.empty else pd.concat([df1, df_part], axis=1)
            except Exception as e:
                print(f"Skipping multivariate connectivity due to error: {e}")
            
            df = pd.concat([df, df1], axis=1) if not df1.empty else df

            # Univariate
            con_u = mnecon.spectral_connectivity_time(
                ep_sel, method=con_u_types, freqs=freqs,
                faverage=False, n_cycles=freqcycles, mode='cwt_morlet',
                sfreq=srate, fmin=fmin, fmax=fmax, n_jobs=1
            )
            df2 = pd.DataFrame()
            for con_no, mtype in enumerate(con_u_types):
                con_dataall = con_u[con_no].get_data()
                con_dataall = con_dataall.transpose([1, 0, 2]).reshape(
                    [len(chanlist), len(chanlist), con_dataall.shape[0], con_dataall.shape[-1]]
                )
                con_dataall = (np.nansum(con_dataall, axis=0) + np.nansum(con_dataall, axis=1)) / len(chanlist)
                con_dataall = con_dataall.transpose([1, 0, 2])
                con_dataall = con_dataall.reshape([con_dataall.shape[0] * con_dataall.shape[1], con_dataall.shape[2]])
                bands2use = Freq_Bands[1:]
                con_databand = np.zeros([con_dataall.shape[0], len(bands2use)])
                for band_no, band in enumerate(bands2use):
                    con_databand[:, band_no] = np.mean(
                        con_dataall[:, np.logical_and(freqs >= band[0], freqs <= band[1])], axis=1
                    )
                df_part = pd.DataFrame(data=con_databand, columns=[f'conn_{mtype}_{x[-1]}' for x in bands2use])
                df2 = df_part if df2.empty else pd.concat([df2, df_part], axis=1)
            
            df = pd.concat([df, df2], axis=1)
            
            filenameinfo = name_noext.split("_")
            df["filename"] = name_noext
            df["subjid"] = filenameinfo[0] if len(filenameinfo) > 0 else "NA"
            df["sessn"] = filenameinfo[1] if len(filenameinfo) > 1 else "NA"
            df["condn"] = filenameinfo[2] if len(filenameinfo) > 2 else "NA"
            
            b_idx, b_start, b_end = bin_meta[g_idx]
            df["bin_idx"] = b_idx
            df["bin_start_s"] = round(b_start, 3)
            df["bin_end_s"] = round(b_end, 3)
            df["mode"] = "full"
            
            all_features = pd.concat([all_features, df], axis=0) if not all_features.empty else df
            
        if not all_features.empty:
            all_features.to_csv(outfilename, index=False)
            print(f"✅ Saved results to {outfilename}")
        else:
            print("⚠ No features extracted, nothing to save.")
    except Exception as e:
        print(f"⚠ Error processing {filepath}: {e}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Input .set file")
    parser.add_argument("--outdir", required=True, help="Output directory")
    args = parser.parse_args()
    
    extract(args.input, args.outdir)
