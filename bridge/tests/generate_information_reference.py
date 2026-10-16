"""Generate offline fixtures from a pinned Frites checkout; no package installation.
python3 bridge/tests/generate_information_reference.py /tmp/ccs-frites-reference
"""
import sys, pathlib, types, json, subprocess, numpy as np
from scipy.special import ndtri
root=pathlib.Path(sys.argv[1])
pinned='ded44ea19bfa86a37b83f703e3f1375c35a1eeca'
if subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()!=pinned:
 raise ValueError(f'Check out the pinned Frites revision: {pinned}')
core=types.ModuleType('frites.core')
core.copnorm_nd=lambda x,axis=-1: ndtri((np.argsort(np.argsort(x,axis=axis),axis=axis)+1)/(x.shape[axis]+1))
core.copnorm_cat_nd=None
sys.modules['frites']=types.ModuleType('frites');sys.modules['frites.core']=core
ns={};exec((root/'frites/core/gcmi_1d.py').read_text(),ns)
rng=np.random.default_rng(20261015)
x=rng.normal(size=(3,250)).astype('float32');x[1]=(x[0]*.65+x[1]*.7).astype('float32')
z=core.copnorm_nd(x)
mi=ns['mi_1d_gg'](z[0],z[1]); cmi=ns['cmi_1d_ggg'](z[0],z[1],z[2])
# A delayed directed AR process, independent third channel, single continuous epoch.
temporal=rng.normal(size=(3,1500)).astype('float32')
for t in range(3,1500):
 temporal[0,t]+=.6*temporal[0,t-1]
 temporal[1,t]=.3*temporal[1,t-1]+.9*temporal[0,t-3]+.5*temporal[1,t]
temporal=temporal[:,100:]
def time_te(data,lag=3,hs=1,ht=1,spacing=1):
 start=max(lag+(hs-1)*spacing,1+(ht-1)*spacing)
 w=np.zeros((len(data),len(data)))
 for i in range(len(data)):
  for j in range(len(data)):
   if i==j:continue
   x=core.copnorm_nd(np.stack([data[i,start-lag-h*spacing:len(data[i])-lag-h*spacing] for h in range(hs)]))
   y=core.copnorm_nd(data[j,start:])
   z=core.copnorm_nd(np.stack([data[j,start-1-h*spacing:len(data[j])-1-h*spacing] for h in range(ht)]))
   w[i,j]=ns['cmi_1d_ggg'](x,y,z)
 return w.tolist()
# Fixed orientation, identity noise; independent direct NumPy operators.
l=rng.normal(size=(4,6));data=rng.normal(size=(4,50));alpha=np.trace(l@l.T)/4/9
w=l.T@np.linalg.inv(l@l.T+alpha*np.eye(4))
dspm=w/np.linalg.norm(w,axis=1)[:,None]
sloreta=w/np.sqrt(np.diag(w@l))[:,None]
cov=np.cov(data);ci=np.linalg.inv(cov+np.trace(cov)/4*.05*np.eye(4));lcmv=l.T@ci;lcmv/=np.diag(lcmv@l)[:,None]
fixture=dict(upstream_commit='ded44ea19bfa86a37b83f703e3f1375c35a1eeca',x=x.tolist(),mi=float(mi),cmi=float(cmi),temporal=temporal.tolist(),te_time=time_te(temporal),te_time_first=time_te(temporal[:,:250]),te_time_history=time_te(temporal,hs=2,ht=3,spacing=2),leadfield=l.tolist(),data=data.tolist(),operators={k:v.tolist() for k,v in [('mne',w),('dspm',dspm),('sloreta',sloreta),('lcmv',lcmv)]})
path=pathlib.Path('bridge/tests/reference/information_source.json');path.write_text(json.dumps(fixture,indent=2)+'\n');print(path)
# Independent graph reference: matrix triangle formula and SciPy shortest paths.
from scipy.sparse.csgraph import shortest_path
raw=rng.uniform(-.1,1,size=(5,5));np.fill_diagonal(raw,0)
sym=(np.maximum(raw,0)+np.maximum(raw.T,0))/2
edges=sorted([(sym[i,j],i,j) for i in range(5) for j in range(i) if sym[i,j]>0],key=lambda e:(-e[0],e[1],e[2]))[:6]
mask=np.zeros((5,5));weights=mask.copy()
for value,i,j in edges:mask[i,j]=mask[j,i]=1;weights[i,j]=weights[j,i]=value/edges[0][0]
deg=mask.sum(1);cube=np.cbrt(weights);clustering=np.diag(cube@cube@cube)/np.maximum(1,deg*(deg-1))
lengths=np.divide(1,weights,out=np.full_like(weights,np.inf),where=weights>0);np.fill_diagonal(lengths,0)
distance=shortest_path(lengths,directed=False)
inv=np.divide(1,distance,out=np.zeros_like(distance),where=(distance>0)&np.isfinite(distance));eff=inv.sum(1)/4
expected=np.c_[(np.maximum(raw,0)*mask).sum(1),(np.maximum(raw,0)*mask).sum(0),deg,clustering,eff,np.repeat(eff.mean(),5),np.repeat(.6,5)]
fixture.update(graph_raw=raw.tolist(),graph_expected=expected.tolist());path.write_text(json.dumps(fixture,indent=2)+'\n')
