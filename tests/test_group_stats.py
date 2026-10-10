import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import numpy as np
import pandas as pd

spec = importlib.util.spec_from_file_location('eeg_group_stats', Path(__file__).parents[1]/'assets/group_stats.py')
g = importlib.util.module_from_spec(spec);spec.loader.exec_module(g)

class GroupStatsTests(unittest.TestCase):
    def table(self):
        rng=np.random.default_rng(12);rows=[];metadata=[]
        for subject in range(20):
            group='A' if subject<10 else 'B'; offset=rng.normal(0,.7)
            name=f'S{subject:02}_Rest'
            metadata.append({'Recording':name,'Subject':f'S{subject:02}','Group':group,'Age':30+subject})
            for channel in ['F3','F4']:
                for epoch in range(6):
                    rows.append({'filename':name+'_clean','subjid':f'S{subject:02}','Chan':channel,'Epoch':epoch+1,'bin_idx':0,'bin_start_s':0,'bin_end_s':12,'Alpha_PSD':4*(group=='B')+offset+.5*(channel=='F4')+rng.normal(0,.2)})
        return pd.DataFrame(rows),pd.DataFrame(metadata)
    def test_metadata_and_epoch_aggregation(self):
        df,meta=self.table()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'metadata.csv';meta.to_csv(path,index=False)
            prepared=g.prepare_eeg_table(df,path,'Recording')
            self.assertEqual(len(prepared),40)
            self.assertEqual(prepared['Subject'].nunique(),20)
            self.assertNotIn('Epoch',prepared.columns)
            self.assertEqual(g.detect_columns(prepared)['subject_id'],'Subject')
    def test_epoch_conditions_are_not_averaged_together(self):
        frame=pd.DataFrame([{"filename":"S01_ERP","subjid":"S01","Chan":"Fz","Epoch":epoch,"epoch_label":state,"Alpha_PSD":value} for epoch,state,value in [(1,"Stimulus/S 51",1),(2,"Stimulus/S 51",3),(3,"Stimulus/S 52",8),(4,"Stimulus/S 52",10)]])
        prepared=g.prepare_eeg_table(frame)
        self.assertEqual(list(prepared["Alpha_PSD"]),[2,9])
        self.assertEqual(set(prepared["epoch_condition"]),{"Stimulus/S 51","Stimulus/S 52"})
    def test_ambiguous_or_unmatched_metadata_is_rejected(self):
        df,meta=self.table()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'metadata.csv'
            pd.concat([meta,meta.iloc[:1]]).to_csv(path,index=False)
            with self.assertRaises(ValueError):g.prepare_eeg_table(df,path,'Recording')
            meta.iloc[1:].to_csv(path,index=False)
            with self.assertRaises(ValueError):g.prepare_eeg_table(df,path,'Recording')
    def test_model_adjusted_contrasts_and_lmm(self):
        df,meta=self.table()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'metadata.csv';meta.to_csv(path,index=False)
            prepared=g.prepare_eeg_table(df,path,'Recording')
            result=g.fit_statistical_model(prepared,'Alpha_PSD','Group','Chan',[], 'Subject','lmm','fdr')
            self.assertIn('Mixed',result['model_type'])
            contrasts=result['posthoc_contrasts']
            group_contrasts=[c for c in contrasts if c['contrast_type']=='Group within Subgroup']
            self.assertEqual(len(group_contrasts),2)
            self.assertTrue(all(c['p_raw']<.05 for c in group_contrasts))
            self.assertTrue(all(c['comparison']=='model-adjusted marginal means' for c in contrasts))
    def test_failed_mixed_model_has_no_silent_ols_fallback(self):
        df,_=self.table();prepared=g.prepare_eeg_table(df);prepared['Group']=prepared['subjid'].map(lambda s:'A' if int(s[1:])<10 else 'B')
        with patch.object(g.smf,'mixedlm',side_effect=RuntimeError('singular')),patch.object(g.smf,'ols') as ols:
            with self.assertRaises(RuntimeError):g.fit_statistical_model(prepared,'Alpha_PSD','Group','Chan',[],'subjid','lmm','fdr')
            ols.assert_not_called()

if __name__=='__main__':unittest.main()
