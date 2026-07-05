#!/usr/bin/env bash
# build_macos.sh — Local macOS release build for CCS EEG Feature Studio.
#
# Run from the repository root (or any directory; the script is self-relocating):
#   ./scripts/build_macos.sh
#
# What it does:
#   1. Compiles the Rust engine (bridge/src/main.rs → ccs-eeg-engine binary).
#   2. Builds the Flutter macOS app in release mode.
#   3. Copies ccs-eeg-engine into the .app bundle's MacOS directory so that
#      the Flutter ExtractionService can locate and launch it at runtime.
#   4. Removes any stale tools/ directory from the bundle Resources folder.
#   5. Ad-hoc signs the bundle with codesign so Gatekeeper accepts it after
#      the user runs: xattr -rd com.apple.quarantine <app>
#
# Output: build/macos/Build/Products/Release/ccs_eeg_app.app
set -euo pipefail

# ── Locate repository root ─────────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Locate cargo (supports ~/.cargo/bin path) ─────────────────────────────
CARGO_BIN="$(command -v cargo 2>/dev/null || true)"
if [[ -z "$CARGO_BIN" && -x "$HOME/.cargo/bin/cargo" ]]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$CARGO_BIN" ]]; then
  echo "Error: cargo was not found. Install Rust via https://rustup.rs" >&2
  exit 1
fi

# ── Build Rust engine ──────────────────────────────────────────────────────
echo "==> Building Rust engine (release)..."
cd "$ROOT/bridge"
"$CARGO_BIN" build --release
echo "    Engine: bridge/target/release/ccs-eeg-engine"

# ── Build Flutter macOS app ────────────────────────────────────────────────
echo "==> Building Flutter macOS app (release)..."
cd "$ROOT"
flutter build macos --release

APP="$ROOT/build/macos/Build/Products/Release/ccs_eeg_app.app"
if [[ ! -d "$APP" ]]; then
  echo "Error: Expected .app bundle not found at $APP" >&2
  exit 1
fi

# ── Embed the Rust engine inside the .app bundle ──────────────────────────
echo "==> Copying ccs-eeg-engine into .app bundle..."
cp "$ROOT/bridge/target/release/ccs-eeg-engine" "$APP/Contents/MacOS/ccs-eeg-engine"
chmod +x "$APP/Contents/MacOS/ccs-eeg-engine"

# Remove stale developer tools directory if it crept in from a previous run.
rm -rf "$APP/Contents/Resources/tools"

# ── Ad-hoc code sign ──────────────────────────────────────────────────────
echo "==> Ad-hoc signing bundle..."
codesign --force --deep --sign - "$APP"

echo ""
echo "✅  Built: $APP"
echo ""
echo "To clear Gatekeeper quarantine after distributing:"
echo "    xattr -rd com.apple.quarantine ~/Downloads/ccs_eeg_app.app"
