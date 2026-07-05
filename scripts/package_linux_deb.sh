#!/usr/bin/env bash
# package_linux_deb.sh — Build a Debian/Ubuntu .deb installer for CCS EEG Feature Studio.
#
# Usage:
#   bash scripts/package_linux_deb.sh <flutter-bundle-dir> <output.deb>
#
# Arguments:
#   <flutter-bundle-dir>  Path to the flutter build/linux/x64/release/bundle directory.
#                         Must contain the compiled 'ccs_eeg_app' executable.
#   <output.deb>          Destination path for the generated .deb package.
#
# The script reads the version from pubspec.yaml at the repository root.
# It installs the app under /usr/lib/ccseegstudio/, creates a /usr/bin/ccseegstudio
# symlink, registers a .desktop launcher, and installs the app icon.
#
# Requires: dpkg-deb (part of dpkg-dev)
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <flutter-bundle> <output.deb>" >&2
  exit 2
fi

bundle_dir="$1"
output_deb="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Validate inputs ────────────────────────────────────────────────────────
if [[ ! -x "$bundle_dir/ccs_eeg_app" ]]; then
  echo "Error: Linux bundle executable not found: $bundle_dir/ccs_eeg_app" >&2
  exit 1
fi

# ── Read version from pubspec.yaml ─────────────────────────────────────────
version="$(awk '/^version:/ {print $2; exit}' "$repo_root/pubspec.yaml")"
version="${version%%+*}"  # strip build metadata (e.g. "0.1.0+1" → "0.1.0")

package_name="ccseegstudio"
display_name="CCS EEG Feature Studio"
description="EEG feature extraction and connectivity analysis desktop application"

# ── Build staging directory ────────────────────────────────────────────────
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
package_root="$work_dir/package"
install_dir="$package_root/usr/lib/ccseegstudio"

mkdir -p \
  "$package_root/DEBIAN" \
  "$install_dir" \
  "$package_root/usr/bin" \
  "$package_root/usr/share/applications" \
  "$package_root/usr/share/icons/hicolor/256x256/apps"

# Copy entire Flutter bundle into the install prefix.
cp -a "$bundle_dir/." "$install_dir/"

# Symlink the executable so it is on PATH.
ln -s "../lib/ccseegstudio/ccs_eeg_app" "$package_root/usr/bin/ccseegstudio"

# Install app icon if present (created from assets/logo.png or similar).
icon_src=""
for candidate in \
    "$repo_root/linux/runner/assets/logo.png" \
    "$repo_root/assets/logo.png" \
    "$repo_root/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"; do
  if [[ -f "$candidate" ]]; then
    icon_src="$candidate"
    break
  fi
done
if [[ -n "$icon_src" ]]; then
  install -m 0644 "$icon_src" \
    "$package_root/usr/share/icons/hicolor/256x256/apps/ccseegstudio.png"
fi

# ── DEBIAN/control ─────────────────────────────────────────────────────────
installed_size="$(du -sk "$package_root/usr" | awk '{print $1}')"
cat > "$package_root/DEBIAN/control" <<EOF
Package: $package_name
Version: $version
Section: science
Priority: optional
Architecture: amd64
Installed-Size: $installed_size
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: CCS NIMHANS <noreply@github.com>
Homepage: https://github.com/arunsasidharan84/CCS_EEGApp
Description: $description
 CCS EEG Feature Studio is a desktop application for epoch-wise EEG
 feature extraction and functional connectivity analysis, implementing
 the CCS EEG pipeline with native Rust speed.
EOF

# ── .desktop launcher ──────────────────────────────────────────────────────
cat > "$package_root/usr/share/applications/ccseegstudio.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$display_name
Comment=$description
Exec=/usr/bin/ccseegstudio
Icon=ccseegstudio
Terminal=false
Categories=Science;Education;MedicalSoftware;
StartupNotify=true
StartupWMClass=ccs_eeg_app
EOF

# ── Build .deb ─────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$output_deb")"
dpkg-deb --build --root-owner-group "$package_root" "$output_deb"

# Verify the output package.
echo ""
echo "=== Package info ==="
dpkg-deb --info "$output_deb"
echo ""
echo "=== Key files ==="
dpkg-deb --contents "$output_deb" | grep -E \
  'usr/bin/ccseegstudio|usr/lib/ccseegstudio/ccs_eeg_app|ccseegstudio.desktop'
