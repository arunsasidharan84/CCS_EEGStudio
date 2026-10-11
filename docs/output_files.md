# Analysis output files

The default workflow now writes one feature CSV and one analysis PDF per recording,
plus one plots PDF and statistics CSV when plot generation is selected. Individual
plot PNGs and the pooled batch CSV are optional extra exports.

| File | Purpose | Default |
| --- | --- | --- |
| `<recording>_clean.ccseeg.json` | Reusable cleaned signal | Written by preprocessing |
| `...ccseeg.json.preprocessing.json` | Source, cleaning settings, actual summary, marker/timing provenance | Retained; needed for history and raw comparison |
| `<recording>.features.csv` | Numerical features per epoch/channel | On |
| `...features.csv.analysis.json` | Extraction settings and source/window coordinates | Retained for reproducibility |
| `<recording>.analysis_report.pdf` | Preprocessing/raw comparison and feature summary | On; replaces the less descriptive `.features_report.pdf` naming for new runs |
| `Figures_TopoStats/<recording>_TopoStats_report.pdf` | All selected feature plots in one report | On |
| `Figures_TopoStats/<recording>_TopoStats_stats.csv` | Numerical tests underlying those plots | Retained |
| `Figures_TopoStats/*.png` | Separate high-resolution plot images | Off unless “Also export individual plot PNGs” is enabled; generated when plots PDF is off |
| `Batch_features.csv` | Pooled copy of individual feature CSVs | Off; enable when a combined table is wanted |

The analysis PDF and plots PDF have different content. Neither is a duplicate of
the other. Provenance JSONs are machine-readable companions, not disposable
intermediate files. The app's temporary engine inputs are removed after a run.
Existing outputs are not deleted when defaults change. Older report filenames and
plot outputs remain readable. The plots folder and CSV names remain stable for
existing consumers.

For the Girish Testbin reviewed in this change, 220 individual PNGs accompany 11
plots PDFs. Future default runs avoid those PNGs and the pooled duplicate CSV.
To retain publication-resolution images, enable PNG export or export individual
plots from the viewer.

# Feature window advice

Extraction warns before running when selected DFA/fE:I uses less than the
recommended 60 seconds for the full band range, when FOOOF/IRASA has less than one
second, when the Welch window exceeds the available epoch, or when GC lags exceed
the available samples. The warning uses saved parent-epoch duration for already
epoched inputs. Batch runs ask once for each distinct warning, allowing continuation
or cancellation to change settings. It does not silently merge trials.

In the supplied Girish outputs (28,132 rows), Delta through Beta2 DFA/fE:I are all
missing; Gamma1 DFA is finite throughout and Gamma1 fE:I in 3,759 rows. The actual
analysis windows are two seconds. Missing low-band values reflect insufficient
fit scales; fE:I also has statistical/validity gates, so longer windows do not
guarantee every value is finite. Sixty seconds is a practical full-range
recommendation, not an unconditional validity guarantee.


## Method references for window advice

DFA scaling and filter-induced correlations follow [Hardstone et al. (2012),
doi:10.3389/fphys.2012.00450](https://doi.org/10.3389/fphys.2012.00450).
fE:I follows [Bruining et al. (2020), doi:10.1038/s41598-020-65500-4](https://doi.org/10.1038/s41598-020-65500-4).
The 60-second warning is Studio guidance derived from its fit scales/window counts,
not a hard cutoff claimed by those papers. The FOOOF/IRASA one-second warning is
an engine requirement, and the Welch/GC warnings use the configured sample/window
parameters. See the [full method table](../README.md#-method-references) and
[implementation/validation guide](methods_and_validation.md) for cited algorithms.
