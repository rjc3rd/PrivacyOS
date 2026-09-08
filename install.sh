#!/usr/bin/env bash
#
# install.sh — the one file you actually need to fetch by hand (see the
# one-line curl command in README.md's Quick Start). Everything else, this
# handles: making sure you have sudo, updating the system, pulling down the
# real PrivacyOS repo, and handing off to privacyos.sh.
#
set -euo pipefail

REPO_TARBALL="https://github.com/rjc3rd/PrivacyOS/archive/refs/heads/main.tar.gz"
REPO_DIR="PrivacyOS-main"

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

Done — your user now has sudo access, but it needs a full reboot to
actually take effect. Logging out and back in was tested directly and
confirmed NOT enough on this setup (Cinnamon's session can hold onto
enough state to skip re-checking group membership) — a real reboot is
needed, not just a shorter alternative to one.

privacyos.sh runs almost entirely through sudo, so PrivacyOS can't be
installed until your sudo access is actually active — which means this
reboot has to happen first. Not optional, just asking when, not if.
EOF
  read -r -p "Reboot now? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    # su, not sudo -- you don't have sudo yet, that's the whole reason
    # we're here. Full path again, same PATH reason as usermod above.
    su -c "/usr/sbin/reboot"
  else
    echo "OK — reboot whenever you're ready, then run ./install.sh again from this same directory to continue."
  fi
  exit 0
fi

# ---- system update + basic tools ----
log "Updating package lists and upgrading installed packages..."
sudo apt update -y
sudo apt upgrade -y

log "Installing a basic set of tools..."
# wget and gnupg specifically aren't optional -- privacyos.sh calls wget
# and gpg internally (fetching blocklists/prefs, dearmoring repo keys) and
# can't get past those steps without them. git and curl round out a
# baseline toolset worth having on a system like this regardless of
# whether privacyos.sh itself happens to need them today.
sudo apt install -y wget gnupg git curl

# ---- fetch the real repo and hand off ----
if [[ -d "$REPO_DIR" ]]; then
  log "$REPO_DIR already exists here — using it as-is."
else
  log "Downloading the PrivacyOS repo..."
  curl -fsSL "$REPO_TARBALL" | tar xz
fi

cd "$REPO_DIR"
chmod +x privacyos.sh upgrade 2>/dev/null || true

log "Handing off to privacyos.sh..."
exec ./privacyos.sh "$@"
