# Event markers on feature plots

New app feature exports include `event_markers`, a CSV-quoted JSON array. Each entry contains `type`, `label`, `onset_s`, `duration_s`, and optionally `channel_index`. Times are seconds on the same source timeline as `epoch_start_s` and `epoch_end_s`; they are not rounded to an epoch centre.

Point events belong to half-open epochs [start, end). Duration annotations belong to every epoch they intersect. Overlapping epochs therefore repeat the same event, intentionally. Plotting deduplicates identical entries across epochs and channels, draws purple onset lines and labels, and shades duration intervals. Subepoching preserves the full annotation duration and restores source onset times from parent epoch onsets. Existing CSVs need re-extraction to acquire annotations.

Annotations cannot be recovered when absent from the loaded source. Preprocessing modes that reject/concatenate time segments without retaining an explicit timeline currently omit markers rather than assign misleading timestamps. Retained continuous timelines, saved epoched recordings with markers, and overlapping subepochs are supported.
