#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/bridge"
CARGO_BIN="$(command -v cargo || true)"
if [[ -z "$CARGO_BIN" && -x "$HOME/.cargo/bin/cargo" ]]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$CARGO_BIN" ]]; then
  echo "cargo was not found" >&2
  exit 1
fi
"$CARGO_BIN" build --release
cd "$ROOT"
flutter build macos --release
APP="$ROOT/build/macos/Build/Products/Release/ccs_eeg_app.app"
cp "$ROOT/bridge/target/release/ccs-eeg-engine" "$APP/Contents/MacOS/ccs-eeg-engine"
rm -rf "$APP/Contents/Resources/tools"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
