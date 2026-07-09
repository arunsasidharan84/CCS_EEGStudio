#!/usr/bin/env bash
# package_linux_rpm.sh — Build an RPM installer for CCS EEG Studio.
#                        Targets RHEL 9, AlmaLinux 9, Rocky Linux 9.
#
# Usage:
#   bash scripts/package_linux_rpm.sh <flutter-bundle-dir> <output.rpm>
#
# Arguments:
#   <flutter-bundle-dir>  Path to the flutter build/linux/x64/release/bundle directory.
#                         Must contain the compiled 'ccs_eeg_app' executable.
#   <output.rpm>          Destination path for the generated .rpm package.
#
# The script reads the version from pubspec.yaml at the repository root.
# It installs the app under /usr/lib/ccseegstudio/, creates a /usr/bin/ccseegstudio
# symlink, registers a .desktop launcher, and installs the app icon.
#
# Requires: rpmbuild (part of rpm-build), available via: sudo dnf install rpm-build
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <flutter-bundle> <output.rpm>" >&2
  exit 2
fi

bundle_dir="$1"
output_rpm="$2"
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
display_name="CCS EEG Studio"
description="EEG feature extraction and connectivity analysis desktop application"

# ── Build RPM staging tree ─────────────────────────────────────────────────
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
top_dir="$work_dir/rpmbuild"
source_dir="$top_dir/SOURCES"
mkdir -p "$source_dir/bundle" "$top_dir/SPECS"

# Copy Flutter bundle into SOURCES.
cp -a "$bundle_dir/." "$source_dir/bundle/"

# Copy icon if available.
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
  install -m 0644 "$icon_src" "$source_dir/ccseegstudio.png"
fi

# ── Generate .desktop file ─────────────────────────────────────────────────
cat > "$source_dir/ccseegstudio.desktop" <<EOF
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

# ── Generate RPM spec ──────────────────────────────────────────────────────
cat > "$top_dir/SPECS/ccseegstudio.spec" <<EOF
%global debug_package %{nil}
Name:           $package_name
Version:        $version
Release:        1%{?dist}
Summary:        $description
License:        Proprietary
URL:            https://github.com/arunsasidharan84/CCS_EEGApp
BuildArch:      x86_64
Requires:       gtk3, glibc, libstdc++, xz-libs
AutoReqProv:    no

%description
CCS EEG Studio is a desktop application for epoch-wise EEG
feature extraction and functional connectivity analysis, implementing
the CCS pipeline with a native Rust computation engine.

%prep

%build

%install
mkdir -p \\
  %{buildroot}/usr/lib/ccseegstudio \\
  %{buildroot}/usr/bin \\
  %{buildroot}/usr/share/applications \\
  %{buildroot}/usr/share/icons/hicolor/256x256/apps

cp -a %{_sourcedir}/bundle/. %{buildroot}/usr/lib/ccseegstudio/
ln -s ../lib/ccseegstudio/ccs_eeg_app %{buildroot}/usr/bin/ccseegstudio

install -m 0644 %{_sourcedir}/ccseegstudio.desktop \\
  %{buildroot}/usr/share/applications/ccseegstudio.desktop

# Install icon only if it was found.
if [[ -f "%{_sourcedir}/ccseegstudio.png" ]]; then
  install -m 0644 %{_sourcedir}/ccseegstudio.png \\
    %{buildroot}/usr/share/icons/hicolor/256x256/apps/ccseegstudio.png
fi

%files
/usr/bin/ccseegstudio
/usr/lib/ccseegstudio
/usr/share/applications/ccseegstudio.desktop
%{?_iconsdir:/usr/share/icons/hicolor/256x256/apps/ccseegstudio.png}

%changelog
* Fri Jul 04 2026 CCS NIMHANS <noreply@github.com> - $version-1
- Automated desktop release
EOF

# ── Build RPM ──────────────────────────────────────────────────────────────
rpmbuild --define "_topdir $top_dir" --target x86_64 \
  -bb "$top_dir/SPECS/ccseegstudio.spec"

built_rpm="$(find "$top_dir/RPMS" -type f -name '*.rpm' -print -quit)"
if [[ -z "$built_rpm" ]]; then
  echo "Error: rpmbuild did not produce an RPM package." >&2
  exit 1
fi

mkdir -p "$(dirname "$output_rpm")"
cp "$built_rpm" "$output_rpm"

# Verify the output package.
echo ""
echo "=== Package info ==="
rpm -qip "$output_rpm"
echo ""
echo "=== Key files ==="
rpm -qlp "$output_rpm" | grep -E \
  '/usr/bin/ccseegstudio|/usr/lib/ccseegstudio/ccs_eeg_app|ccseegstudio.desktop'
