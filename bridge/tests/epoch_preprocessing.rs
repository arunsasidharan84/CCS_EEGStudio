use ccs_algorithm::eeg::{Recording, preprocessing::{run, PreprocessOptions}};
use serde_json::json;
fn options(extra: serde_json::Value) -> PreprocessOptions {
    let mut v = json!({"downsample":false,"downsample_freq":250.,"filter":false,"low_hz":0.5,"high_hz":40.,"notch_hz":0.,"badchannel":false,"gedai":false,"interpolate":false,"gedai_epoch_seconds":1.,"gedai_threshold":"auto"});
    for (k,val) in extra.as_object().unwrap() {v[k]=val.clone();}
    serde_json::from_value(v).unwrap()
}
#[test]
fn resampling_and_event_cut_keep_zero_sample_aligned() {
    for source_rate in [1000., 256.] {
        for filter in [false, true] {
            let n=(source_rate*20.) as usize;
            let mut samples=vec![0f32;n];
            for t in [4.,12.] { samples[(t*source_rate) as usize]=100.; }
            let mut rec=Recording{rate:source_rate,labels:vec!["Pz".into()],channels:vec![samples],source_epoch_samples:None,epoch_labels:None};
            let opts=options(json!({"downsample":true,"filter":filter,"stim_epochs":{"onsets":[4.,12.],"labels":["A","B"],"tmin":-0.2,"tmax":0.5}}));
            let out=std::env::temp_dir().join(format!("ccs-timing-{source_rate}-{filter}.ccseeg"));
            run(&mut rec,"fixture",out.to_str().unwrap(),&opts).unwrap();
            assert!((rec.rate-250.).abs()<1e-9);
            assert_eq!(rec.source_epoch_samples,Some(176));
            for trial in rec.channels[0].chunks(176) {
                let peak=trial.iter().enumerate().max_by(|a,b| a.1.abs().total_cmp(&b.1.abs())).unwrap().0;
                assert_eq!(peak,50,"source={source_rate}, filter={filter}");
            }
            std::fs::remove_file(out).unwrap();
        }
    }
}
#[test]
fn epoched_ica_runs_without_changing_trial_layout() {
    let points=200; let trials=12;
    let labels=["Fp1","Fp2","F3","F4","C3","C4","P3","P4"].iter().map(|s|s.to_string()).collect();
    let channels=(0..8).map(|ch| (0..points*trials).map(|i| {
        let t=i as f64/100.;
        ((t*(ch+2) as f64*2.7).sin()*7.+(t*17.3+ch as f64).cos()*2.+(((i*113+ch*337)%101) as f64-50.)*0.03) as f32
    }).collect()).collect();
    let mut rec=Recording{rate:100.,labels,channels,source_epoch_samples:Some(points),epoch_labels:Some((0..trials).map(|i|format!("T{i}")).collect())};
    let opts=options(json!({"ica_method":"picard","ica_blink":false,"ica_other":true,"ica_fit_asr":true,"asr_mode":"correct"}));
    let out=std::env::temp_dir().join("ccs-epoched-ica-test.ccseeg");
    let summary=run(&mut rec,"fixture",out.to_str().unwrap(),&opts).unwrap();
    let summary=serde_json::to_value(summary).unwrap();
    assert_eq!(summary["ica"]["ica"]["other_stage"]["ran"],true,"{summary}");
    assert_eq!(rec.source_epoch_samples,Some(points));
    assert_eq!(rec.epoch_labels.as_ref().unwrap().len(),trials);
    assert_eq!(rec.channels[0].len(),points*trials);
    assert!(rec.channels.iter().flatten().all(|v|v.is_finite()));
    std::fs::remove_file(out).unwrap();
}
#[test]
fn reject_asr_cannot_invalidate_event_positions() {
    let mut rec=Recording{rate:100.,labels:vec!["Pz".into()],channels:vec![vec![0.;2000]],source_epoch_samples:None,epoch_labels:None};
    let opts=options(json!({"asr_mode":"reject","stim_epochs":{"onsets":[4.],"labels":["A"],"tmin":-0.2,"tmax":0.5}}));
    let error=run(&mut rec,"fixture","/tmp/ccs-should-not-write.ccseeg",&opts).err().unwrap();
    assert!(error.contains("preserve event timing"));
}
