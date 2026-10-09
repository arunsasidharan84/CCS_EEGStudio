#!/usr/bin/env bash
# ==============================================================================
# CCS EEG Studio - Enterprise Linux Multi-User Server Installer & Updater
# Repository: https://github.com/arunsasidharan84/CCS_EEGStudio
# ==============================================================================
set -euo pipefail

GITHUB_REPO="arunsasidharan84/CCS_EEGStudio"

echo "======================================================================"
echo "          CCS EEG Studio - Linux Server Installation Setup            "
echo "======================================================================"

if [[ $EUID -ne 0 ]]; then
  echo "Error: This installer requires administrative privileges." >&2
  echo "Please rerun with sudo: sudo bash $0" >&2
  exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
  echo "Error: CCS EEG Studio currently supports x86_64 architecture (detected: $ARCH)." >&2
  exit 1
fi

# Detect Linux Distribution
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  DISTRO_ID=${ID:-linux}
  DISTRO_LIKE=${ID_LIKE:-""}
else
  echo "Warning: Unable to determine Linux distribution from /etc/os-release."
  DISTRO_ID="unknown"
  DISTRO_LIKE=""
fi

IS_RPM=false
IS_DEB=false

if [[ "$DISTRO_ID" =~ ^(rhel|centos|almalinux|rocky|fedora|ol|amzn)$ ]] || [[ "$DISTRO_LIKE" =~ (rhel|fedora|centos) ]]; then
  IS_RPM=true
elif [[ "$DISTRO_ID" =~ ^(ubuntu|debian|linuxmint|pop)$ ]] || [[ "$DISTRO_LIKE" =~ (ubuntu|debian) ]]; then
  IS_DEB=true
elif command -v dnf >/dev/null 2>&1 || command -v rpm >/dev/null 2>&1; then
  IS_RPM=true
elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
  IS_DEB=true
else
  echo "Error: Unsupported package manager. Requires dnf/rpm (EL/Fedora) or apt/dpkg (Ubuntu/Debian)." >&2
  exit 1
fi

echo "--> Target Platform : $DISTRO_ID (arch: $ARCH)"

# Step 1: Repository & System Dependency Setup
echo "--> Preparing repository and system dependencies..."
if [[ "$IS_RPM" = true ]]; then
  if command -v dnf >/dev/null 2>&1; then
    if ! rpm -q epel-release >/dev/null 2>&1; then
      echo "    Installing epel-release repository..."
      dnf install -y epel-release 2>/dev/null || true
    fi
    dnf config-manager --set-enabled crb 2>/dev/null || \
    dnf config-manager --set-enabled powertools 2>/dev/null || true
    dnf install -y gtk3 xz-libs libstdc++ curl 2>/dev/null || true
  fi
