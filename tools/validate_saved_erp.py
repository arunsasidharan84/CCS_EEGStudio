"""Independent NumPy check of the user's saved response-locked ERN epochs."""
import json,sys,pathlib
import numpy as np
r=json.loads(pathlib.Path(sys.argv[1]).read_text());f=r['files'][0];raw=json.loads(pathlib.Path(f['path']).read_text());side=json.loads(pathlib.Path(f['path']+'.preprocessing.json').read_text());rate=raw['sample_rate'];start=raw['epoch_tmin'];n=raw['source_epoch_samples'];codes={}
for m in side['markers']:
 if abs(m['start_seconds']+start)<=2/rate:codes.setdefault(m['epoch_index'],m['description'])
a={'111','121','212','222'};b={'112','122','211','221'}
x=np.array(raw['channels'][raw['labels'].index('FCz')],dtype='float32').astype('float64').reshape(-1,n);times=np.arange(n)/rate+start;base=(times>=f['profile']['baseline'][0]-1e-10)&(times<=f['profile']['baseline'][1]+1e-10);x=x-x[:,base].mean(1)[:,None]
checks={}
for key,which in [('a',a),('b',b)]:
 idx=[i for i in range(len(x)) if codes.get(i) in which];error=float(np.max(abs(x[idx].mean(0)-np.array(f[key]))));assert len(idx)==f['n_'+key];assert error<1e-10;checks[key]={'trials':len(idx),'maximum_waveform_error_uv':error}
out=pathlib.Path(sys.argv[1]).parent/'numpy_saved_epoch_validation.json';out.write_text(json.dumps(checks,indent=2)+'\n');print(checks)
