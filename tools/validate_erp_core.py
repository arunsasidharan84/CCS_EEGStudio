"""Independently validate native ERP CORE condition waveforms against MNE/NumPy.
Set NUMBA_DISABLE_JIT=1 and _MNE_FAKE_HOME_DIR to a writable temp directory.
"""
import os,sys,pathlib,json,csv,math
os.environ.setdefault('NUMBA_DISABLE_JIT','1')
import numpy as np
import mne

def round_away(x):return int(math.floor(x+.5) if x>=0 else math.ceil(x-.5))
def classes(task):
 if task=='MMN':return {80},{70}
 if task=='N170':return set(range(41,81)),set(range(1,41))
 if task=='N2pc':return {111,112,211,212},{121,122,221,222}
 if task=='N400':return {211,212},{221,222}
 if task=='P3':return {10*a+b for a in range(1,6) for b in range(1,6) if a!=b},{11,22,33,44,55}
 if task=='LRP':return {111,121},{212,222}
 if task=='ERN':return {111,121,212,222},{112,122,211,221}
 raise ValueError(task)

def main(path):
 result=json.loads(pathlib.Path(path).read_text());checks=[]
 for f in result['files']:
  raw=mne.io.read_raw_edf(f['path'],preload=False,verbose=False);sf=raw.info['sfreq'];p=f['profile'];a_codes,b_codes=classes(f['task']);indices=[raw.ch_names.index(next(x for x in raw.ch_names if x.upper()==r.upper())) for r in p['roi']]
  # Rust stores calibrated EEG samples as f32 before double-precision epoch math.
  data=(raw.get_data(picks=indices)*1e6).astype('float32').astype('float64')
  with open(pathlib.Path(f['path']).with_suffix('.evt')) as stream:events=[(int(e['type']),float(e['latency'])) for e in csv.DictReader(stream,delimiter='\t')]
  start,stop=map(lambda t:round_away(t*sf),p['epoch']);times=np.arange(start,stop+1)/sf;baseline=(times>=p['baseline'][0]-1e-10)&(times<=p['baseline'][1]+1e-10);a=[];b=[];counts=[0,0]
  for i,(code,onset) in enumerate(events):
   if code not in a_codes|b_codes:continue
   k=int(code in b_codes)
   if f['task'] not in ['MMN','LRP','ERN']:
    response=next(((c,t) for c,t in events[i+1:] if t-onset<=1. and c in [201,202]),None)
    if response is None or response[0]!=201 or response[1]-onset<.2:continue
   e=round_away(onset*sf)
   if e+start<0 or e+stop>=data.shape[1]:continue
   trial=data[:,e+start:e+stop+1].copy();trial-=trial[:,baseline].mean(1)[:,None];counts[k]+=1
   if p['lateralized']:a.append(trial[k]);b.append(trial[1-k])
   elif k==0:a.append(trial.mean(0))
   else:b.append(trial.mean(0))
  ma=np.mean(a,0);mb=np.mean(b,0);da=float(np.max(np.abs(ma-np.asarray(f['a']))));db=float(np.max(np.abs(mb-np.asarray(f['b']))))
  assert counts==[f['n_a'],f['n_b']],(f['task'],counts,f['n_a'],f['n_b'])
  assert max(da,db)<2e-5,(f['task'],da,db)
  checks.append(dict(task=f['task'],subject=f['subject'],n_a=counts[0],n_b=counts[1],max_abs_waveform_error_uv=max(da,db)))
  print(checks[-1],flush=True)
 output=pathlib.Path(path).parent/'mne_numpy_validation.json';output.write_text(json.dumps(dict(mne=mne.__version__,numpy=np.__version__,checks=checks),indent=2)+'\n');print(output)
if __name__=='__main__':main(sys.argv[1])
