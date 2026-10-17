"""Read-only raw/cleaned ERP and timing audit; outputs go into workspace output/."""
import os
os.environ.setdefault('NUMBA_DISABLE_JIT','1')
os.environ.setdefault('_MNE_FAKE_HOME_DIR','/tmp/ccs-mne-validation')
os.environ.setdefault('MPLCONFIGDIR','/tmp/ccs-mpl-cache')
import argparse,json
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly, correlate, correlation_lags
import mne
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

p=argparse.ArgumentParser();p.add_argument('folder',type=Path);p.add_argument('--output',type=Path,default=Path('output/pallavi_timing_audit'));args=p.parse_args()
root=args.folder;args.output.mkdir(parents=True,exist_ok=True)
def existing(*names):
    return next(root/n for n in names if (root/n).exists())
clean_path=existing('Pallavi_Task_Pre_2_clean.ccseeg','Pallavi_Task_Pre_2_clean.ccseeg.json')
clean=json.loads(clean_path.read_text());side_path=next(Path(str(clean_path)+s) for s in ['.ccshistory','.preprocessing.json'] if Path(str(clean_path)+s).exists());side=json.loads(side_path.read_text())
raw=mne.io.read_raw_brainvision(root/'Pallavi_Task_Pre_2.vhdr',preload=True,verbose='ERROR')
fs=clean['sample_rate'];ci=clean['labels'].index('Pz');y=np.asarray(clean['channels'][ci]);original=resample_poly(raw.get_data(picks=['Pz'])[0]*1e6,1,4)
report={'raw_rate':raw.info['sfreq'],'saved_rate':fs,'raw_samples':int(raw.n_times),'saved_samples':len(y),'local_lags':[],'conditions':{}}
for t in [30,300,600,900,1100]:
 a=original[int(t*fs):int((t+10)*fs)];b=y[int(t*fs):int((t+10)*fs)]
 c=correlate(b-b.mean(),a-a.mean());lags=correlation_lags(len(b),len(a));sel=abs(lags)<fs
 report['local_lags'].append({'time_s':t,'samples':int(lags[sel][np.argmax(c[sel])])})
# Match saved filtering to independent zero-phase filtering; no artifact removal.
filtered=raw.copy().pick(['Pz']).filter(.5,40.,verbose='ERROR').notch_filter([50.],verbose='ERROR').resample(fs,verbose='ERROR').get_data()[0]*1e6
fig,axes=plt.subplots(2,2,figsize=(12,7),sharex=True);times=np.arange(-125,376)/fs
for ax,(code,name) in zip(axes.flat,[('S10','Standard'),('S20','Neutral'),('S30','Pleasant'),('S40','Unpleasant')]):
 onsets=[m['start_seconds'] for m in side['markers'] if m.get('description','').replace(' ','')==code]
 def epochs(signal):
  trials=[]
  for t in onsets:
   a=round(t*fs)-125;b=a+501
   if a>=0 and b<=len(signal):
    trial=signal[a:b].copy();trial-=trial[75:126].mean();trials.append(trial)
  return np.asarray(trials)
 a=epochs(filtered);b=epochs(y);ma=a.mean(0);mb=b.mean(0)
 ax.plot(times*1000,ma,label='Independent filter only',lw=1.1);ax.plot(times*1000,mb,label='Saved ICA cleaned',lw=1.1)
 ax.axvline(0,color='k',lw=.8);ax.axhline(0,color='gray',lw=.6);ax.set_title(f'{name} · {len(b)} trials');ax.set_ylabel('Pz (µV)');ax.set_xlabel('Time (ms)');ax.legend(fontsize=8);ax.grid(alpha=.2)
 report['conditions'][name]={'trials':len(b),'filtered_peak_abs_uv':float(abs(ma).max()),'cleaned_peak_abs_uv':float(abs(mb).max()),'mean_waveform_correlation':float(np.corrcoef(ma,mb)[0,1])}
fig.suptitle('Pallavi: independently event-locked averages (no sign reversal or smoothing)');fig.tight_layout();fig.savefig(args.output/'raw_vs_cleaned_erp.png',dpi=160);plt.close(fig)
# Saved epochs should equal continuous slices, apart from baseline and sample rounding.
epoch_path=existing('P300_v01.ccseeg','P300_v01.json');e=json.loads(epoch_path.read_text());n=e['source_epoch_samples'];a=np.asarray(e['channels'][e['labels'].index('Pz')]);corr=[]
for i,start in enumerate(e.get('epoch_start_seconds',[])):
 j=round(start*fs);expected=y[j:j+n];actual=a[i*n:(i+1)*n]
 if len(expected)==n and np.std(expected)>0 and np.std(actual)>0:corr.append(float(np.corrcoef(expected,actual)[0,1]))
report['saved_epoch_correlations']={'count':len(corr),'minimum':min(corr),'median':float(np.median(corr))}
(args.output/'audit.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
