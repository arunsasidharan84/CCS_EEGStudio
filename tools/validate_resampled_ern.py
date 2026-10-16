"""Independent MNE/SciPy check of corrected downsampling and response alignment.
Usage: python3 tools/validate_resampled_ern.py SOURCE.edf RESULTS.json
"""
import os, sys, json, csv, math
from fractions import Fraction
from pathlib import Path
os.environ.setdefault('NUMBA_DISABLE_JIT','1')
import numpy as np
import mne
from scipy.signal import resample_poly

def rounded(x):
    return int(math.floor(x+.5) if x >= 0 else math.ceil(x-.5))

def main(source, result_path):
    result=json.loads(Path(result_path).read_text())['files'][0]
    profile=result['profile'];times=np.array(result['times']);rate=1/(times[1]-times[0])
    raw=mne.io.read_raw_edf(source,preload=False,verbose=False)
    ratio=Fraction(rate/raw.info['sfreq']).limit_denominator(1000000)
    data=(raw.get_data(picks=profile['roi'])*1e6).astype('float32').astype('float64')
    data=resample_poly(data,ratio.numerator,ratio.denominator,axis=1)
    with Path(source).with_suffix('.evt').open() as f:events=list(csv.DictReader(f,delimiter='\t'))
    side=json.loads(Path(result['path']+'.preprocessing.json').read_text())
    prebase=side['preprocessing']['stim_epochs_spec']['baseline']
    mask=(times >= profile['baseline'][0]-1e-9)&(times <= profile['baseline'][1]+1e-9)
    pre=(times>=prebase[0]-1e-9)&(times<=prebase[1]+1e-9)
    groups={'a':{'111','121','212','222'},'b':{'112','122','211','221'}};checks={}
    for name,codes in groups.items():
        trials=[]
        for e in events:
            if e['type'].strip() not in codes:continue
            start=rounded(float(e['latency'])*rate)+rounded(times[0]*rate)
            x=data[:,start:start+len(times)].copy()
            if x.shape[1]!=len(times):continue
            x-=x[:,pre].mean(1)[:,None]
            x=x.astype('float32').astype('float64')
            x-=x[:,mask].mean(1)[:,None]
            trials.append(x.mean(0))
        expected=np.mean(trials,axis=0)
        error=float(np.max(np.abs(expected-np.array(result[name]))))
        assert len(trials)==result['n_'+name]
        assert error<1e-4,(name,error)
        checks[name]={'trials':len(trials),'max_error_uv':error}
    report={'source':source,'ratio':[ratio.numerator,ratio.denominator],'rate_hz':rate,'checks':checks}
    Path(result_path).with_name('scipy_resampling_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main(*sys.argv[1:])
