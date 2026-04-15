#!/usr/bin/env bash
# Installer for claude-dotfiles.
# - Verifies required tools are present (jq, awk, bash).
# - Symlinks statusline.sh into ~/.claude/.
# - Prints the settings.json snippet for manual wiring (no auto-patch).
#
# Usage: bash install.sh

set -eu

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET_DIR="${HOME}/.claude"

# --- OS detection ---
os="unknown"
case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux)
    if [ -f /etc/synoinfo.conf ] || [ -d /volume1 ]; then
      os="synology"
    elif [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
      os="wsl"
    elif command -v apt-get >/dev/null 2>&1; then
      os="debian"
    elif command -v pacman >/dev/null 2>&1; then
      os="arch"
    elif command -v apk >/dev/null 2>&1; then
      os="alpine"
    else
      os="linux"
    fi
    ;;
esac
echo "detected OS: $os"

# --- required tools ---
REQUIRED=(bash jq awk)
OPTIONAL=(git)

missing=()
for cmd in "${REQUIRED[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

missing_opt=()
for cmd in "${OPTIONAL[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing_opt+=("$cmd")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "error: missing required tools: ${missing[*]}" >&2
  echo "install them with:" >&2
  case "$os" in
    macos)    echo "  brew install ${missing[*]}" >&2 ;;
    debian|wsl)
              echo "  sudo apt-get update && sudo apt-get install -y ${missing[*]}" >&2 ;;
    arch)     echo "  sudo pacman -S --needed ${missing[*]}" >&2 ;;
    alpine)   echo "  sudo apk add ${missing[*]}" >&2 ;;
    synology) echo "  opkg install ${missing[*]}    (requires Entware)" >&2
              echo "  see https://github.com/Entware/Entware/wiki/Install-on-Synology-NAS" >&2 ;;
    *)        echo "  (install via your package manager)" >&2 ;;
  esac
  exit 1
fi

if [ "${#missing_opt[@]}" -gt 0 ]; then
  echo "note: optional tools missing: ${missing_opt[*]} (git branch won't show in statusline)"
fi

# --- jq version sanity check (need >= 1.5 for from_entries) ---
jq_ver=$(jq --version 2>/dev/null | sed -e 's/^jq-//' -e 's/[^0-9.].*//')
jq_major=${jq_ver%%.*}
jq_minor_rest=${jq_ver#*.}
jq_minor=${jq_minor_rest%%.*}
if [ "${jq_major:-0}" -lt 1 ] || { [ "${jq_major:-0}" -eq 1 ] && [ "${jq_minor:-0}" -lt 5 ]; }; then
  echo "error: jq >= 1.5 required (found $jq_ver)" >&2
  exit 1
fi

# --- link statusline.sh into ~/.claude/ ---
mkdir -p "$TARGET_DIR"
chmod +x "$REPO_DIR/statusline.sh"

link="$TARGET_DIR/statusline.sh"
if [ -e "$link" ] && [ ! -L "$link" ]; then
  backup="$link.bak.$(date +%s)"
  mv "$link" "$backup"
  echo "note: moved existing $link -> $backup"
fi
ln -sfn "$REPO_DIR/statusline.sh" "$link"
echo "linked: $link -> $REPO_DIR/statusline.sh"

# --- final instructions ---
cat <<EOF

next step: add this to $TARGET_DIR/settings.json

  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }

if settings.json already has a "statusLine" entry, overwrite it manually
(this installer does not patch json to avoid clobbering your config).
EOF
