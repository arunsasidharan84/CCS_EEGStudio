use ccs_eeg_engine::{features,preprocessing,connectivity,Options,Recording};
use std::f64::consts::PI;

#[test]
fn references_have_expected_voltage_differences(){
    let mut data=vec![vec![1.0,4.0],vec![3.0,8.0],vec![5.0,12.0]];
    let labels=vec!["Fz".into(),"Cz".into(),"Pz".into()];
    preprocessing::apply_output_reference(&mut data,&labels,"channels",&["Cz".into()]).unwrap();
    assert_eq!(data,vec![vec![-2.0,-4.0],vec![0.0,0.0],vec![2.0,4.0]]);
    assert!(preprocessing::apply_output_reference(&mut data,&labels,"channels",&["Unknown".into()]).is_err());
}
#[test]
fn mean_psd_is_more_sensitive_to_an_outlier_than_median(){
    let signal:Vec<f64>=(0..1500).map(|i| (2.0*PI*10.0*i as f64/250.0).sin()*if i<250{20.0}else{1.0}).collect();
    let (_,median)=features::welch_psd_nperseg(&signal,250.0,250,false);
    let (_,mean)=features::welch_psd_nperseg(&signal,250.0,250,true);
    assert!(mean[10]>median[10]*5.0);
    let bands=features::bandpowers_with_options(&signal,250.0,1.0,false,&[(12.0,15.0,"SMR"),(1.0,4.0,"Slow")]);
    assert!(bands.contains_key("SMR_PSD"));assert!(!bands.contains_key("Alpha_PSD"));
    assert!(bands.values().all(|v|*v>=0.0&&*v<=1.0));
}
#[test]
fn butterworth_filter_preserves_alpha_and_attenuates_high_frequency(){
    let raw:Vec<f32>=(0..2000).map(|i|((2.0*PI*10.0*i as f64/250.0).sin()+0.7*(2.0*PI*80.0*i as f64/250.0).sin()) as f32).collect();
    let mut recording=Recording{rate:250.0,labels:vec!["Fz".into(),"Cz".into(),"Pz".into()],channels:vec![raw.clone(),raw.clone(),raw],source_epoch_samples:None,epoch_labels:None};
    let options=serde_json::from_value(serde_json::json!({"filter":true,"filter_type":"iir","iir_order":4,"low_hz":1,"high_hz":35,"notch_hz":0,"gedai":false,"badchannel":false,"interpolate":false,"downsample":false})).unwrap();
    let output=std::env::temp_dir().join(format!("ccs_iir_{}.json",std::process::id()));
    preprocessing::run(&mut recording,"synthetic",output.to_str().unwrap(),&options).unwrap();
    let amplitude=|frequency:f64|{let s=&recording.channels[0][500..1500];2.0/s.len() as f64*(s.iter().enumerate().map(|(i,v)|*v as f64*(2.0*PI*frequency*(i+500) as f64/250.0).sin()).sum::<f64>()).abs()};
    assert!(amplitude(10.0)>0.95);assert!(amplitude(80.0)<0.02);
    std::fs::remove_file(output).unwrap();
}
#[test]
fn gc_contrast_is_gc_minus_time_reversed_gc(){
    let mut options=Options::connectivity_test();options.mic=false;options.mim=false;options.coh=false;options.plv=false;options.ciplv=false;options.pli=false;options.wpli=false;options.gc_contrast=true;
    let labels=vec!["F3".into(),"F4".into(),"P3".into(),"P4".into()];
    let mut state=7_u64;
    let channels:Vec<Vec<f32>>=(0..4).map(|channel|(0..1000).map(|i|{state=state.wrapping_mul(6364136223846793005).wrapping_add(1); let noise=((state>>32) as u32 as f64/u32::MAX as f64)-0.5;((2.0*PI*(8.0+channel as f64)*i as f64/250.0).sin()+noise) as f32}).collect()).collect();
    let rows=connectivity::compute_epoch(&channels,&labels,0,1000,250.0,&options);
    assert_eq!(rows[0].len(),18);
    for i in 0..6 {let expected=rows[0][i]-rows[0][i+6];let contrast=rows[0][i+12];assert!((expected.is_nan()&&contrast.is_nan())||(expected-contrast).abs()<1e-9);}
}
