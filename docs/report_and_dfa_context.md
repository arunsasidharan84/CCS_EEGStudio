# Compact reports and DFA/fE:I context

## Reports

The default per-recording analysis report is a compact summary: overview,
one representative-channel signal snapshot, selected scalp maps, selected time
courses and key statistics. The reviewed 64-channel PC001 report is four pages.
Detailed PDF mode retains all channel snapshots and feature tables when needed.

Waveforms use the effective sampling rate of the preview buffer, rather than
mistaking decimated samples for full-rate samples. A shared peak-safe scale is
computed across the shown channels and both inputs when comparing raw/cleaned
signals. Each trace is centred; matching time and amplitude scales are retained.
Typical scalp channels are selected (Fp1/Fp2/F3/F4/Cz/Pz/O1/O2), with an evenly
spaced fallback when that montage is unavailable.

Scalp maps have fitted head/nose/ear outlines, sensor markers, contour lines and
per-map colorbars. This is an EEGLAB/Brainstorm-style presentation using the
existing MNE-compatible interpolation grid; it is not a claim of numerical
identity to either package's interpolation implementation. Full channel and
parameter provenance remains in CSV/JSON, avoiding repeated detail in the PDF.
Empty compact statistics sections are omitted, and DFA/fE:I is named as its own
family with a missing-column availability note.

## Why five-second epochs can produce missing values

The envelope already uses Hilbert analysis. Computing an amplitude envelope or
power at a frequency is different from fitting its temporal scaling law. DFA
requires multiple fitting scales and enough envelope windows at each scale;
the frequency-dependent lower fit bounds and four-fit-point requirement cannot
always fit in five seconds after edge trimming. The fE:I estimator uses several
local amplitude/fluctuation windows and a DFA validity gate.

Method references: [Hardstone et al. (2012), DFA of neuronal oscillations](https://doi.org/10.3389/fphys.2012.00450)
and [Bruining et al. (2020), functional E/I](https://doi.org/10.1038/s41598-020-65500-4).
The paper's five-second local fluctuation window should not be confused with
estimating the full measure from one isolated five-second recording.

The supplied PC001 five-second CSV has 6,016 rows. Beta2 and Gamma1 DFA are finite
throughout; Delta through Beta1 DFA are missing. Some fE:I values exist. The old
implementation allowed a missing DFA to pass its gate because NaN <= 0.6 is false.
That loophole is corrected: missing DFA or DFA <= 0.6 cannot qualify fE:I. Values
are not fabricated by weakening that gate or shortening the published fit scales.

## Separate context window

When DFA/fE:I is selected, the UI defaults to 60 seconds of source context, while
PSD and other epoch features retain the chosen analysis window. The context is
centred on the epoch where possible, shifted at recording edges to retain its
length, and limited to the recording or saved parent trial. It never joins recognized saved trials. Context estimates require genuinely continuous input; gaps removed upstream cannot be inferred from a feature CSV alone.
Masked/discontinuous selections use epoch-only context rather than span gaps.
Zero selects epoch-only mode; native jobs omitting the parameter retain epoch-only
behavior. A longer context remains a practical estimate, not a universal validity
guarantee. fE:I can still be missing where its DFA/statistical criteria fail.

CSV metadata records `dfa_fei_window_s`, `dfa_fei_context_start_s` and
`dfa_fei_context_end_s`. Provenance stores the requested setting. These are metadata,
not outcomes. The report notes actual context when recorded in the CSV. Overlapping
contexts are dependent; group analysis still aggregates recording/channel values
rather than treating each epoch as an independent subject.

Validation on PC001 used five-second output epochs and 60-second context for
Fz/Cz/Pz/O1/O2 across the full recording: all seven DFA bands were finite in all
285 channel/epoch rows. fE:I finite counts were Delta 120, Theta 210, ThetaAlpha 142,
Alpha 168, Beta1 237, Beta2 227 and Gamma1 134. This is a computation/validity check,
not a physiological finding. The original CSV was not overwritten; rerun extraction
to generate the newly qualified estimates and their context metadata.
