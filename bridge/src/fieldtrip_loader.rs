use crate::mat_v5::{self, MatValue};
use crate::Recording;
use std::path::Path;

fn first_field<'a>(value: &'a MatValue, name: &str) -> Option<&'a MatValue> {
    value.fields.get(name)?.first()
}

fn matrix_shape(value: &MatValue) -> Result<(usize, usize), String> {
    let channels = *value
        .dims
        .first()
        .ok_or("FieldTrip trial has no dimensions")?;
    let samples = value.dims.get(1..).unwrap_or(&[]).iter().copied().product();
    if channels == 0 || samples == 0 || value.numeric.len() != channels * samples {
        return Err(format!(
            "Invalid FieldTrip trial dimensions {:?} for {} values",
            value.dims,
            value.numeric.len()
        ));
    }
    Ok((channels, samples))
}

fn labels(value: &MatValue, count: usize) -> Vec<String> {
    let mut labels = first_field(value, "label")
        .and_then(|v| v.fields.get("cell"))
        .map(|items| {
            items
                .iter()
                .map(|v| v.text.trim().to_string())
                .filter(|v| !v.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    while labels.len() < count {
        labels.push(format!("Ch {}", labels.len() + 1));
    }
    labels.truncate(count);
    labels
}

pub(crate) fn recording_from_ft(value: &MatValue) -> Result<Recording, String> {
    let rate = first_field(value, "fsample")
        .and_then(|v| v.numeric.first())
        .copied()
        .ok_or("FieldTrip ftData.fsample is missing")?;
    if !rate.is_finite() || rate <= 0.0 {
        return Err(format!("Invalid FieldTrip sampling rate: {rate}"));
    }
    let trial = first_field(value, "trial").ok_or("FieldTrip ftData.trial is missing")?;
    let trials: Vec<&MatValue> = trial
        .fields
        .get("cell")
        .map(|v| v.iter().collect())
        .unwrap_or_else(|| vec![trial]);
    if trials.is_empty() {
        return Err("FieldTrip ftData.trial is empty".into());
    }
    let (channel_count, first_samples) = matrix_shape(trials[0])?;
    let mut channels = vec![Vec::<f32>::new(); channel_count];
    let mut equal_samples = true;
    for trial in &trials {
        let (n_channels, n_samples) = matrix_shape(trial)?;
        if n_channels != channel_count {
            return Err("FieldTrip trials have inconsistent channel counts".into());
        }
        equal_samples &= n_samples == first_samples;
        // MATLAB stores [channel x sample] matrices in column-major order.
        for sample in 0..n_samples {
            for (channel, output) in channels.iter_mut().enumerate() {
                output.push(trial.numeric[sample * channel_count + channel] as f32);
            }
        }
    }
    Ok(Recording {
        rate,
        labels: labels(value, channel_count),
        channels,
        source_epoch_samples: (trials.len() > 1 && equal_samples).then_some(first_samples),
        epoch_labels: None,
    })
}

/// Loads a FieldTrip MATLAB v5 recording containing an `ftData` struct.
pub fn load_fieldtrip(path: &Path) -> Result<Recording, String> {
    let variables = mat_v5::load(path)?;
    let value = variables
        .get("ftData")
        .or_else(|| {
            variables.values().find(|v| {
                v.fields.contains_key("trial")
                    && v.fields.contains_key("label")
                    && v.fields.contains_key("fsample")
            })
        })
        .ok_or("MAT file does not contain a FieldTrip ftData struct")?;
    recording_from_ft(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn numeric(dims: &[usize], values: &[f64]) -> MatValue {
        MatValue {
            dims: dims.to_vec(),
            numeric: values.to_vec(),
            ..Default::default()
        }
    }

    #[test]
    fn converts_matlab_column_major_trial() {
        let mut fields = HashMap::new();
        fields.insert("fsample".into(), vec![numeric(&[1, 1], &[250.0])]);
        fields.insert(
            "trial".into(),
            vec![numeric(&[2, 3], &[1., 10., 2., 20., 3., 30.])],
        );
        let labels = ["C3", "C4"]
            .into_iter()
            .map(|s| MatValue {
                text: s.into(),
                ..Default::default()
            })
            .collect();
        fields.insert(
            "label".into(),
            vec![MatValue {
                fields: HashMap::from([("cell".into(), labels)]),
                ..Default::default()
            }],
        );
        let rec = recording_from_ft(&MatValue {
            fields,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(rec.labels, ["C3", "C4"]);
        assert_eq!(rec.channels, [vec![1., 2., 3.], vec![10., 20., 30.]]);
        assert_eq!(rec.source_epoch_samples, None);
    }

    #[test]
    fn concatenates_equal_length_cell_trials_as_epochs() {
        let mut fields = HashMap::new();
        fields.insert("fsample".into(), vec![numeric(&[1, 1], &[100.0])]);
        let cells = vec![numeric(&[1, 2], &[1., 2.]), numeric(&[1, 2], &[3., 4.])];
        fields.insert(
            "trial".into(),
            vec![MatValue {
                fields: HashMap::from([("cell".into(), cells)]),
                ..Default::default()
            }],
        );
        let rec = recording_from_ft(&MatValue {
            fields,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(rec.channels[0], [1., 2., 3., 4.]);
        assert_eq!(rec.source_epoch_samples, Some(2));
    }
}
