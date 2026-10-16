"""Map a volumetric atlas (including HCPex) onto an explicitly aligned forward grid.

Requires numpy and, for NIfTI input, nibabel. No implicit coordinate conversion.
Forward NPZ: channels[str], leadfield[sensors,sources], source_mni_mm[sources,3].
Atlas NPZ alternative: data[3D], affine[4,4], in the same MNI world coordinates.
Labels JSON: {"integer atlas ID": "region name"}.
"""
import argparse, gzip, json, pathlib
import numpy as np

def build(forward, atlas_data, affine, labels):
    names=[str(x) for x in forward['channels']]
    lead=np.asarray(forward['leadfield'],dtype=float)
    xyz=np.asarray(forward['source_mni_mm'],dtype=float)
    if lead.ndim!=2 or xyz.shape!=(lead.shape[1],3) or lead.shape[0]!=len(names) or len(set(names))!=len(names) or not np.isfinite(lead).all() or not np.isfinite(xyz).all():
        raise ValueError('Invalid forward dimensions, duplicate channel labels, or nonfinite values')
    if len(set(labels.values()))!=len(labels):raise ValueError('Atlas region names must be unique')
    if not np.isfinite(atlas_data).all() or not np.equal(atlas_data,np.rint(atlas_data)).all():raise ValueError('Atlas must contain finite integer region IDs')
    if atlas_data.ndim!=3 or np.asarray(affine).shape!=(4,4):raise ValueError('Atlas must have a 3D label volume and 4x4 affine')
    voxel=np.rint((np.linalg.inv(affine)@np.c_[xyz,np.ones(len(xyz))].T).T[:,:3]).astype(int)
    inside=np.all((voxel>=0)&(voxel<np.asarray(atlas_data.shape)),axis=1)
    ids=np.zeros(len(xyz),dtype=int)
    ids[inside]=atlas_data[tuple(voxel[inside].T)].astype(int)
    rois=[]
    for key,name in labels.items():
        indices=np.flatnonzero(ids==int(key)).tolist()
        if indices and int(key)!=0:rois.append(dict(name=name,indices=indices))
    if not rois:raise ValueError('No atlas sources matched: check coordinate frames, affine, and label IDs')
    missing=[str(k) for k in labels if int(k)!=0 and not np.any(ids==int(k))]
    return dict(channels=names,leadfield=lead.tolist(),rois=rois,
      metadata=dict(coordinates='MNI mm; explicitly supplied',missing_atlas_ids=missing,
        mapped_sources=sum(len(r['indices']) for r in rois),total_sources=len(ids)))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--forward',required=True);p.add_argument('--atlas',required=True)
    p.add_argument('--labels',required=True);p.add_argument('--output',required=True)
    args=p.parse_args()
    if args.atlas.endswith('.npz'):
        atlas=np.load(args.atlas);data,affine=atlas['data'],atlas['affine']
    else:
        import nibabel as nib
        atlas=nib.load(args.atlas);data,affine=np.asarray(atlas.dataobj),atlas.affine
    with np.load(args.forward,allow_pickle=False) as forward:
        result=build(forward,data,affine,json.loads(pathlib.Path(args.labels).read_text()))
    result['metadata'].update(atlas=str(pathlib.Path(args.atlas).name),forward=str(pathlib.Path(args.forward).name))
    output=pathlib.Path(args.output)
    if output.exists():raise FileExistsError(f'Refusing to replace {output}')
    if output.suffix=='.gz':
        with gzip.open(output,'wt') as f:json.dump(result,f)
    else:output.write_text(json.dumps(result))
    print(json.dumps(result['metadata'],indent=2))
if __name__=='__main__':main()
