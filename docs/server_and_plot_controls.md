# Per-user server updates, concurrent instances and ERP controls

## Linux without sudo

Version 1.2.21 adds `CCSEEGStudio-linux-x86_64.tar.gz` to every desktop release.
The in-app updater uses a GitHub API SHA-256 digest or the checksum file from the
same release tag, rejecting mismatches before installation. Old installers remain
available; the portable bundle avoids needing dpkg/rpm extraction tools.

Installation is isolated per OS account:

- `$XDG_DATA_HOME/ccseegstudio/releases/<version>` (default `~/.local/share/...`)
- `$XDG_DATA_HOME/ccseegstudio/current` points to the selected version.
- `~/.local/bin/ccseegstudio` launches that version.
- `$XDG_DATA_HOME/applications/ccseegstudio.desktop` overrides the system launcher
  for the current account. Custom `XDG_BIN_HOME` is also respected.

The updater stages a complete version before atomically switching `current`.
Old release directories are retained because a running instance can load resources
later in its lifetime. A lock prevents simultaneous installers for the same account.
Each account owns its copy; no sudo, shared write permission or administrator
password is used. Initial host libraries (including GTK) must already be installed.

Users of older app versions can run `scripts/update_linux_nosudo.sh` once. This
bootstraps the latest tagged portable archive with checksum verification. After
that, updates run from the user copy. The system-wide package is left intact.
If a shell still resolves the system executable, invoke `~/.local/bin/ccseegstudio`
explicitly or put `~/.local/bin` ahead of `/usr/bin` in the user's PATH.

## Multiple instances

The toolbar action opens another independent process. Linux uses
`G_APPLICATION_NON_UNIQUE`; Windows executable launches are independent. On macOS,
`open -n ".../CCS EEG Studio.app"` is also available. Per-job temporary directories
and per-download staging paths are unique. Use separate output paths for different
analyses; the app does not merge concurrent writes to one output file.

On a shared server, set `RAYON_NUM_THREADS` before starting each instance to avoid
having every analysis use all CPU cores. Jobs inherit that setting. Updating one
instance closes/restarts only that updater process; other processes retain their
original version directory.

## GPU status

Flutter's graphics rendering and numerical GPU compute are different capabilities.
The Rust scientific kernels currently use CPU/Rayon. GPU compute is not advertised
as implemented. Selection of CUDA, ROCm or another backend depends on actual server
hardware and installed driver/runtime; it also needs numerical parity and memory
failure/fallback testing on that hardware. CPU remains the functioning fallback.

## ERP display axes

In both Waveforms and Interactive batch review, expand **Plot axis limits**. Enter
both time bounds in ms and/or both voltage bounds in µV, then apply. Leave a pair
empty for Auto or use Reset to Auto. Limits apply to the main waveform and electrode
panels. Negative-up orientation does not reverse the entered physical voltages.
The controls affect display only; CSV measurements retain the analysis window.

Single-epoch waveform view labels its actual trial duration. Its time ticks show
fractional seconds relative to the saved epoch zero. Stitched view shows the
remembered continuous window setting. This avoids a 1.7-second trial being labelled
as a 20- or 120-second view.

**Output re-reference** is visible directly in preprocessing. Common average and
selected/linked references are applied by the native pipeline after cleaning; keep
current/cleaned means no additional output re-reference.
