"""Independent numerical references: NumPy/SciPy, explicit resamples/designs.
No clinical or full-toolbox parity claim follows from these finite fixtures.
"""
import json,pathlib,itertools,numpy as np,scipy
from scipy.sparse import csr_matrix
from scipy.sparse.linalg import lsqr
from scipy.stats import ttest_1samp
rng=np.random.default_rng(20261015)
times=np.linspace(-.2,.8,257);y=-3*np.exp(-((times-.22)/.04)**2)+.12*np.sin(20*times)
window=[.1,.35];ix=np.flatnonzero((times>=window[0]-1e-10)&(times<=window[1]+1e-10));t=times[ix];v=y[ix];peak=np.argmin(v);cum=np.r_[0,np.cumsum((np.maximum(-v[:-1],0)+np.maximum(-v[1:],0))*np.diff(t)/2)];area=float(np.interp(cum[-1]/2,cum,t));threshold=-v[peak]/2;cross=np.flatnonzero(((-v[:-1])<threshold)&((-v[1:])>=threshold)&(np.arange(len(v)-1)<peak));k=cross[0];onset=float(t[k]+(threshold+v[k])/(-v[k+1]+v[k])*(t[k+1]-t[k]));measure=dict(mean=float(v.mean()),signed_auc=float(np.trapezoid(v,t)),positive_auc=float(np.trapezoid(np.maximum(v,0),t)),negative_auc=float(np.trapezoid(np.minimum(v,0),t)),peak_amplitude=float(v[peak]),peak_latency=float(t[peak]),fractional_area_latency=area,fractional_peak_latency=onset)
x=np.c_[np.ones(80),rng.integers(0,2,80),rng.normal(size=80)];response=x@rng.normal(size=(3,12))+rng.normal(size=(80,12))*.1;beta=np.linalg.lstsq(x,response,rcond=1e-10)[0]
a=rng.normal(size=(120,24));a[rng.random(a.shape)<.88]=0;by=rng.normal(size=120);sparse=lsqr(csr_matrix(a),by,atol=1e-11,btol=1e-11,iter_lim=2000)
train=rng.normal(size=(60,6));labels=np.r_[np.zeros(35,dtype=int),np.ones(25,dtype=int)];train[labels==1]+=np.linspace(.1,.8,6);test=rng.normal(size=(15,6));m=train.mean(0);sd=train.std(0);z=(train-m)/sd;means=np.stack([z[labels==k].mean(0) for k in [0,1]]);res=z-means[labels];cov=res.T@res/(len(z)-2);cov=.9*cov+np.eye(6)*(.1*np.trace(cov)/6+1e-12);weights=np.linalg.solve(cov,means[1]-means[0]);scores=((test-m)/sd)@weights-.5*(means[1]+means[0])@weights
values=rng.normal(size=(5,12))+.3;signs=np.array(list(itertools.product([1.,-1.],repeat=5)));observed=ttest_1samp(values,0,axis=0).statistic;null=np.array([np.max(np.abs(ttest_1samp(values*s[:,None],0,axis=0).statistic)) for s in signs]);p=(null[:,None]>=np.abs(observed)[None,:]-1e-10).mean(0)
r=dict(numpy=np.__version__,scipy=scipy.__version__,times=times.tolist(),y=y.tolist(),window=window,measure=measure,x=x.tolist(),response=response.tolist(),beta=beta.tolist(),sparse_a=a.tolist(),sparse_y=by.tolist(),lsqr=sparse[0].tolist(),train=train.tolist(),labels=labels.tolist(),test=test.tolist(),scores=scores.tolist(),differences=values.tolist(),signs=signs.tolist(),t=observed.tolist(),p=p.tolist())
path=pathlib.Path('bridge/tests/reference/erp_workbench.json');path.write_text(json.dumps(r,indent=2)+'\n');print(path)
