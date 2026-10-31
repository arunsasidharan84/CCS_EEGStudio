# Microstate syntax and sample exports

Both the interactive microstate panel and Batch Workspace → Microstates run the
same native Rust pipeline. Choose recordings, state count, optional epoch DC
removal, and a syntax word length, then run. Progress shows loading/preparation,
model count, restart, iteration, recording backfit and sample export. The centre
of the workspace shows progress while running, with elapsed time and Stop.
Iterations are convergence-dependent, so the percentage is workflow allocation,
not a linear estimate of time remaining. Stop during a file read takes effect
when that read finishes; the running engine can be stopped immediately.

## Preparation and epochs

The supplied test SET files contain one 15-second epoch each at 1000 Hz, 63
channels and 15,000 samples. They have large channel DC offsets. The visible
**Remove per-epoch channel DC before fitting** checkbox defaults on: subtract
channel means separately inside each epoch, then use the existing channel
variance normalization and average reference for microstate fitting. Disable it
to retain the earlier preparation. The choice is stored as `remove_epoch_dc` in
`microstates.json`. This changes the analysis copy, not the source recording.

GFP peaks do not compare across epoch edges; short-segment smoothing, syntax
words, durations/occurrences and transitions respect those boundaries. The
historical LZ/sequence-complexity summary retains its existing concatenated-sequence
convention; it is not the new boundary-aware Microsynt analysis or the paper's
LZMA2 MS-LZC implementation.

## Per-sample output

Each recording gets a uniquely prefixed `NNN_<name>.samples.csv`. Indices are zero
based except `state_index`, which is one based and matches the existing JSON
sequence. Columns include:

- `sample_index`, `epoch_index`, `epoch_sample`, `time_in_epoch_s`;
- final smoothed `state_index` and canonical `state_label`;
- `gfp_uv`: spatial standard deviation of the original common EEG channels;
- `fitting_gfp_uv`: GFP after optional epoch DC subtraction, before variance normalization;
- `gfp_normalized`: GFP of the normalized data actually used in fitting (unitless);
- `assigned_fit_pct`: `100 × abs(spatial correlation)²` for the **final assigned** state;
- `fit_<state>_pct`: the same unnormalized squared-correlation fit for every state;
- `relative_fit_<state>_pct`: squared correlation divided by its sum across states,
  multiplied by 100. These sum to 100 for a nonzero map, but are **not calibrated
  class probabilities**. Zero maps produce zero fits.

Smoothing may assign a state other than the sample's highest-correlation state.
Both assigned and per-state fits are therefore retained. Physical GFP assumes
the loader's EEG unit conversion to µV. Original and normalized values should
not be mixed in physical-amplitude statistics.

## Microsynt definitions and compatibility

Reference: Artoni et al. (2023), *Microsynt: Exploring the syntax of EEG
microstates*, NeuroImage 277, 120196. DOI:
https://doi.org/10.1016/j.neuroimage.2023.120196.
Definitions were checked against the supplied Frederic-vW `microsynt.py`;
its MIT notice is retained in [microsynt_LICENSE.txt](microsynt_LICENSE.txt).

Within each epoch, collapse consecutive repeated states into a no-permanence
sequence. Count overlapping words of the selected length (default 6; UI 2–7).
Enumerate all `K × (K−1)^(w−1)` theoretical words with no equal adjacent symbols.
Classify words by Shannon entropy in bits rounded to three decimals, matching
`microsynt.py`:

- TER: theoretical fraction of words in each entropy class;
- EER: observed fraction of windows in the class;
- MER: class probabilities under the empirical first-order Markov model,
  initialized with empirical jump-symbol occupancy and normalized across the
  theoretical no-repeat dictionary;
- EER/TER and EER/MER: representation ratios. Undefined ratios are blank/null.

The paper's worked example counts **N−w+1** valid windows. The supplied code
uses `range(N−w)` and omits the final window. The default follows the paper;
**Legacy microsynt.py window count** reproduces that code convention inside each
epoch for comparisons. Neither mode joins epochs.

`MicrostateSyntax.csv` provides one row per recording/entropy class for batch use.
`microstates.json` additionally retains observed word counts, preparation choice,
syntax classes, ratios, warnings, and discovery results. Older saved results
without syntax fields remain readable.

`MicrostateDictionaryDiscovery.csv` and the UI discovery table compare observed
unique words against three seeded uniform no-repeat random sequences, for word
lengths 1–10. They use observed-sequence length separately in every epoch. These
are descriptive discovery aids. The paper selected word length using comparisons
across subjects/conditions; the app does not invent a cohort-level statistical
optimum from an individual recording. Review discovery and rerun with an
appropriate word length. Sparse dictionaries and absent complete windows are
flagged explicitly. Ratios alone are not p-values. This implementation does not
claim the paper's LZMA2 compression or every group-level surrogate hypothesis test.

## Validation

- Rust matches the paper's `ABABAC`, length-3 example: EER 0.75/0.25, TER 0.5/0.5,
  ratios 1.5/0.5; epoch boundaries and the legacy off-by-one are tested.
- A fixture generated with the supplied Python class matches Rust TER/EER/MER
  to 1e-10 in legacy mode.
- Four complete supplied files (P005, P007, P008, P009) were analysed together:
  60,000 exported samples, DC removal on, four selected states, default ten
  restarts and model search 3–8. Length-6 syntax windows: 14, 21, 15, 24.
- Real-file TER/EER/MER also match the supplied reference to 1e-10 after adapting
  its empirical count to the paper's final-window convention. Sample-row counts,
  assigned/per-state fit equality, relative-fit normalization and epoch indices
  are checked. The single-recording route is checked with length-3 words.

These four short epochs validate execution and numerical consistency; they do
not establish population effects or an optimal word length for the complete cohort.

To rerun the four-file validation without changing the source data:

```sh
flutter test tools/validate_microstate_syntax_test.dart \
  --dart-define=MICROSTATE_DATA_DIR=/path/to/epoch-folder \
  --dart-define=MICROSTATE_OUTPUT_DIR=/path/to/new/validation-output
```

The tool selects the first four SET files in sorted order, uses full recordings,
and also runs the first file through the single-recording service. If no output
is supplied, it creates a temporary directory. Keep the matching FDT files beside
their SET headers.
