#!/bin/zsh -l
# Runs Rust tests, pub get, analyze, the parity tests and the release build
# (engine + app, via scripts/build_macos.sh); output -> tools/topostats_checks.log
cd "$(dirname "$0")/.."
source ~/.zshrc >/dev/null 2>&1
export PATH="$PATH:$HOME/.cargo/bin:$HOME/flutter/bin:$HOME/development/flutter/bin:$HOME/fvm/default/bin:/opt/homebrew/bin:/usr/local/bin"
LOG=tools/topostats_checks.log
{
  echo "== $(date)"; which flutter cargo; flutter --version 2>&1 | head -2
  echo "== cargo test (CCS_Algorithm preprocessing)"
  (cd ../CCS_Algorithm && cargo test --release --lib eeg::preprocessing 2>&1 | grep -E "^test |test result|error|warning: unused|panicked|-->" | head -80)
  echo "== cargo build engine"; (cd bridge && cargo build --release 2>&1 | grep -E "error|warning: unused|Finished" | head -20)
  echo "== pub get"; flutter pub get 2>&1 | tail -3
  echo "== analyze"; flutter analyze --no-fatal-infos 2>&1 | grep -v "available)"
  echo "== test erp"; flutter test test/erp_parity_test.dart -r expanded 2>&1 | grep -v "available)" | tail -20
  echo "== test erp pipeline"; flutter test test/erp_pipeline_test.dart -r expanded 2>&1 | grep -v "available)" | tail -40
  echo "== test widget"; flutter test test/erp_view_test.dart test/widget_test.dart test/plot_segmentation_test.dart 2>&1 | grep -v "available)" | tail -40
  echo "== build (engine + app)"; bash scripts/build_macos.sh 2>&1 | grep -v "^\s*Compiling" | tail -25
  echo "== DONE"
} > "$LOG" 2>&1
exit
