use nalgebra::{DMatrix, SymmetricEigen};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::f64::consts::PI;
use std::fs;
use std::io::Write;
use std::path::Path;

use ccs_algorithm::eeg::Recording;

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct MicrostateOptions {
    pub min_states: usize,
    pub max_states: usize,
    pub selected_states: usize,
    pub repetitions: usize,
    pub max_iterations: usize,
    pub convergence: f64,
    pub min_peak_distance_ms: f64,
    pub peaks_per_recording: usize,
    pub gfp_threshold_sd: f64,
    pub min_segment_ms: f64,
    pub seed: u64,
}

impl Default for MicrostateOptions {
    fn default() -> Self {
        Self {
            min_states: 3,
            max_states: 8,
            selected_states: 8,
            repetitions: 10,
            max_iterations: 1000,
            convergence: 1e-6,
            min_peak_distance_ms: 10.0,
            peaks_per_recording: 300,
            gfp_threshold_sd: 1.5,
            min_segment_ms: 30.0,
            seed: 12345,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct ModelFit {
    pub states: usize,
    pub gev: f64,
    pub cross_validation: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct ScalpPosition {
    pub label: String,
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct StateStats {
    pub label: String,
    pub mean_gfp: f64,
    pub occurrence_hz: f64,
    pub mean_duration_ms: f64,
    pub coverage: f64,
    pub gev: f64,
    pub mean_spatial_correlation: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct SequenceStats {
    pub lz_complexity: usize,
    pub shuffled_lz_complexity: usize,
    pub normalized_lz: f64,
    pub duration_variance_samples2: f64,
    pub entropy_production: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct RecordingResult {
    pub filename: String,
    pub sample_rate: f64,
    pub sample_count: usize,
    pub gev_total: f64,
    pub states: Vec<StateStats>,
    pub transition_matrix: Vec<Vec<f64>>,
    pub sequence: Vec<usize>,
    pub sequence_metrics: SequenceStats,
    pub sequence_plot: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct MicrostateResult {
    pub algorithm: String,
    pub selected_states: usize,
    pub state_labels: Vec<String>,
    pub channel_labels: Vec<String>,
    pub channel_positions: Vec<ScalpPosition>,
    pub prototypes: Vec<Vec<f64>>,
    pub canonical_correlations: Vec<Option<f64>>,
    pub model_fits: Vec<ModelFit>,
    pub recordings: Vec<RecordingResult>,
    pub statistics_csv: String,
    pub sequence_metrics_csv: String,
    pub transitions_csv: String,
    pub categorical_summary_csv: String,
    pub template_plot: String,
}

#[derive(Clone)]
struct Prepared {
    name: String,
    rate: f64,
    data: Vec<Vec<f64>>,
    gfp: Vec<f64>,
}

#[derive(Deserialize)]
struct MetaMapsResource {
    channels: Vec<MetaChannel>,
    solutions: HashMap<String, Vec<Vec<f64>>>,
}

#[derive(Deserialize)]
struct MetaChannel {
    label: String,
    theta: f64,
    radius: f64,
    x: f64,
    y: f64,
    z: f64,
}

pub fn analyse(
    recordings: Vec<(String, Recording)>,
    output_dir: &Path,
    options: &MicrostateOptions,
    progress: &mut dyn FnMut(usize, &str),
) -> Result<MicrostateResult, String> {
    if recordings.is_empty() {
        return Err("microstate analysis requires at least one recording".into());
    }
    fs::create_dir_all(output_dir).map_err(|e| e.to_string())?;
    let common = common_labels(&recordings)?;
    if common.len() < 4 {
        return Err("microstate analysis requires at least four common EEG channels".into());
    }
    let prepared: Vec<Prepared> = recordings
        .into_iter()
        .map(|(name, r)| prepare(name, r, &common))
        .collect::<Result<_, _>>()?;
    progress(8, "Selecting GFP peaks");
    let mut peak_maps = Vec::new();
    for p in &prepared {
        for idx in select_peaks(p, options) {
            let mut map = p.data.iter().map(|c| c[idx]).collect::<Vec<_>>();
            normalize(&mut map);
            peak_maps.push(map);
        }
    }
    if peak_maps.len() < options.max_states.max(2) {
        return Err("too few GFP peaks for the requested microstate models".into());
    }

    let min_k = options
        .min_states
        .max(2)
        .min(common.len().saturating_sub(2));
    let max_k = options
        .max_states
        .max(min_k)
        .min(common.len().saturating_sub(2));
    let mut models = Vec::new();
    for k in min_k..=max_k {
        progress(
            10 + (k - min_k) * 35 / (max_k - min_k + 1),
            &format!("Fitting {k}-state model"),
        );
        let (maps, gev, residual) = modified_kmeans(&peak_maps, k, options)?;
        let correction = (common.len() - 1) as f64 / (common.len() - k - 1) as f64;
        models.push((
            maps,
            ModelFit {
                states: k,
                gev,
                cross_validation: residual * correction * correction,
            },
        ));
    }
    let selected = if options.selected_states >= min_k && options.selected_states <= max_k {
        options.selected_states
    } else {
        models
            .iter()
            .min_by(|a, b| a.1.cross_validation.total_cmp(&b.1.cross_validation))
            .map(|x| x.1.states)
            .unwrap_or(max_k)
    };
    let mut prototypes = models
        .iter()
        .find(|m| m.1.states == selected)
        .map(|m| m.0.clone())
        .ok_or("selected microstate model was not fitted")?;
    let meta = load_metamaps()?;
    let (canonical_correlations, state_labels) = order_by_metamaps(&mut prototypes, &common, &meta)
        .unwrap_or_else(|| {
            order_by_gev(&mut prototypes, &peak_maps);
            (
                vec![None; prototypes.len()],
                (0..prototypes.len()).map(state_label).collect(),
            )
        });
    let channel_positions = scalp_positions(&common, &meta);
    progress(52, "Backfitting and smoothing sequences");

    let mut results = Vec::new();
    // sequences.py seeds NumPy's legacy RandomState once, then shuffles each
    // recording in order.  Keep the same MT19937 stream for exact parity.
    let mut sequence_rng = NumpyMt19937::new(options.seed as u32);
    for (ri, p) in prepared.iter().enumerate() {
        let (mut labels, correlations) = backfit(&p.data, &prototypes);
        smooth_short_segments(&mut labels, &correlations, p.rate, options.min_segment_ms);
        let state_stats = calculate_stats(p, &labels, &correlations, &prototypes, &state_labels);
        let transition_matrix = transitions(&labels, selected);
        let seq_stats = sequence_stats(&labels, &mut sequence_rng);
        let filename = p.name.clone();
        let plot_name = format!("{}.microstates.svg", safe_stem(&filename));
        write_sequence_svg(&output_dir.join(&plot_name), p, &labels, &prototypes)?;
        let gev_total = state_stats.iter().map(|s| s.gev).sum();
        results.push(RecordingResult {
            filename,
            sample_rate: p.rate,
            sample_count: labels.len(),
            gev_total,
            states: state_stats,
            transition_matrix,
            sequence: labels.iter().map(|x| x + 1).collect(),
            sequence_metrics: seq_stats,
            sequence_plot: plot_name,
        });
        progress(
            52 + (ri + 1) * 30 / prepared.len(),
            "Computed recording statistics",
        );
    }

    let topo_name = "TemplateMicrostateTopos.svg".to_string();
    write_topographies_svg(
        &output_dir.join(&topo_name),
        &channel_positions,
        &prototypes,
        &canonical_correlations,
        &state_labels,
    )?;
    let stats_name = "MicrostateAnalysisResults.csv".to_string();
    let sequence_name = "MicrostateSequenceMetrics.csv".to_string();
    let transitions_name = "MicrostateTransitions.csv".to_string();
    let categorical_name = "Categorical_Summary_Counts.csv".to_string();
    write_stats_csv(&output_dir.join(&stats_name), &results)?;
    write_sequence_csv(&output_dir.join(&sequence_name), &results)?;
    write_transitions_csv(&output_dir.join(&transitions_name), &results)?;
    write_categorical_csv(&output_dir.join(&categorical_name), &results)?;
    let result = MicrostateResult {
        algorithm: "polarity-invariant modified k-means (EEGLAB Microstate parity)".into(),
        selected_states: selected,
        state_labels,
        channel_labels: common,
        channel_positions,
        prototypes,
        canonical_correlations,
        model_fits: models.into_iter().map(|m| m.1).collect(),
        recordings: results,
        statistics_csv: stats_name,
        sequence_metrics_csv: sequence_name,
        transitions_csv: transitions_name,
        categorical_summary_csv: categorical_name,
        template_plot: topo_name,
    };
    fs::write(
        output_dir.join("microstates.json"),
        serde_json::to_vec_pretty(&result).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    progress(100, "Microstate analysis complete");
    Ok(result)
}

fn is_eeg(label: &str) -> bool {
    let x = label.to_ascii_lowercase();
    ![
        "annotation",
        "status",
        "ecg",
        "ekg",
        "eog",
        "emg",
        "trigger",
        "stim",
        "resp",
        "gsr",
        "ppg",
        "acc",
        "gyro",
    ]
    .iter()
    .any(|term| x.contains(term))
}

fn common_labels(recordings: &[(String, Recording)]) -> Result<Vec<String>, String> {
    let first = recordings.first().ok_or("no recordings")?;
    Ok(first
        .1
        .labels
        .iter()
        .filter(|l| is_eeg(l))
        .filter(|l| {
            recordings
                .iter()
                .all(|(_, r)| r.labels.iter().any(|x| x.eq_ignore_ascii_case(l)))
        })
        .cloned()
        .collect())
}

fn prepare(name: String, r: Recording, common: &[String]) -> Result<Prepared, String> {
    let n = r.channels.iter().map(Vec::len).min().unwrap_or(0);
    if n < 3 || r.rate <= 0.0 {
        return Err(format!("{name}: recording is empty"));
    }
    let mut data = Vec::new();
    for label in common {
        let i = r
            .labels
            .iter()
            .position(|x| x.eq_ignore_ascii_case(label))
            .ok_or_else(|| format!("{name}: channel {label} is missing"))?;
        data.push(
            r.channels[i][..n]
                .iter()
                .map(|x| *x as f64)
                .collect::<Vec<_>>(),
        );
    }
    for t in 0..n {
        let mean = data.iter().map(|c| c[t]).sum::<f64>() / data.len() as f64;
        for c in &mut data {
            c[t] -= mean;
        }
    }
    // pop_micro_selectdata(... normalise=1): equalise channel variance before
    // pooling datasets, then re-reference each sample.
    for c in &mut data {
        let mean = c.iter().sum::<f64>() / n as f64;
        let sd = (c.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n as f64).sqrt();
        if sd > 1e-12 {
            for v in c {
                *v /= sd;
            }
        }
    }
    for t in 0..n {
        let mean = data.iter().map(|c| c[t]).sum::<f64>() / data.len() as f64;
        for c in &mut data {
            c[t] -= mean;
        }
    }
    let gfp = (0..n)
        .map(|t| (data.iter().map(|c| c[t] * c[t]).sum::<f64>() / data.len() as f64).sqrt())
        .collect();
    Ok(Prepared {
        name,
        rate: r.rate,
        data,
        gfp,
    })
}

fn select_peaks(p: &Prepared, o: &MicrostateOptions) -> Vec<usize> {
    let mean = p.gfp.iter().sum::<f64>() / p.gfp.len() as f64;
    let sd = (p.gfp.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / p.gfp.len() as f64).sqrt();
    let ceiling = mean + o.gfp_threshold_sd * sd;
    let distance = ((o.min_peak_distance_ms * p.rate / 1000.0).round() as usize).max(1);
    let mut candidates: Vec<usize> = (1..p.gfp.len() - 1)
        .filter(|i| p.gfp[*i] >= p.gfp[*i - 1] && p.gfp[*i] > p.gfp[*i + 1] && p.gfp[*i] <= ceiling)
        .collect();
    candidates.sort_by(|a, b| p.gfp[*b].total_cmp(&p.gfp[*a]));
    let mut selected = Vec::new();
    for i in candidates {
        if selected.iter().all(|j: &usize| i.abs_diff(*j) >= distance) {
            selected.push(i);
            if selected.len() == o.peaks_per_recording {
                break;
            }
        }
    }
    selected.sort_unstable();
    selected
}

fn normalize(v: &mut [f64]) {
    let mean = v.iter().sum::<f64>() / v.len() as f64;
    for x in v.iter_mut() {
        *x -= mean;
    }
    let norm = v.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm > 1e-15 {
        for x in v {
            *x /= norm;
        }
    }
}

fn corr(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn modified_kmeans(
    maps: &[Vec<f64>],
    k: usize,
    o: &MicrostateOptions,
) -> Result<(Vec<Vec<f64>>, f64, f64), String> {
    let mut best: Option<(Vec<Vec<f64>>, f64, f64)> = None;
    for rep in 0..o.repetitions.max(1) {
        let mut rng = StableRng::new(o.seed.wrapping_add((k * 1009 + rep) as u64));
        let mut chosen = Vec::new();
        while chosen.len() < k {
            let x = rng.index(maps.len());
            if !chosen.contains(&x) {
                chosen.push(x);
            }
        }
        let mut prototypes: Vec<Vec<f64>> = chosen
            .iter()
            .map(|i| {
                let mut v = maps[*i].clone();
                normalize(&mut v);
                v
            })
            .collect();
        let mut previous = f64::NEG_INFINITY;
        for _ in 0..o.max_iterations.max(1) {
            let assignments: Vec<usize> = maps
                .iter()
                .map(|m| {
                    prototypes
                        .iter()
                        .enumerate()
                        .max_by(|a, b| corr(m, a.1).abs().total_cmp(&corr(m, b.1).abs()))
                        .unwrap()
                        .0
                })
                .collect();
            for state in 0..k {
                let members: Vec<&Vec<f64>> = maps
                    .iter()
                    .zip(&assignments)
                    .filter_map(|(m, a)| (*a == state).then_some(m))
                    .collect();
                if members.is_empty() {
                    prototypes[state] = maps[rng.index(maps.len())].clone();
                    normalize(&mut prototypes[state]);
                    continue;
                }
                prototypes[state] = first_component(&members);
            }
            let gev = peak_gev(maps, &prototypes);
            if (gev - previous).abs() <= o.convergence {
                break;
            }
            previous = gev;
        }
        let gev = peak_gev(maps, &prototypes);
        let residual = 1.0 - gev;
        if best.as_ref().map(|b| gev > b.1).unwrap_or(true) {
            best = Some((prototypes, gev, residual));
        }
    }
    best.ok_or("modified k-means did not produce a model".into())
}

fn first_component(members: &[&Vec<f64>]) -> Vec<f64> {
    let c = members[0].len();
    let mut cov = DMatrix::<f64>::zeros(c, c);
    for m in members {
        for i in 0..c {
            for j in i..c {
                cov[(i, j)] += m[i] * m[j];
            }
        }
    }
    for i in 0..c {
        for j in 0..i {
            cov[(i, j)] = cov[(j, i)];
        }
    }
    let eig = SymmetricEigen::new(cov);
    let index = eig
        .eigenvalues
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.total_cmp(b.1))
        .unwrap()
        .0;
    let mut v: Vec<f64> = eig.eigenvectors.column(index).iter().copied().collect();
    normalize(&mut v);
    v
}

fn peak_gev(maps: &[Vec<f64>], prototypes: &[Vec<f64>]) -> f64 {
    maps.iter()
        .map(|m| {
            prototypes
                .iter()
                .map(|p| corr(m, p).powi(2))
                .fold(0.0, f64::max)
        })
        .sum::<f64>()
        / maps.len() as f64
}

fn order_by_gev(prototypes: &mut Vec<Vec<f64>>, maps: &[Vec<f64>]) {
    prototypes.sort_by(|a, b| {
        let ga = maps.iter().map(|m| corr(m, a).powi(2)).sum::<f64>();
        let gb = maps.iter().map(|m| corr(m, b).powi(2)).sum::<f64>();
        gb.total_cmp(&ga)
    });
}

fn load_metamaps() -> Result<MetaMapsResource, String> {
    serde_json::from_str(include_str!("../resources/metamaps_2023_06.json"))
        .map_err(|e| format!("invalid bundled MetaMaps resource: {e}"))
}

fn canonical_label(label: &str) -> String {
    let value = label.trim().to_ascii_uppercase();
    match value.as_str() {
        "T3" => "T7/T3".into(),
        "T4" => "T8/T4".into(),
        "T5" => "P7/T5".into(),
        "T6" => "P8/T6".into(),
        _ => value,
    }
}

/// Reproduce accs_CompareTemplateMaps ordering. Canonical maps are resampled
/// from the 71-channel MetaMaps montage onto the recording montage with the
/// same Perrin spherical spline used by accs_splint2.m (m=4, orders 1..7).
fn order_by_metamaps(
    prototypes: &mut Vec<Vec<f64>>,
    labels: &[String],
    meta: &MetaMapsResource,
) -> Option<(Vec<Option<f64>>, Vec<String>)> {
    let solution_count = prototypes.len().min(7).max(4);
    let canonical = meta.solutions.get(&solution_count.to_string())?;
    let meta_index: HashMap<String, usize> = meta
        .channels
        .iter()
        .enumerate()
        .map(|(i, c)| (canonical_label(&c.label), i))
        .collect();
    let local_indices: Vec<usize> = labels
        .iter()
        .map(|label| meta_index.get(&canonical_label(label)).copied())
        .collect::<Option<_>>()?;
    if local_indices.len() < 4 {
        return None;
    }
    let source_xyz: Vec<[f64; 3]> = meta.channels.iter().map(|c| [c.x, c.y, c.z]).collect();
    let target_xyz: Vec<[f64; 3]> = local_indices
        .iter()
        .map(|i| {
            let c = &meta.channels[*i];
            [c.x, c.y, c.z]
        })
        .collect();
    let resampled = spherical_spline_resample(&source_xyz, canonical, &target_xyz)?;
    let matrix: Vec<Vec<f64>> = resampled
        .iter()
        .map(|reference| {
            prototypes
                .iter()
                .map(|learned_map| pearson(learned_map, reference))
                .collect()
        })
        .collect();
    // accs_CompareTemplateMaps assigns canonical rows in order. This is
    // intentional: established A-D maps retain priority over later classes.
    let assignment = priority_assignment(&matrix, 0.5);
    let mut available: Vec<usize> = (0..prototypes.len()).collect();
    let mut ordered = Vec::new();
    let mut correlations = Vec::new();
    let mut labels_out = Vec::new();
    for (template, candidate) in assignment.iter().enumerate() {
        let Some(candidate) = *candidate else {
            continue;
        };
        let signed = matrix[template][candidate];
        let mut map = prototypes[candidate].clone();
        if signed < 0.0 {
            for value in &mut map {
                *value = -*value;
            }
        }
        ordered.push(map);
        correlations.push(Some(signed.abs()));
        labels_out.push(state_label(template));
        available.retain(|x| *x != candidate);
    }
    // MetaMaps has at most seven canonical maps; retain extra learned states
    // after A-G in descending GEV order instead of discarding them.
    for (unmatched, candidate) in available.into_iter().enumerate() {
        ordered.push(prototypes[candidate].clone());
        correlations.push(None);
        labels_out.push(format!("U{}", unmatched + 1));
    }
    *prototypes = ordered;
    Some((correlations, labels_out))
}

fn spherical_spline_resample(
    source_xyz: &[[f64; 3]],
    maps: &[Vec<f64>],
    target_xyz: &[[f64; 3]],
) -> Option<Vec<Vec<f64>>> {
    let source: Vec<[f64; 3]> = source_xyz.iter().copied().map(unit_xyz).collect();
    let target: Vec<[f64; 3]> = target_xyz.iter().copied().map(unit_xyz).collect();
    let n = source.len();
    let t = maps.len();
    if n == 0 || t == 0 || maps.iter().any(|map| map.len() != n) {
        return None;
    }

    // H = [0, 1'; 1, G] and RHS = [0; Z], matching accs_splint2.m.
    let mut h = DMatrix::from_element(n + 1, n + 1, 1.0);
    h[(0, 0)] = 0.0;
    for row in 0..n {
        for column in 0..n {
            h[(row + 1, column + 1)] = spline_g(source[row], source[column]);
        }
    }
    let mut rhs = DMatrix::zeros(n + 1, t);
    for (column, map) in maps.iter().enumerate() {
        for (row, value) in map.iter().enumerate() {
            rhs[(row + 1, column)] = *value;
        }
    }
    let coefficients = h.lu().solve(&rhs)?;
    let mut output = vec![vec![0.0; target.len()]; t];
    for (target_index, point) in target.iter().enumerate() {
        for map_index in 0..t {
            let mut value = coefficients[(0, map_index)];
            for source_index in 0..n {
                value += spline_g(*point, source[source_index])
                    * coefficients[(source_index + 1, map_index)];
            }
            output[map_index][target_index] = value;
        }
    }
    Some(output)
}

fn unit_xyz(point: [f64; 3]) -> [f64; 3] {
    let length = (point[0] * point[0] + point[1] * point[1] + point[2] * point[2])
        .sqrt()
        .max(1e-15);
    [point[0] / length, point[1] / length, point[2] / length]
}

fn spline_g(a: [f64; 3], b: [f64; 3]) -> f64 {
    let distance = ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt();
    let x = 1.0 - distance;
    let (mut p0, mut p1) = (1.0, x);
    let mut sum = 0.0;
    for order in 1..=7 {
        let pn = if order == 1 {
            p1
        } else {
            let next = ((2 * order - 1) as f64 * x * p1 - (order - 1) as f64 * p0) / order as f64;
            p0 = p1;
            p1 = next;
            next
        };
        let order = order as f64;
        sum += (2.0 * order + 1.0) / (order.powi(4) * (order + 1.0).powi(4)) * pn;
    }
    sum / (4.0 * PI)
}

fn priority_assignment(matrix: &[Vec<f64>], threshold: f64) -> Vec<Option<usize>> {
    let columns = matrix.first().map(Vec::len).unwrap_or(0);
    let mut available = vec![true; columns];
    matrix
        .iter()
        .map(|row| {
            let best = row
                .iter()
                .enumerate()
                .filter(|(column, _)| available[*column])
                .max_by(|a, b| a.1.abs().total_cmp(&b.1.abs()));
            match best {
                Some((column, value)) if value.abs() > threshold => {
                    available[column] = false;
                    Some(column)
                }
                _ => None,
            }
        })
        .collect()
}

fn pearson(a: &[f64], b: &[f64]) -> f64 {
    let am = a.iter().sum::<f64>() / a.len() as f64;
    let bm = b.iter().sum::<f64>() / b.len() as f64;
    let mut numerator = 0.0;
    let mut aa = 0.0;
    let mut bb = 0.0;
    for (x, y) in a.iter().zip(b) {
        numerator += (x - am) * (y - bm);
        aa += (x - am).powi(2);
        bb += (y - bm).powi(2);
    }
    numerator / (aa * bb).sqrt().max(1e-15)
}

fn scalp_positions(labels: &[String], meta: &MetaMapsResource) -> Vec<ScalpPosition> {
    let lookup: HashMap<String, &MetaChannel> = meta
        .channels
        .iter()
        .map(|c| (canonical_label(&c.label), c))
        .collect();
    labels
        .iter()
        .enumerate()
        .map(|(i, label)| {
            if let Some(channel) = lookup.get(&canonical_label(label)) {
                let theta = channel.theta.to_radians();
                ScalpPosition {
                    label: label.clone(),
                    x: (channel.radius * theta.sin() / 0.5).clamp(-1.0, 1.0),
                    y: (channel.radius * theta.cos() / 0.5).clamp(-1.0, 1.0),
                }
            } else {
                let (x, y) = channel_xy(label, i, labels.len());
                ScalpPosition {
                    label: label.clone(),
                    x,
                    y: -y,
                }
            }
        })
        .collect()
}

fn backfit(data: &[Vec<f64>], prototypes: &[Vec<f64>]) -> (Vec<usize>, Vec<Vec<f64>>) {
    let n = data[0].len();
    let mut labels = vec![0; n];
    let mut correlations = vec![vec![0.0; n]; prototypes.len()];
    for t in 0..n {
        let mut map: Vec<f64> = data.iter().map(|c| c[t]).collect();
        normalize(&mut map);
        for (s, p) in prototypes.iter().enumerate() {
            correlations[s][t] = corr(&map, p).abs();
        }
        labels[t] = (0..prototypes.len())
            .max_by(|a, b| correlations[*a][t].total_cmp(&correlations[*b][t]))
            .unwrap();
    }
    (labels, correlations)
}

fn smooth_short_segments(labels: &mut [usize], correlations: &[Vec<f64>], rate: f64, min_ms: f64) {
    let minimum = ((min_ms * rate / 1000.0).round() as usize).max(1);
    for _ in 0..labels.len().max(1) {
        let runs = runs(labels);
        let short = runs.iter().position(|(_, a, b)| b - a < minimum);
        let Some(i) = short else { break };
        let (_, a, b) = runs[i];
        let replacement = if i == 0 {
            runs.get(1).map(|r| r.0)
        } else if i + 1 == runs.len() {
            Some(runs[i - 1].0)
        } else {
            let left = runs[i - 1].0;
            let right = runs[i + 1].0;
            let ls = (a..b).map(|t| correlations[left][t]).sum::<f64>();
            let rs = (a..b).map(|t| correlations[right][t]).sum::<f64>();
            Some(if ls >= rs { left } else { right })
        };
        if let Some(s) = replacement {
            labels[a..b].fill(s);
        } else {
            break;
        }
    }
}

fn runs(labels: &[usize]) -> Vec<(usize, usize, usize)> {
    if labels.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut a = 0;
    for i in 1..=labels.len() {
        if i == labels.len() || labels[i] != labels[a] {
            out.push((labels[a], a, i));
            a = i;
        }
    }
    out
}

fn calculate_stats(
    p: &Prepared,
    labels: &[usize],
    correlations: &[Vec<f64>],
    prototypes: &[Vec<f64>],
    state_labels: &[String],
) -> Vec<StateStats> {
    let total_gfp2 = p.gfp.iter().map(|x| x * x).sum::<f64>().max(1e-15);
    let rr = runs(labels);
    let duration = labels.len() as f64 / p.rate;
    (0..prototypes.len())
        .map(|s| {
            let samples: Vec<usize> = labels
                .iter()
                .enumerate()
                .filter_map(|(i, x)| (*x == s).then_some(i))
                .collect();
            let segments: Vec<_> = rr.iter().filter(|r| r.0 == s).collect();
            let coverage = samples.len() as f64 / labels.len() as f64;
            StateStats {
                label: state_labels[s].clone(),
                mean_gfp: mean(samples.iter().map(|i| p.gfp[*i])),
                occurrence_hz: segments.len() as f64 / duration,
                mean_duration_ms: mean(
                    segments
                        .iter()
                        .map(|r| (r.2 - r.1) as f64 / p.rate * 1000.0),
                ),
                coverage,
                gev: samples
                    .iter()
                    .map(|i| p.gfp[*i].powi(2) * correlations[s][*i].powi(2))
                    .sum::<f64>()
                    / total_gfp2,
                mean_spatial_correlation: mean(samples.iter().map(|i| correlations[s][*i])),
            }
        })
        .collect()
}

fn mean<I: Iterator<Item = f64>>(it: I) -> f64 {
    let v: Vec<f64> = it.collect();
    if v.is_empty() {
        0.0
    } else {
        v.iter().sum::<f64>() / v.len() as f64
    }
}

fn transitions(labels: &[usize], k: usize) -> Vec<Vec<f64>> {
    let mut m = vec![vec![0.0; k]; k];
    for w in labels.windows(2) {
        m[w[0]][w[1]] += 1.0;
    }
    // Python reference divides by total transitions, not per-row totals.
    let total = labels.len().saturating_sub(1) as f64;
    if total > 0.0 {
        for row in &mut m {
            for x in row {
                *x /= total;
            }
        }
    }
    m
}

fn sequence_stats(labels: &[usize], rng: &mut NumpyMt19937) -> SequenceStats {
    let actual = lz_complexity(labels);
    let mut shuffled = labels.to_vec();
    for i in (1..shuffled.len()).rev() {
        let j = rng.interval(i);
        shuffled.swap(i, j);
    }
    let normal = lz_complexity(&shuffled);
    let durations: Vec<f64> = runs(labels).iter().map(|r| (r.2 - r.1) as f64).collect();
    let dm = if durations.is_empty() {
        0.0
    } else {
        durations.iter().sum::<f64>() / durations.len() as f64
    };
    let mdv = if durations.is_empty() {
        0.0
    } else {
        durations.iter().map(|x| (x - dm).powi(2)).sum::<f64>() / durations.len() as f64
    };
    let p = transitions(labels, labels.iter().max().copied().unwrap_or(0) + 1);
    let mut ep = 0.0;
    for i in 0..p.len() {
        for j in 0..p.len() {
            if p[i][j] > 0.0 && p[j][i] > 0.0 {
                ep += p[i][j] * (p[i][j] / p[j][i]).ln();
            }
        }
    }
    SequenceStats {
        lz_complexity: actual,
        shuffled_lz_complexity: normal,
        normalized_lz: if normal > 0 {
            actual as f64 / normal as f64
        } else {
            0.0
        },
        duration_variance_samples2: mdv,
        entropy_production: ep,
    }
}

// Exhaustive LZ76 parser, matching antropy.lziv_complexity(..., normalize=False).
fn lz_complexity(seq: &[usize]) -> usize {
    let n = seq.len();
    if n == 0 {
        return 0;
    }
    if n == 1 {
        return 1;
    }
    let (mut complexity, mut prefix, mut cursor, mut matched, mut best) =
        (1usize, 1usize, 0usize, 1usize, 1usize);
    loop {
        if prefix + matched >= n {
            return complexity + 1;
        }
        if seq[cursor + matched - 1] == seq[prefix + matched - 1] {
            matched += 1;
            if prefix + matched > n {
                return complexity + 1;
            }
        } else {
            best = best.max(matched);
            cursor += 1;
            if cursor == prefix {
                complexity += 1;
                prefix += best;
                if prefix >= n {
                    return complexity;
                }
                cursor = 0;
                matched = 1;
                best = 1
            } else {
                matched = 1
            }
        }
    }
}

fn state_label(i: usize) -> String {
    if i < 26 {
        ((b'A' + i as u8) as char).to_string()
    } else {
        format!("S{}", i + 1)
    }
}
fn safe_stem(s: &str) -> String {
    Path::new(s)
        .file_stem()
        .and_then(|x| x.to_str())
        .unwrap_or("recording")
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn write_stats_csv(path: &Path, results: &[RecordingResult]) -> Result<(), String> {
    let mut f = fs::File::create(path).map_err(|e| e.to_string())?;
    let k = results.first().map(|r| r.states.len()).unwrap_or(0);
    let mut h = vec!["filename".to_string(), "GEVtotal".to_string()];
    for field in [
        "Gfp",
        "Occurrence",
        "Duration",
        "Coverage",
        "GEV",
        "MspatCorr",
        "TP",
    ] {
        for s in 0..k {
            h.push(format!("{}_{}", field, results[0].states[s].label))
        }
    }
    writeln!(f, "{}", h.join(",")).map_err(|e| e.to_string())?;
    for r in results {
        let mut v = vec![csv(&r.filename), fmt(r.gev_total)];
        for field in 0..7 {
            for (state_index, s) in r.states.iter().enumerate() {
                v.push(fmt(match field {
                    0 => s.mean_gfp,
                    1 => s.occurrence_hz,
                    2 => s.mean_duration_ms,
                    3 => s.coverage,
                    4 => s.gev,
                    5 => s.mean_spatial_correlation,
                    _ => mean(
                        r.transition_matrix
                            .iter()
                            .map(|row| row[state_index])
                            .filter(|x| *x > 0.0),
                    ),
                }))
            }
        }
        writeln!(f, "{}", v.join(",")).map_err(|e| e.to_string())?
    }
    Ok(())
}
fn write_sequence_csv(path: &Path, results: &[RecordingResult]) -> Result<(), String> {
    let mut f = fs::File::create(path).map_err(|e| e.to_string())?;
    writeln!(f, "Filename,Subject_ID,Cognitive_State,Drowsiness,Time,Self_Reference,Valence,Modality,Intensity_Rating,Epoch,Normalized_LZ,MDV,EP,LZ,LZ_Shuffled")
        .map_err(|e| e.to_string())?;
    for r in results {
        let s = &r.sequence_metrics;
        let filename = safe_stem(&r.filename);
        let metadata = extract_metadata(&filename);
        writeln!(
            f,
            "{},{},{},{},{},{},{}",
            csv(&filename),
            metadata
                .iter()
                .map(|x| csv(x))
                .collect::<Vec<_>>()
                .join(","),
            fmt(s.normalized_lz),
            fmt(s.duration_variance_samples2),
            fmt(s.entropy_production),
            s.lz_complexity,
            s.shuffled_lz_complexity
        )
        .map_err(|e| e.to_string())?
    }
    Ok(())
}

fn extract_metadata(filename: &str) -> Vec<String> {
    for state in ["AttentiveMW", "MW", "Attentive"] {
        let marker = format!("_{state}_");
        if let Some((prefix, rest)) = filename.split_once(&marker) {
            let mut parts: Vec<&str> = rest.split('_').collect();
            while parts.len() < 8 {
                parts.push("");
            }
            let subject = prefix.split('_').next().unwrap_or(prefix);
            let value = |i: usize| if parts[i].is_empty() { "NA" } else { parts[i] };
            return vec![
                subject,
                state,
                value(0),
                value(1),
                value(2),
                value(3),
                value(4),
                value(5),
                value(6),
            ]
            .into_iter()
            .map(str::to_string)
            .collect();
        }
    }
    vec!["NA".to_string(); 9]
}

fn write_categorical_csv(path: &Path, results: &[RecordingResult]) -> Result<(), String> {
    const COLUMNS: [&str; 7] = [
        "Cognitive_State",
        "Drowsiness",
        "Time",
        "Self_Reference",
        "Valence",
        "Modality",
        "Intensity_Rating",
    ];
    const OFFSETS: [usize; 7] = [1, 2, 3, 4, 5, 6, 7];
    let mut counts: BTreeMap<(usize, String), usize> = BTreeMap::new();
    for r in results {
        let metadata = extract_metadata(&safe_stem(&r.filename));
        for (column, offset) in OFFSETS.iter().enumerate() {
            *counts
                .entry((column, metadata[*offset].clone()))
                .or_default() += 1;
        }
    }
    let mut f = fs::File::create(path).map_err(|e| e.to_string())?;
    writeln!(f, "Variable,Category,Count").map_err(|e| e.to_string())?;
    for ((column, category), count) in counts {
        writeln!(f, "{},{},{}", COLUMNS[column], csv(&category), count)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn write_transitions_csv(path: &Path, results: &[RecordingResult]) -> Result<(), String> {
    let mut f = fs::File::create(path).map_err(|e| e.to_string())?;
    writeln!(f, "filename,from_state,to_state,probability").map_err(|e| e.to_string())?;
    for r in results {
        for (i, row) in r.transition_matrix.iter().enumerate() {
            for (j, p) in row.iter().enumerate() {
                writeln!(
                    f,
                    "{},{},{},{}",
                    csv(&r.filename),
                    r.states[i].label,
                    r.states[j].label,
                    fmt(*p)
                )
                .map_err(|e| e.to_string())?
            }
        }
    }
    Ok(())
}
fn fmt(x: f64) -> String {
    format!("{x:.10}")
}
fn csv(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.into()
    }
}

fn write_topographies_svg(
    path: &Path,
    positions: &[ScalpPosition],
    prototypes: &[Vec<f64>],
    correlations: &[Option<f64>],
    state_labels: &[String],
) -> Result<(), String> {
    const CELL: usize = 210;
    const GRID: usize = 56;
    let columns = prototypes.len().min(4);
    let rows = prototypes.len().div_ceil(columns);
    let w = CELL * columns;
    let h = 250 * rows;
    let mut s = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><rect width="100%" height="100%" fill="#0f172a"/>"##
    );
    for (st, map) in prototypes.iter().enumerate() {
        let row = st / columns;
        let column = st % columns;
        let top = row as f64 * 250.0;
        let cx = CELL as f64 * (column as f64 + 0.5);
        let cy = top + 128.0;
        let radius = 78.0;
        let absmax = map.iter().map(|x| x.abs()).fold(0.0, f64::max).max(1e-12);
        let subtitle = correlations
            .get(st)
            .copied()
            .flatten()
            .map(|r| format!("MetaMap r={r:.2}"))
            .unwrap_or_else(|| "additional GEV state".into());
        s.push_str(&format!(r##"<text x="{cx}" y="{}" text-anchor="middle" fill="white" font-family="sans-serif" font-size="15" font-weight="600">State {}</text><text x="{cx}" y="{}" text-anchor="middle" fill="#94a3b8" font-family="sans-serif" font-size="9">{subtitle}</text><defs><clipPath id="head{st}"><circle cx="{cx}" cy="{cy}" r="{radius}"/></clipPath></defs><g clip-path="url(#head{st})">"##,top+20.0,state_labels[st],top+36.0));
        let step = radius * 2.0 / GRID as f64;
        for gy in 0..GRID {
            for gx in 0..GRID {
                let nx = -1.0 + (gx as f64 + 0.5) * 2.0 / GRID as f64;
                let ny = 1.0 - (gy as f64 + 0.5) * 2.0 / GRID as f64;
                if nx * nx + ny * ny > 1.0 {
                    continue;
                }
                let value = interpolate_topography(nx, ny, positions, map) / absmax;
                s.push_str(&format!(
                    r#"<rect x="{:.2}" y="{:.2}" width="{:.2}" height="{:.2}" fill="{}"/>"#,
                    cx - radius + gx as f64 * step,
                    cy - radius + gy as f64 * step,
                    step + 0.4,
                    step + 0.4,
                    diverging(value)
                ));
            }
        }
        s.push_str("</g>");
        // Standard EEGLAB-style head outline, nose, ears, and electrodes.
        s.push_str(&format!(r##"<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="#e2e8f0" stroke-width="2.2"/><path d="M {} {} L {cx} {} L {} {}" fill="none" stroke="#e2e8f0" stroke-width="2.2" stroke-linejoin="round"/><path d="M {} {} C {} {},{} {},{} {} C {} {},{} {},{} {}" fill="none" stroke="#e2e8f0" stroke-width="2"/><path d="M {} {} C {} {},{} {},{} {} C {} {},{} {},{} {}" fill="none" stroke="#e2e8f0" stroke-width="2"/>"##,cx-14.0,cy-radius+3.0,cy-radius-17.0,cx+14.0,cy-radius+3.0,cx-radius-1.0,cy-20.0,cx-radius-14.0,cy-16.0,cx-radius-14.0,cy+12.0,cx-radius-2.0,cy+22.0,cx-radius-8.0,cy+9.0,cx-radius-7.0,cy-8.0,cx-radius-1.0,cy-20.0,cx+radius+1.0,cy-20.0,cx+radius+14.0,cy-16.0,cx+radius+14.0,cy+12.0,cx+radius+2.0,cy+22.0,cx+radius+8.0,cy+9.0,cx+radius+7.0,cy-8.0,cx+radius+1.0,cy-20.0));
        for position in positions {
            s.push_str(&format!(r##"<circle cx="{:.2}" cy="{:.2}" r="1.8" fill="#0f172a" stroke="#f8fafc" stroke-width="0.55"/>"##,cx+position.x*radius*0.92,cy-position.y*radius*0.92));
        }
        // Symmetric blue-white-red scale communicates polarity explicitly.
        for i in 0..48 {
            let value = -1.0 + 2.0 * (i as f64 + 0.5) / 48.0;
            s.push_str(&format!(
                r#"<rect x="{:.2}" y="{:.2}" width="{:.2}" height="7" fill="{}"/>"#,
                cx - radius + i as f64 * (radius * 2.0 / 48.0),
                top + 220.0,
                radius * 2.0 / 48.0 + 0.2,
                diverging(value)
            ));
        }
        s.push_str(&format!(r##"<text x="{}" y="{}" fill="#94a3b8" font-family="sans-serif" font-size="8">−</text><text x="{}" y="{}" fill="#94a3b8" font-family="sans-serif" font-size="8">0</text><text x="{}" y="{}" fill="#94a3b8" font-family="sans-serif" font-size="8">+</text>"##,cx-radius,top+240.0,cx-2.5,top+240.0,cx+radius-5.0,top+240.0));
    }
    s.push_str("</svg>");
    fs::write(path, s).map_err(|e| e.to_string())
}

fn interpolate_topography(x: f64, y: f64, positions: &[ScalpPosition], values: &[f64]) -> f64 {
    let mut weighted = 0.0;
    let mut weights = 0.0;
    for (position, value) in positions.iter().zip(values) {
        let d2 = (x - position.x).powi(2) + (y - position.y).powi(2);
        if d2 < 1e-8 {
            return *value;
        }
        let weight = 1.0 / d2.powf(1.5);
        weighted += value * weight;
        weights += weight;
    }
    weighted / weights.max(1e-15)
}

fn diverging(value: f64) -> String {
    let v = value.clamp(-1.0, 1.0);
    let (r, g, b) = if v < 0.0 {
        let t = v + 1.0;
        (59.0 + 196.0 * t, 76.0 + 179.0 * t, 192.0 + 63.0 * t)
    } else {
        (255.0, 255.0 - 197.0 * v, 255.0 - 207.0 * v)
    };
    format!("#{:02x}{:02x}{:02x}", r as u8, g as u8, b as u8)
}
fn channel_xy(label: &str, index: usize, n: usize) -> (f64, f64) {
    let key = label.to_ascii_uppercase();
    let known: HashMap<&str, (f64, f64)> = [
        ("FP1", (-0.35, -0.88)),
        ("FP2", (0.35, -0.88)),
        ("AF3", (-0.30, -0.72)),
        ("AF4", (0.30, -0.72)),
        ("F7", (-0.82, -0.52)),
        ("F3", (-0.38, -0.48)),
        ("FZ", (0.0, -0.50)),
        ("F4", (0.38, -0.48)),
        ("F8", (0.82, -0.52)),
        ("FT7", (-0.90, -0.20)),
        ("FC3", (-0.42, -0.22)),
        ("FCZ", (0.0, -0.22)),
        ("FC4", (0.42, -0.22)),
        ("FT8", (0.90, -0.20)),
        ("T3", (-0.95, 0.0)),
        ("C3", (-0.45, 0.0)),
        ("CZ", (0.0, 0.0)),
        ("C4", (0.45, 0.0)),
        ("T4", (0.95, 0.0)),
        ("TP7", (-0.90, 0.28)),
        ("CP3", (-0.42, 0.28)),
        ("CPZ", (0.0, 0.28)),
        ("CP4", (0.42, 0.28)),
        ("TP8", (0.90, 0.28)),
        ("T5", (-0.78, 0.55)),
        ("P3", (-0.38, 0.52)),
        ("P4", (0.38, 0.52)),
        ("T6", (0.78, 0.55)),
        ("O1", (-0.30, 0.82)),
        ("O2", (0.30, 0.82)),
    ]
    .into_iter()
    .collect();
    known.get(key.as_str()).copied().unwrap_or_else(|| {
        let a = 2.0 * PI * index as f64 / n as f64;
        (a.sin() * 0.85, -a.cos() * 0.85)
    })
}
fn write_sequence_svg(
    path: &Path,
    p: &Prepared,
    labels: &[usize],
    prototypes: &[Vec<f64>],
) -> Result<(), String> {
    let width = 1200.0;
    let mut s = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="220" viewBox="0 0 1200 220"><rect width="100%" height="100%" fill="#0f172a"/><text x="25" y="25" fill="white" font-family="sans-serif">{}</text>"##,
        p.name
    );
    let colors = [
        "#3b82f6", "#22c55e", "#f59e0b", "#a855f7", "#06b6d4", "#ec4899", "#ef4444", "#84cc16",
    ];
    for (st, a, b) in runs(labels) {
        let x = 25.0 + a as f64 / labels.len() as f64 * (width - 50.0);
        let w = (b - a) as f64 / labels.len() as f64 * (width - 50.0);
        s.push_str(&format!(
            r#"<rect x="{x}" y="48" width="{}" height="55" fill="{}"/>"#,
            w.max(0.5),
            colors[st % colors.len()]
        ));
    }
    let max = p.gfp.iter().copied().fold(0.0, f64::max).max(1e-12);
    let points = p
        .gfp
        .iter()
        .enumerate()
        .step_by((p.gfp.len() / 1100).max(1))
        .map(|(i, v)| {
            format!(
                "{:.1},{:.1}",
                25.0 + i as f64 / p.gfp.len() as f64 * (width - 50.0),
                190.0 - v / max * 65.0
            )
        })
        .collect::<Vec<_>>()
        .join(" ");
    s.push_str(&format!(r##"<polyline points="{points}" fill="none" stroke="#94a3b8" stroke-width="1"/><text x="25" y="120" fill="#94a3b8" font-family="sans-serif" font-size="11">GFP and smoothed sequence · {} states · {:.1} s</text></svg>"##, prototypes.len(), labels.len() as f64 / p.rate));
    fs::write(path, s).map_err(|e| e.to_string())
}

struct StableRng(u64);
impl StableRng {
    fn new(seed: u64) -> Self {
        Self(seed.max(1))
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(2685821657736338717)
    }
    fn index(&mut self, n: usize) -> usize {
        (self.next() % (n as u64)) as usize
    }
}

/// NumPy RandomState's MT19937 and `rk_interval`, used by
/// `np.random.seed(...); np.random.shuffle(...)` in sequences.py.
struct NumpyMt19937 {
    state: [u32; 624],
    position: usize,
}

impl NumpyMt19937 {
    fn new(seed: u32) -> Self {
        let mut state = [0_u32; 624];
        state[0] = seed;
        for i in 1..624 {
            state[i] = 1812433253_u32
                .wrapping_mul(state[i - 1] ^ (state[i - 1] >> 30))
                .wrapping_add(i as u32);
        }
        Self {
            state,
            position: 624,
        }
    }

    fn next_u32(&mut self) -> u32 {
        if self.position >= 624 {
            for i in 0..624 {
                let y = (self.state[i] & 0x8000_0000) | (self.state[(i + 1) % 624] & 0x7fff_ffff);
                self.state[i] = self.state[(i + 397) % 624]
                    ^ (y >> 1)
                    ^ if y & 1 != 0 { 0x9908_b0df } else { 0 };
            }
            self.position = 0;
        }
        let mut y = self.state[self.position];
        self.position += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c_5680;
        y ^= (y << 15) & 0xefc6_0000;
        y ^= y >> 18;
        y
    }

    fn interval(&mut self, max: usize) -> usize {
        let mut mask = max as u32;
        mask |= mask >> 1;
        mask |= mask >> 2;
        mask |= mask >> 4;
        mask |= mask >> 8;
        mask |= mask >> 16;
        loop {
            let value = self.next_u32() & mask;
            if value <= max as u32 {
                return value as usize;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lz_known_values() {
        assert_eq!(lz_complexity(&[0, 0, 0, 0]), 2);
        assert_eq!(lz_complexity(&[0, 1, 0, 1, 0, 1]), 3);
    }
    #[test]
    fn transition_mass_is_one() {
        let m = transitions(&[0, 1, 0, 1], 2);
        assert!((m.iter().flatten().sum::<f64>() - 1.0).abs() < 1e-12);
    }
    #[test]
    fn smoothing_removes_short_run() {
        let mut l = vec![0, 0, 1, 0, 0];
        let c = vec![vec![0.9; 5], vec![0.1; 5]];
        smooth_short_segments(&mut l, &c, 1000.0, 2.0);
        assert_eq!(l, vec![0; 5]);
    }
    #[test]
    fn numpy_shuffle_stream_matches_reference() {
        let mut rng = NumpyMt19937::new(12345);
        let mut a: Vec<usize> = (0..10).collect();
        for i in (1..a.len()).rev() {
            let j = rng.interval(i);
            a.swap(i, j);
        }
        assert_eq!(a, vec![0, 7, 3, 9, 6, 4, 1, 8, 5, 2]);
        let mut b: Vec<usize> = (0..10).collect();
        for i in (1..b.len()).rev() {
            let j = rng.interval(i);
            b.swap(i, j);
        }
        assert_eq!(b, vec![4, 0, 9, 5, 7, 3, 8, 6, 1, 2]);
    }
    #[test]
    fn metadata_matches_sequences_py_field_order() {
        let values = extract_metadata("S01_paradigm_MW_Drowsy_Past_Self_Positive_Verbal_4_epoch01");
        assert_eq!(
            values,
            vec!["S01", "MW", "Drowsy", "Past", "Self", "Positive", "Verbal", "4", "epoch01"]
        );
        assert_eq!(extract_metadata("unmatched"), vec!["NA"; 9]);
    }
    #[test]
    fn spherical_spline_reproduces_source_electrodes() {
        let xyz = vec![
            [1.0, 0.0, 0.2],
            [-1.0, 0.0, 0.2],
            [0.0, 1.0, 0.4],
            [0.0, -1.0, 0.4],
            [0.2, 0.1, 1.0],
        ];
        let maps = vec![vec![0.4, -0.3, 0.8, -0.7, 0.1]];
        let result = spherical_spline_resample(&xyz, &maps, &xyz).unwrap();
        for (actual, expected) in result[0].iter().zip(&maps[0]) {
            assert!((actual - expected).abs() < 1e-9);
        }
    }
    #[test]
    fn assignment_prioritises_established_earlier_maps() {
        let assignment = priority_assignment(&[vec![0.90, 0.80], vec![0.89, 0.10]], 0.5);
        assert_eq!(assignment, vec![Some(0), None]);
    }
    #[test]
    fn assignment_matches_matlab_acceptance_threshold() {
        let assignment = priority_assignment(&[vec![0.50, 0.49], vec![0.20, -0.70]], 0.5);
        assert_eq!(assignment, vec![None, Some(1)]);
    }
}
