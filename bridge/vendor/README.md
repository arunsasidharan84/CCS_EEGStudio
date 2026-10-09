CCS Algorithm is vendored from c65bfbd356b5580996cd2ec7c2162fe662ddc59e.
Local fix: Welch shortens windows for short IRASA resampled epochs and zero-pads to the requested FFT length, retaining matching spectral bins.
This keeps release builds reproducible without requiring an unpublished SDK commit.