elif [[ "$IS_DEB" = true ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends libgtk-3-0 libblkid1 liblzma5 curl 2>/dev/null || true
  fi
fi

# Step 2: Determine package URL from GitHub Releases
echo "--> Fetching latest release information from GitHub..."
RELEASE_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
API_RESPONSE=$(curl -fsSL "$RELEASE_API_URL" 2>/dev/null || true)

if [[ -z "$API_RESPONSE" ]]; then
  echo "    Checking releases index..."
  API_RESPONSE=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases" 2>/dev/null || true)
fi

DOWNLOAD_URL=""
LATEST_TAG=""

if [[ "$IS_RPM" = true ]]; then
  RPM_ASSET_NAME="CCSEEGStudio-linux-x86_64.rpm"
  if [[ -n "$API_RESPONSE" ]]; then
    DOWNLOAD_URL=$(echo "$API_RESPONSE" | grep -o "https://[^\"]*${RPM_ASSET_NAME}" | head -n 1 || true)
    LATEST_TAG=$(echo "$API_RESPONSE" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)
  fi

  if [[ -z "$DOWNLOAD_URL" ]]; then
    LATEST_TAG="v1.2.5"
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${RPM_ASSET_NAME}"
  fi

  PKG_TMP="/tmp/${RPM_ASSET_NAME}"
elif [[ "$IS_DEB" = true ]]; then
  DEB_ASSET_NAME="CCSEEGStudio-linux-amd64.deb"
  if [[ -n "$API_RESPONSE" ]]; then
    DOWNLOAD_URL=$(echo "$API_RESPONSE" | grep -o "https://[^\"]*${DEB_ASSET_NAME}" | head -n 1 || true)
    LATEST_TAG=$(echo "$API_RESPONSE" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)
  fi

  if [[ -z "$DOWNLOAD_URL" ]]; then
    LATEST_TAG="v1.2.5"
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${DEB_ASSET_NAME}"
  fi

  PKG_TMP="/tmp/${DEB_ASSET_NAME}"
fi

echo "--> Latest Release  : ${LATEST_TAG:-v1.2.5}"
echo "--> Downloading package from: $DOWNLOAD_URL"
curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$PKG_TMP"

# Step 3: Install Package
echo "--> Installing package..."
if [[ "$IS_RPM" = true ]]; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$PKG_TMP"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$PKG_TMP"
  else
    rpm -Uvh --replacepkgs "$PKG_TMP"
  fi
elif [[ "$IS_DEB" = true ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y "$PKG_TMP"
  else
    dpkg -i "$PKG_TMP" || apt-get install -f -y
  fi
fi

# Clean up download
rm -f "$PKG_TMP"

# Step 4: Verify & Ensure Native Engine Compatibility
ENGINE_PATH="/usr/lib/ccseegstudio/ccs-eeg-engine"
if [[ -f "$ENGINE_PATH" ]]; then
  echo "--> Verifying native ccs-eeg-engine compatibility..."
  MISSING_SYMBOLS=$(ldd "$ENGINE_PATH" 2>&1 | grep -E "not found|version .* not found" || true)
  if [[ -n "$MISSING_SYMBOLS" ]]; then
    echo "    [WARN] Incompatible dynamic GLIBC symbols detected in ccs-eeg-engine:"
    echo "    $MISSING_SYMBOLS"
    if command -v cargo >/dev/null 2>&1; then
      echo "    [INFO] Rebuilding native ccs-eeg-engine using local rust/cargo toolchain..."
      TMP_BUILD_DIR=$(mktemp -d)
      git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "$TMP_BUILD_DIR/repo" 2>/dev/null || true
      if [[ -d "$TMP_BUILD_DIR/repo/bridge" ]]; then
        (cd "$TMP_BUILD_DIR/repo/bridge" && cargo build --release)
        cp -f "$TMP_BUILD_DIR/repo/bridge/target/release/ccs-eeg-engine" "$ENGINE_PATH"
        chmod 755 "$ENGINE_PATH"
        echo "    [OK] Native ccs-eeg-engine successfully recompiled for this platform."
      fi
      rm -rf "$TMP_BUILD_DIR"
    fi
  else
    echo "    [OK] ccs-eeg-engine linked cleanly against system C runtime."
  fi
fi

# Step 5: Multi-User Desktop & System Integration
echo "--> Configuring multi-user desktop integration across all user accounts..."

# 5a. Ensure icons exist in pixmaps and hicolor icon themes
mkdir -p /usr/share/pixmaps /usr/share/icons/hicolor/256x256/apps
if [[ -f /usr/share/icons/hicolor/256x256/apps/ccseegstudio.png ]] && [[ ! -f /usr/share/pixmaps/ccseegstudio.png ]]; then
  cp -f /usr/share/icons/hicolor/256x256/apps/ccseegstudio.png /usr/share/pixmaps/ccseegstudio.png
elif [[ -f /usr/share/pixmaps/ccseegstudio.png ]] && [[ ! -f /usr/share/icons/hicolor/256x256/apps/ccseegstudio.png ]]; then
  cp -f /usr/share/pixmaps/ccseegstudio.png /usr/share/icons/hicolor/256x256/apps/ccseegstudio.png
fi

# 5b. Update desktop database and icon caches
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi

# 5c. Setup skeleton directory so every future user gets an executable desktop launcher
LAUNCHER="/usr/share/applications/ccseegstudio.desktop"
if [[ -d /etc/skel && -f "$LAUNCHER" ]]; then
  mkdir -p /etc/skel/Desktop
  cp -f "$LAUNCHER" /etc/skel/Desktop/ccseegstudio.desktop
  chmod 755 /etc/skel/Desktop/ccseegstudio.desktop
fi

# 5d. Propagate to all existing user accounts with mode 755 and user ownership
USER_COUNT=0
if [[ -f "$LAUNCHER" ]]; then
  while IFS=: read -r uname _ uid gid _ homedir _; do
    if [[ "$uid" -ge 1000 ]] 2>/dev/null && [[ -d "$homedir" ]]; then
      USER_DESKTOP="$homedir/Desktop"
      if [[ -d "$USER_DESKTOP" ]]; then
        cp -f "$LAUNCHER" "$USER_DESKTOP/ccseegstudio.desktop"
        chmod 755 "$USER_DESKTOP/ccseegstudio.desktop"
        chown "$uid:$gid" "$USER_DESKTOP/ccseegstudio.desktop" 2>/dev/null || true
        USER_COUNT=$((USER_COUNT + 1))
      fi
    fi
  done < <(getent passwd 2>/dev/null || cat /etc/passwd)

  # Also scan common multi-user home mounts (/serverdata/ccshome, /home, /export/home)
  for udir in /serverdata/ccshome/* /home/* /export/home/* /data/home/*; do
    if [[ -d "$udir/Desktop" ]]; then
      cp -f "$LAUNCHER" "$udir/Desktop/ccseegstudio.desktop"
      chmod 755 "$udir/Desktop/ccseegstudio.desktop"
      OWNER=$(stat -c '%u:%g' "$udir" 2>/dev/null || true)
      if [[ -n "$OWNER" ]]; then
        chown "$OWNER" "$udir/Desktop/ccseegstudio.desktop" 2>/dev/null || true
      fi
    fi
  done
fi

echo "--> Propagated desktop shortcut to $USER_COUNT user accounts."

# Step 6: Install system updater command
UPDATER_BIN="/usr/local/bin/update-ccs-eeg-studio"
mkdir -p /usr/local/bin
cat > "$UPDATER_BIN" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "--> Checking for latest CCS EEG Studio updates..."
TMP_SCRIPT=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/arunsasidharan84/CCS_EEGStudio/main/scripts/install_linux.sh" -o "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"
exec bash "$TMP_SCRIPT" "$@"
EOF
chmod 755 "$UPDATER_BIN"
echo "--> Created system updater: $UPDATER_BIN"

# Step 7: Verification
echo "--> Verifying installation..."
if [[ -x /usr/bin/ccseegstudio ]]; then
  echo "    [OK] Main binary: /usr/bin/ccseegstudio"
else
  echo "    [WARN] /usr/bin/ccseegstudio not found or not executable"
fi

if [[ -x /usr/lib/ccseegstudio/ccs-eeg-engine ]]; then
  echo "    [OK] Native engine: /usr/lib/ccseegstudio/ccs-eeg-engine"
else
  echo "    [WARN] ccs-eeg-engine not found"
fi

echo ""
echo "======================================================================"
echo "  CCS EEG Studio installed successfully for all server users!         "
echo "======================================================================"
echo "  • Desktop Launch: Double-click 'CCS EEG Studio' on your Desktop.    "
echo "  • Menu Launch   : Applications > Science / Medical > CCS EEG Studio "
echo "  • Terminal      : Run 'ccseegstudio' from any shell.                "
echo "  • Update Anytime: Run 'sudo update-ccs-eeg-studio'                  "
echo "======================================================================"
