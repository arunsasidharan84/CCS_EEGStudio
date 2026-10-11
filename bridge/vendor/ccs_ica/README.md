Vendored copy of `ccs_toolbox/rust_ica` (crate `ccs_ica`) with nalgebra pinned to 0.32 to match this engine.
Source of truth: ccs_toolbox/rust_ica (validation scripts, parity tables, MATLAB reference harness live there).
Re-sync with: cp -r rust_ica/src rust_ica/data <here> && rm src/main.rs

See [VALIDATION.md](VALIDATION.md) for the upstream evidence snapshot supplied
with version 1.2.11, and [Studio method conventions](../../../docs/methods_and_validation.md)
for integration limits and references.
