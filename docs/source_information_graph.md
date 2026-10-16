# Source models, information connectivity, and graph measures

## Source analysis: what actually runs

The previous implementation was an isotropic, fixed-orientation, regularized **minimum-norm** inverse. Its eLORETA UI label was incorrect; it did not perform eLORETA's iterative weighting. The default is now named MNE. Existing minimum-norm results are not reclassified as sLORETA or eLORETA.

Source Space → settings offers:

| Method | Operator before ROI aggregation | Assumptions |
|---|---|---|
| MNE | `W = Lᵀ(LLᵀ + αI)⁻¹` | Isotropic source prior; identity sensor-noise covariance |
| dSPM | MNE row divided by its noise standard deviation | Identity sensor noise; fixed orientation |
| sLORETA | MNE row divided by `sqrt(diag(WL))` | Fixed orientation; resolution normalization |
| LCMV | `lᵀC⁻¹ / (lᵀC⁻¹l)` per source | Sample covariance over the processed recording, mean removed, 5% trace regularization, unit gain |

For the first three, `α = trace(LLᵀ) / n_sensors / SNR²`. LCMV uses the stated 5% covariance regularization, not the SNR setting. The bundled source grid and 68 Desikan–Killiany regions remain available. ROI aggregation retains the app's existing data-sign-aligned mean; this is **not** MNE's geometry-based `mean_flip`. The existing MNE source display scale factor is preserved for compatibility (also used for LCMV); dSPM/sLORETA use their normalized scale. These outputs must not be interpreted as calibrated current density or compared across inverse methods by amplitude alone.

The tests verify inverse **operator formulas** against independent NumPy calculations. They do not establish full end-to-end parity with every MNE/Brainstorm option. Free orientations, estimated noise covariance, depth priors, vector beamformers, eLORETA iteration, DICS, and Rust BEM/FEM forward solvers are not implemented here.

