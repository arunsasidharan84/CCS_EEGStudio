import unittest
import numpy as np
from build_source_atlas import build
class AtlasTests(unittest.TestCase):
 def test_explicit_grid_and_missing_regions(self):
  forward={'channels':['Fz','Cz','Pz','Oz'],'leadfield':np.ones((4,3)),
           'source_mni_mm':np.array([[0,0,0],[1,1,1],[9,9,9]])}
  data=np.zeros((2,2,2));data[0,0,0]=1;data[1,1,1]=2
  model=build(forward,data,np.eye(4),{'1':'Cortex','2':'Thalamus','3':'Missing'})
  self.assertEqual(model['rois'],[dict(name='Cortex',indices=[0]),dict(name='Thalamus',indices=[1])])
  self.assertEqual(model['metadata']['missing_atlas_ids'],['3'])
 def test_wrong_frame_is_rejected(self):
  f={'channels':['Fz'],'leadfield':np.ones((1,1)),'source_mni_mm':np.array([[1000,1000,1000]])}
  with self.assertRaises(ValueError):build(f,np.ones((2,2,2)),np.eye(4),{'1':'ROI'})
if __name__=='__main__':unittest.main()
