# Preprocessed FieldTrip batch workflow

## Starting with cleaned recordings

In Batch Workspace enable **Already preprocessed: start with features**.
Preprocessing is hidden and the workflow starts from the feature input queue.
Set **Folder import: first N subjects** to 10 before importing the psiconnect
folder; zero means all subjects. BIDS names use `sub-...` as the subject ID;
other names use their first underscore-separated token. Files are sorted before
selecting subjects. The pilot used PC001–PC010: 79 recordings, not ten files.

Choose feature window and overlap in seconds. Zero overlap retains ordinary
nonoverlapping windows. Continuous MAT data stays continuous and is read at full
resolution by the engine. The waveform's decimated preview is never treated as
analysis samples. **Subepoch existing trials** optionally creates windows inside
each saved trial; no window crosses a parent boundary. Incomplete tails drop.

Preprocessing offers **Saved epoch overlap after cleaning**. The source is cleaned
once, then output windows are formed; repeated samples are not cleaned twice.
For continuous inputs this defers saved epoch construction until after artifact
cleaning. Existing parent trials remain boundaries. The saved window length uses
the GEDAI/window length control. This setting concerns saved output windows, not
GEDAI's internal covariance-window implementation.

## Group statistics and filename metadata

Stage 4 follows feature extraction and plots. **Configure group analysis** builds
an explicit `Group_Statistics/group_input.features.csv` from current successful
batch feature outputs, then opens the metadata/model workbench. **Open after
batch finishes** provides the same handoff automatically. It does not run a model
without choosing the factors and outcomes. Compact output defaults remain intact;
the group-input pooled table is created only for this explicit handoff.

Use **Infer metadata from filenames…** in the workbench. For example:

| Filename | Subject | Session | Task |
| --- | --- | --- | --- |
| `sub-PC001_ses-01_task-meditation_Clean-ft` | PC001 | 01 | meditation |

BIDS Subject/Session/Task/Run/Acquisition fields and legacy SubNN IDs are recognized.
Unknown fields remain blank. A custom regex can use named captures, e.g.
`(?<Subject>[^_]+)_(?<Session>[^_]+)_(?<Task>[^_]+)`.
Update the preview after editing the regex, inspect the first ten examples, then
save the reviewed metadata CSV. It becomes the selected metadata file with
`filename` as join key. Names do not infer age, gender, diagnosis or treatment.

For this repeated-measures dataset, choose Subject as subject ID, Task as the
factor of interest and Session as an optional second factor. Confirm the design
and outcomes before fitting. The workbench aggregates epochs per recording,
channel and condition; overlapping windows are not independent subject samples.
Numeric categorical labels such as sessions 1/2 are represented consistently in
both model fits and model-adjusted contrasts.

## Validation scope

- All 79 MAT files from PC001–PC010 succeeded using PSD on all 64 channels,
  two-second windows and one-second overlap: 1,466,112 CSV rows.
- The actual first recording loads as continuous at 500 Hz, more than four minutes,
  rather than as a single synthetic epoch. App-service extraction produces the
  expected sliding-window count.
- Separate bounded DFA/fE:I checks used the first ten seconds of one recording per
  subject: 5,760 Gamma1 DFA values were finite, and 708 Gamma1 fE:I values were finite.
  The short windows cannot support the lower-band fits. The app permits continuation
  after the recommendation warning; it does not fill missing estimates.
- Group handoff was exercised with filename-derived Subject/Session/Task metadata
  and an Fz Alpha_PSD LMM, with task/session fixed factors and a subject random
  intercept. This is a workflow validation, not a full dataset scientific conclusion.
- This pilot did not run every expensive feature family on all recordings or use
  subjects outside PC001–PC010. Original dataset files were read only.

Pilot artifacts are under the workspace's `output/psiconnect_first10_validation/`.