References: [MNE source methods](https://mne.tools/stable/auto_tutorials/inverse/30_mne_dspm_loreta.html), [LCMV](https://mne.tools/stable/auto_tutorials/inverse/50_beamformer_lcmv.html), [MNE forward models](https://mne.tools/stable/api/forward.html).

## Forward models and HCPex

Choose **forward + atlas model** in Source Space settings to import a JSON or gzip JSON model:

```json
{"channels":["Fp1","Fp2","Cz","Pz"],
 "leadfield":[[0.1,0.2],[0.2,0.3],[0.4,0.1],[0.1,0.4]],
 "rois":[{"name":"Example ROI","indices":[0,1]}]}
```

Rows are sensors, columns are fixed-orientation sources; indices are zero-based source-column indices. At least four input electrodes must match model channel names. Dimensions, finite values, and atlas indices are validated; model failures stop source processing instead of silently exporting sensor data as sources. A precomputed sphere, BEM, or FEM leadfield can use this format; its forward solver runs upstream, not in Rust.

HCPex extends HCP-MMP cortical labels with 66 subcortical regions. The bundled cortical-only leadfield cannot reconstruct all HCPex regions. Use a compatible volumetric/mixed source forward model and explicit source coordinates in the atlas's MNI space. `tools/build_source_atlas.py` maps those coordinates to the supplied NIfTI atlas using its affine and nearest label voxel:

```sh
python3 tools/build_source_atlas.py \
  --forward fixed_forward_mni.npz --atlas HCPex.nii.gz \
  --labels hcpex_labels.json --output hcpex_forward.json.gz
```

The forward NPZ must contain `channels` (Unicode strings), `leadfield` (sensors × fixed sources), and `source_mni_mm` (sources × 3). Label JSON maps integer atlas IDs to unique names. NIfTI input requires nibabel; NumPy is also required. An atlas NPZ with `data` and `affine` can be used for preconverted label volumes. The tool reports missing atlas IDs and mapped-source counts; zero matches is an error. It never assumes that MRI/head coordinates are MNI coordinates. Obtain the actual atlas and citation from the [HCPex authors](https://github.com/wayalan/HCPex); this change does not bundle HCPex data or claim that a cortical-only forward model includes its subcortex.

## GCMI and transfer entropy

Feature Extraction adds **Gaussian-copula MI** and **Transfer entropy (lagged time samples)**. They operate on broadband processed channel signals, or on source ROI signals when those are the input. Results are in bits.

GCMI follows Frites' `GCMIEstimator(mi_type='cc', copnorm=True, biascorrect=True)` univariate configuration (not the `conn_dfc` wrapper's different defaults): empirical ordinal-rank Gaussian normalization, sample covariance, Cholesky entropy terms, analytic finite-sample bias correction. Samples within each epoch are the observations. Ties use deterministic input-order ordinal ranks; exact tied-value behavior can differ from NumPy's unstable sorting. Constant/nonfinite series produce missing estimates rather than spurious information.

Temporal TE estimates `I(X[t-delay, ...]; Y[t] | Y[t-1, ...])` using aligned lagged **time samples inside each epoch**. Epochs are never pooled as observations, no trial ensemble is required, and overlapping windows are allowed. Delay, source/target history lengths, and history spacing are configurable in samples. The UI defaults to one-sample delay and one sample of history for each process; selecting a delay uses that single delay. Native JSON can additionally request a mean over a delay range (`te_min_delay` is exclusive, `te_max_delay` inclusive, `te_step` positive). The aligned observations use the maximum requested lag/history as a common starting point.

Each embedding variable is Gaussian-copula normalized over its aligned time observations, followed by bias-corrected multivariate Gaussian conditional MI. This is a **Gaussian-copula temporal TE estimator**, using Frites' CMI mathematics, **not Frites' across-trial `conn_te` wrapper**. It handles monotonic marginal transforms but is not a general-purpose nonlinear/nonparametric TE estimator. Auto-correlated time observations can invalidate the IID finite-sample correction as a significance calibration; the estimates are descriptive and do not supply causal proof or surrogate-tested significance.

Exports use `conn_te_time_to_<target>` and `graph_te_time_*`, with independently computed values per window. The JSON metadata explicitly records `te_estimator: time_copula_cmi`, delay and embedding settings. At least `max(20, source_history + target_history + 3)` aligned time observations must remain after embedding. Insufficient epochs produce an actionable error. Processing never borrows samples across a parent trial boundary. Overlapping estimates share samples and are statistically dependent.

This is the supported univariate/bias-corrected/rank-normalized subset, not a port of every Frites estimator, tensor option, permutation workflow, or spectral TE. Frites code is pinned at `ded44ea19bfa86a37b83f703e3f1375c35a1eeca`; reference fixtures exercise MI, multivariate CMI and temporal TE on a known-direction autoregressive simulation. No Python/Frites dependency is used at runtime. Attribution is in [Frites BSD license](licenses/Frites-BSD-3-Clause.txt).

References: [Frites `conn_dfc`](https://brainets.github.io/frites/api/generated/frites.conn.conn_dfc.html), [Frites conditional MI core](https://github.com/brainets/frites/blob/ded44ea19bfa86a37b83f703e3f1375c35a1eeca/frites/core/gcmi_1d.py), [IDTxl embedding definitions](https://pwollstadt.github.io/IDTxl/html/idtxl.html), [Ince et al., 2017](https://doi.org/10.1002/hbm.23471).

## Pair outputs and graph summaries

Select **raw pairs**, **graph summaries**, or **both**. The spectral pair/graph checkbox applies this to the selected COH, PLV, ciPLV, PLI, and wPLI methods and replaces their previous per-node averages. MIC/MIM/GC remain seed/target-set estimators; their scalar summaries cannot define a full channel graph and are not converted into one.

The `connectivity_settings` JSON metadata column preserves information-estimator, graph, and delay settings. CSV row `Chan` is the source node; `_to_<node>` identifies the target. Self edges are missing. Spectral and GCMI matrices are symmetric; TE is directed. Standard spectral bands/settings still apply to spectral methods. GCMI/TE are broadband. `graph_*` columns are recognized by the group-statistics pipeline.

Graph construction retains a selected proportion of the strongest **positive symmetric-mean** pair weights. Negative bias-corrected information estimates remain intact in pair exports but are excluded from positive-weight graphs. Ties are broken by node order. Actual density may be below the selected density when insufficient positive edges exist. Missing pair estimates invalidate graph summaries instead of being treated as absent edges.

Per node: outgoing strength, incoming strength, undirected degree, weighted clustering (Onnela cube-root triangle formula), and nodal shortest-path efficiency. The latter uses reciprocal normalized weights as lengths; disconnected paths contribute zero. Global efficiency is the average nodal efficiency; global efficiency and actual density repeat on node rows. Weights are normalized by the retained maximum for paths/clustering; strengths use original positive retained directed weights. TE retains directed in/out strengths, while paths/clustering use the explicitly symmetrized graph. These are **not** directed efficiency/clustering or community/modularity measures. Channel nodes and source ROI nodes use the same implementation.

Definitions follow standard weighted-network formulas documented in [BCT clustering](https://github.com/fieldtrip/fieldtrip/blob/master/external/bct/clustering_coef_wu.m) and [BCT efficiency](https://github.com/fieldtrip/fieldtrip/blob/master/external/bct/efficiency_wei.m). Complete-triangle/disconnected cases and independent shortest-path calculations are tested. No claim is made of a complete BCT port.
