#!/usr/bin/env bash
#
# install.sh — the one file you actually need to fetch by hand. Everything
# else, this handles: making sure you have sudo, updating the system,
# installing git, pulling down the real PrivacyOS repo, and handing off to
# privacyos.sh. See README.md for why it's built this way.
#
# Get this file with your browser (it's guaranteed present — Debian's own
# live images ship one — unlike git/wget/curl, none of which can be
# assumed installed), then from a terminal:
#   chmod +x install.sh
#   ./install.sh
#
set -euo pipefail

REPO_HTTPS="https://github.com/rjc3rd/PrivacyOS.git"
REPO_DIR="PrivacyOS"

log()  { printf '\n\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[install] warning:\033[0m %s\n' "$*" >&2; }

# ---- make sure sudo actually works before relying on it for everything else ----
if ! sudo -n true 2>/dev/null && ! sudo -v 2>/dev/null; then
  cat <<'EOF'

Your user doesn't have sudo access yet.

This is normal if you set a root password during Debian's installer (the
traditional Debian way — different from Ubuntu, which leaves root disabled
and adds your user to sudo automatically instead).

Enter your ROOT password (not your user password) below to fix this:
EOF
  # Full path, not just "usermod" — su without a login shell doesn't load
  # root's PATH, and usermod lives in /usr/sbin, which your own PATH
  # almost certainly doesn't include.
  su -c "/usr/sbin/usermod -aG sudo $(whoami)"
  cat <<'EOF'

Done — your user now has sudo access. This needs a fresh login to take
effect, though (group membership is only checked at login time): log out
and back in (or reboot), then run ./install.sh again.
EOF
  exit 0
fi

# ---- system update + prerequisites ----
log "Updating package lists and upgrading installed packages..."
sudo apt update -y
sudo apt upgrade -y

log "Installing git..."
sudo apt install -y git

# ---- fetch the real repo and hand off ----
if [[ -d "$REPO_DIR/.git" ]]; then
  log "$REPO_DIR already exists — updating it instead of cloning fresh..."
  git -C "$REPO_DIR" pull
else
  log "Cloning $REPO_HTTPS..."
  git clone "$REPO_HTTPS" "$REPO_DIR"
fi

cd "$REPO_DIR"
chmod +x privacyos.sh upgrade 2>/dev/null || true

log "Handing off to privacyos.sh..."
exec ./privacyos.sh "$@"
