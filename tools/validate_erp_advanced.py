"""Compare real-data native rERP and FIR overlap coefficients to NumPy/SciPy.
Uses the separately validated accepted-event audit and MNE calibrated samples.
"""
import os,sys,pathlib,json,csv,math
os.environ.setdefault('NUMBA_DISABLE_JIT','1')
import numpy as np,mne
from scipy.sparse import coo_matrix
from scipy.sparse.linalg import lsqr
from validate_erp_core import round_away,classes

def main(path):
 result=json.loads(pathlib.Path(path).read_text());checks=[]
 for f in result['files']:
  raw=mne.io.read_raw_edf(f['path'],preload=False,verbose=False);sf=raw.info['sfreq'];p=f['profile'];c=next(i for i,l in enumerate(f['labels']) if l.upper()==p['roi'][0].upper());rawc=next(l for l in raw.ch_names if l.upper()==f['labels'][c].upper());data=(raw.get_data(picks=[rawc])[0]*1e6).astype('float32').astype('float64');dt=result['options']['bin_ms']/1000;nt=len(f['bin_times']);times=np.asarray(f['times']);base=(times>=p['baseline'][0]-1e-10)&(times<=p['baseline'][1]+1e-10);bin_id=np.clip(np.floor((times-p['epoch'][0])/dt).astype(int),0,nt-1);count=np.bincount(bin_id,minlength=nt)
  y=[]
  for event in f['accepted_events']:
   onset=round_away(event['onset_s']*sf);a=round_away(p['epoch'][0]*sf);b=round_away(p['epoch'][1]*sf);trial=data[onset+a:onset+b+1].copy();trial-=trial[base].mean();y.append(np.bincount(bin_id,weights=trial,minlength=nt)/np.maximum(1,count))
  predictors=f['regression']['predictors'];x=np.c_[np.ones(len(y)),[e['class'] for e in f['accepted_events']]]
  if len(predictors)>2:
   rt=np.array([e['rt_s'] for e in f['accepted_events']]);x=np.c_[x,rt-rt.mean()]
  beta=np.linalg.lstsq(x,np.array(y),rcond=1e-10)[0];native=np.array(f['regression']['coefficients'])[:,c,:];regerr=float(np.max(np.abs(beta-native)));assert regerr<1e-8,(f['task'],'regression',regerr)
  with open(pathlib.Path(f['path']).with_suffix('.evt')) as stream:events=[(int(e['type']),float(e['latency'])) for e in csv.DictReader(stream,delimiter='\t')]
  ac,bc=classes(f['task']);first=round_away(p['epoch'][0]/dt);last=round_away(p['epoch'][1]/dt);lags=last-first+1;nr=int(math.floor(len(data)/sf/dt));rr=list(range(nr));cc=[4*lags]*nr;vv=[1.]*nr
  for code,onset in events:
   kind=0 if code in ac else 1 if code in bc else 3 if code in [201,202] else 2 if 1<=code<=180 else None
   if f['task'] in ['ERN','LRP']:
    kind=0 if code in ac else 1 if code in bc else 2 if code in [11,12,21,22] else 3 if 100<=code<=222 else None
   if kind is None:continue
   point=round_away(onset/dt)
   for lag in range(lags):
    row=point+first+lag
    if 0<=row<nr:rr.append(row);cc.append(kind*lags+lag);vv.append(1.)
  design=coo_matrix((vv,(rr,cc)),shape=(nr,4*lags+1)).tocsr();response=np.array([data[round_away(r*dt*sf):round_away((r+1)*dt*sf)].mean() for r in range(nr)])
  fit=lsqr(design,response,atol=1e-11,btol=1e-11,iter_lim=2000)[0];actual=np.array(f['deconvolution']['coefficients'])[:,c,:].reshape(-1);err=float(np.max(np.abs(actual-fit[:-1])));assert err<1e-6,(f['task'],'FIR',err)
  # Independently reconstruct one held-out time point across every CV fold.
  from scipy.stats import rankdata
  all_data=(raw.get_data(picks=f['labels'])*1e6).astype('float32').astype('float64')
  chosen=int(np.argmin(abs(np.array(f['bin_times'])-np.mean(p['window']))));use=bin_id==chosen;features=[]
  for event in f['accepted_events']:
   onset=round_away(event['onset_s']*sf);trial=all_data[:,onset+round_away(p['epoch'][0]*sf):onset+round_away(p['epoch'][1]*sf)+1].copy();trial-=trial[:,base].mean(1)[:,None];features.append(trial[:,use].mean(1))
  features=np.array(features);labels=np.array([e['class'] for e in f['accepted_events']]);onsets=np.array([e['onset_s'] for e in f['accepted_events']]);n=len(labels);folds=result['options']['folds'];duration=len(times)/sf;aucs=[];accs=[]
  for fold in range(folds):
   a=n*fold//folds;b=n*(fold+1)//folds;test=np.arange(a,b);train=np.flatnonzero(((np.arange(n)<a)|(np.arange(n)>=b))&((onsets<onsets[a]-duration)|(onsets>onsets[b-1]+duration)));yt=labels[train];ye=labels[test]
   if any(np.sum(yt==k)<2 or not np.any(ye==k) for k in [0,1]):continue
   assert all(abs(onsets[i]-onsets[j])>duration for i in train for j in test),'overlapping train/test trials'
   x=features[train];mu=x.mean(0);sd=np.maximum(x.std(0),1e-12);z=(x-mu)/sd;means=np.stack([z[yt==k].mean(0) for k in [0,1]]);res=z-means[yt];cov=res.T@res/(len(z)-2);shrink=result['options']['decode_shrinkage'];cov=(1-shrink)*cov+np.eye(cov.shape[0])*(shrink*np.trace(cov)/cov.shape[0]+1e-12);weights=np.linalg.solve(cov,means[1]-means[0]);scores=((features[test]-mu)/sd)@weights-.5*(means[1]+means[0])@weights;n1=np.sum(ye==1);n0=np.sum(ye==0);aucs.append((rankdata(scores)[ye==1].sum()-n1*(n1+1)/2)/(n1*n0));accs.append(np.mean([np.mean((scores[ye==k]>0)==k) for k in [0,1]]))
  decode_error=max(abs(np.mean(aucs)-f['decoding']['auc'][chosen]),abs(np.mean(accs)-f['decoding']['balanced_accuracy'][chosen]));assert decode_error<1e-10,(f['task'],'held-out decoder',decode_error);assert len(aucs)==f['decoding']['folds_used']
  checks.append(dict(task=f['task'],channel=f['labels'][c],regression_max_abs_error_uv=regerr,fir_max_abs_error_uv=err,decoder_held_out_score_error=float(decode_error),decoder_checked_bin=chosen,purged_folds_checked=len(aucs),all_native_channels_converged=all(s['converged'] for s in f['deconvolution']['solver'])));print(checks[-1],flush=True)
 out=pathlib.Path(path).parent/'scipy_model_validation.json';out.write_text(json.dumps(dict(scipy_tolerance=1e-11,checks=checks),indent=2)+'\n');print(out)
if __name__=='__main__':main(sys.argv[1])
