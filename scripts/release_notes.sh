#!/usr/bin/env bash
# Extract one version's Markdown section from CHANGELOG.md.
# Usage: bash scripts/release_notes.sh 1.2.4
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1#v}"
changelog="$repo_root/CHANGELOG.md"

awk -v heading="## [$version]" '
  $0 == heading { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
  END { if (!found) exit 3 }
' "$changelog"
