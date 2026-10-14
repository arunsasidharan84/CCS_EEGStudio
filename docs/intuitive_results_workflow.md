# Results, plotting and group analysis

## Existing results

Group Statistics is available in the Continuous EEG sidebar as well as Batch Stage 4.
Use **Load results folder** to combine recording feature CSVs, or choose multiple
feature files. Pooling aligns columns by their names and leaves absent outcomes
blank instead of concatenating incompatible column orders. The source recording
CSVs are not changed.

The statistics workbench uses a consistent light theme inside the dark app. Its
steps are: choose data/metadata, review subject and group/state factors, select
outcomes, then Run. A run control is shown near the top after successful inspection
and below the outcome choices. One alpha outcome is selected initially where
available. Covariates remain explicit choices. Mean-channel scope produces one
observation per recording/condition; separate-channel scope retains channel rows
and requires an appropriate channel factor/design.

Mixed string/numeric CSV imports are normalized before recording-level aggregation.
Non-numeric feature tokens are rejected with an actionable error rather than
silently erased. Standard and exploratory DFA/fE:I columns are aggregated as
numeric outcomes. Full exception details stay in the workbench log.

## Many plotting files

Use the explicit **Load results folder** button in Plots & Report. The recording
list has a bounded scroll area, a subject/session/task search, selection counts,
**Compare matching**, **Select all** and **Clear**. Initially at most eight records
are selected to keep the plot readable; all files remain available. A recording
comparison plot is different from subject-level statistical inference; use the
group workbench for the latter.

In the supplied OpenDatasets/Testbin folder, inspection found 79 analysis PDFs and
51 plot PDFs under Figures_TopoStats. There were no group PDFs because inspection
failed before the modeling stage. Report and plot output folders are exposed by
the existing results controls; group results show their saved folder after running.

A repaired backend validation on the supplied pooled table successfully generated
an Alpha_PSD report and plot using recording-level channel means, condn/sessn fixed
factors and subjid random intercepts. The validation output is in the workspace's
output/intuitive_group_validation; it is not a full multi-outcome scientific finding.

## Short-epoch verification

Standard DFA/fE:I retains its longer-context and validity rules. The new explicit
**Short-epoch verification (exploratory)** option uses epoch-only context and
short-scale DFA fits with lower scale max(0.1 s, one period at the band's lower
frequency), four fitting points, and at least four local fluctuation windows.
This is an adaptation for implementation checks, not literature-scale LRTC or a
validated replacement for the physiological fE:I protocol. The DFA > 0.6 gate
and missing-data rules remain. Insufficient scales still produce missing values.

Columns are separately named *_DFA_short and *_fEI_short. They are categorized
as exploratory in group-analysis outcome selection. The normal columns/estimators
are not silently redefined.

Validation used the first ten seconds of PC001 on five representative channels,
with two-second epochs: 25 finite DFA_short values per band from Theta through
Gamma1. fEI_short was finite in 9 Theta, 8 ThetaAlpha, 5 Alpha, 7 Beta1, 5 Beta2
and 3 Gamma1 rows. Delta lacked sufficient scales. A synthetic modulated alpha
signal also exercises the distinction between standard and short-scale fits.

Metadata joining has an explicit join-column field. Subject joins recognize a
BIDS `sub-` prefix and preserve numeric-looking CSV IDs as strings, including
leading zeros. File joins recognize all app-supported recording extensions.

Stored fE:I values with a corresponding missing DFA or DFA <= 0.6 are excluded
before epoch averaging. Inspection reports the exclusion count so old outputs
can be re-extracted; source CSVs remain unchanged. Nullable pandas values follow
the same rule. The short verification mode retains this gate.

Validation: the full Flutter run passed 148 tests (5 external-data skips), the
new group-screen test and updated navigation checks passed, the algorithm library
passed 28 tests, and 10 Python tests passed. The local macOS bundle compiled and
passed signature verification. These changes are not yet a published release.
