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
    def test_nullable_missing_dfa_does_not_qualify_fei(self):
        frame=pd.DataFrame({'filename':['a','a'],'Chan':['Fz','Fz'],'Epoch':[1,2],
            'Alpha_DFA':pd.Series([pd.NA,.8],dtype='Float64'),'Alpha_fEI':[.8,1.2]})
        prepared=g.prepare_eeg_table(frame)
        self.assertAlmostEqual(prepared.iloc[0]['Alpha_fEI'],1.2)
        self.assertEqual(prepared.attrs['excluded_unqualified_fei'],1)

    def test_fei_qualification_is_applied_before_epoch_averages(self):
        frame=pd.DataFrame({'filename':['a','a'],'Chan':['Fz','Fz'],'Epoch':[1,2],
            'Alpha_DFA':[.3,.8],'Alpha_fEI':[.8,1.2]})
        prepared=g.prepare_eeg_table(frame)
        self.assertAlmostEqual(prepared.iloc[0]['Alpha_fEI'],1.2)
        self.assertEqual(prepared.attrs['excluded_unqualified_fei'],1)

    def test_subject_join_preserves_zeroes_and_accepts_bids_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'metadata.csv';path.write_text('Subject,Group\n001,A\n')
            frame=pd.DataFrame({'filename':['a'],'subjid':['sub-001'],'Chan':['Fz'],'Epoch':[1],'Alpha_PSD':[1.0]})
            merged=g.prepare_eeg_table(frame,path,'Subject')
            self.assertEqual(merged.iloc[0]['Subject'],'001')

    def test_string_metrics_are_numeric_before_recording_means(self):
        raw=pd.DataFrame({'filename':['a','a'],'Chan':['Fz','Fz'],'Epoch':[1,2],
            'Alpha_PSD':['1.0','3.0'],'Alpha_DFA_short':['.7','.9']})
        prepared=g.prepare_eeg_table(raw)
        self.assertAlmostEqual(prepared.iloc[0]['Alpha_PSD'],2)
        self.assertAlmostEqual(prepared.iloc[0]['Alpha_DFA_short'],.8)
        mean=g.apply_channel_scope(prepared,'mean')
        self.assertEqual(mean.iloc[0]['Chan'],'Mean')
        raw.loc[0,'Alpha_PSD']='not-a-number'
        with self.assertRaisesRegex(ValueError,'Non-numeric feature value'):
            g.prepare_eeg_table(raw)

    def test_numeric_categorical_factors_have_matching_contrast_levels(self):
        rng=np.random.default_rng(11)
        rows=[]
        for subject in range(20):
            offset=rng.normal()
            for session in [1,2]:
                rows.append({'Subject':f'S{subject}', 'Group':subject%2,
                    'Session':session, 'Alpha_PSD':offset+subject%2+session+rng.normal(0,.3)})
        result=g.fit_statistical_model(pd.DataFrame(rows),'Alpha_PSD','Group','Session',[], 'Subject','lmm','fdr')
        self.assertIsNotNone(result)
        self.assertTrue(result['posthoc_contrasts'])

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
