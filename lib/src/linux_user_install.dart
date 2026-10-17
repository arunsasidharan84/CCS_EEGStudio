/// Installs a verified official portable bundle into a per-user version directory.
/// Running instances retain their existing directory; subsequent launches use current.
class LinuxUserInstaller {
  static const script = r'''#!/usr/bin/env bash
set -euo pipefail
ARCHIVE="$1"
VERSION="$2"
PARENT_PID="${3:-0}"
READY="${4:-}"
ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/ccseegstudio"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
STAGING=""
LOCK_HELD=0
cleanup() {
  CCS_INSTALL_RESULT=$?
  if [ "$CCS_INSTALL_RESULT" -ne 0 ] && [ -n "$READY" ]; then printf 'failed\n' > "$READY.failed"; fi
  [ -z "$STAGING" ] || rm -rf "$STAGING"
  if [ "$LOCK_HELD" = 1 ]; then rmdir "$ROOT/.update-lock" 2>/dev/null || true; fi
}
trap cleanup EXIT
mkdir -p "$ROOT/releases" "$BIN" "$APPS"
if ! mkdir "$ROOT/.update-lock" 2>/dev/null; then
  echo 'Another per-user update is in progress.' >&2; exit 1
fi
LOCK_HELD=1
STAGING="$(mktemp -d "$ROOT/releases/.staging.XXXXXX")"
case "$VERSION" in *[!0-9.]*|'') echo 'Invalid release version' >&2; exit 1;; esac
tar -xzf "$ARCHIVE" -C "$STAGING"
test -f "$STAGING/ccs_eeg_app"
test -f "$STAGING/ccs-eeg-engine"
chmod +x "$STAGING/ccs_eeg_app" "$STAGING/ccs-eeg-engine"
TARGET="$ROOT/releases/$VERSION"
# Never overwrite a directory that an existing instance may still be using.
if [ -e "$TARGET" ]; then TARGET="$TARGET-$(date +%s)-$$"; fi
mv "$STAGING" "$TARGET"
ln -s "$TARGET" "$ROOT/.current-$$"
if [ "$(uname -s)" = Linux ]; then
  mv -Tf "$ROOT/.current-$$" "$ROOT/current"
else
  mv -fh "$ROOT/.current-$$" "$ROOT/current"
fi
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$ROOT/current/ccs_eeg_app" > "$BIN/ccseegstudio"
chmod +x "$BIN/ccseegstudio"
cat > "$APPS/ccseegstudio.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CCS EEG Studio
Exec="$BIN/ccseegstudio"
Icon=ccseegstudio
Terminal=false
Categories=Science;Education;
EOF
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" || true
[ -z "$READY" ] || printf 'ready\n' > "$READY"
# Existing instances continue using their own version. Restart only the updater instance.
if [ "$PARENT_PID" -gt 0 ]; then
  while kill -0 "$PARENT_PID" 2>/dev/null; do sleep 0.25; done
fi
if [ "${CCS_EEG_NO_LAUNCH:-0}" != 1 ]; then
  nohup "$BIN/ccseegstudio" >/dev/null 2>&1 &
fi
echo "Installed for the current user: $TARGET"
''';
}
