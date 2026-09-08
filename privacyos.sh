#!/usr/bin/env bash
#
# privacyos.sh — turn a fresh Debian 13 (Trixie) install into PrivacyOS:
# a hardened, privacy-first desktop. https://github.com/rjc3rd/PrivacyOS
#
# This is the one file you need. Fetch it, run it:
#   curl -fsSLO https://raw.githubusercontent.com/rjc3rd/PrivacyOS/main/privacyos.sh
#   chmod +x privacyos.sh
#   ./privacyos.sh
#
# It's fully self-contained on purpose — no sibling files it depends on,
# nothing else to download first. If your user doesn't have sudo access
# yet, it walks you through fixing that (which needs a reboot) and asks
# you to just run it again afterward — apt/package steps are idempotent,
# so a second run picks up quickly rather than needing to resume from
# some particular point.
#
# Usage:
#   ./privacyos.sh [flags]
#   ./privacyos.sh --help
#
# Design notes (see README.md for the full writeup):
#   - Everything installed here comes from apt — Debian's own repos, or a
#     vendor repo added the same way LibreWolf/Waterfox/Mozilla/VSCodium's
#     are. Nothing is a one-off .deb, tarball, AppImage, or Flatpak.
#   - Every optional choice is a flag. Anything not given a flag is asked
#     interactively — as a GUI dialog if zenity/yad is available, a plain
#     terminal prompt otherwise. Pass --yes to skip all prompts and take
#     the defaults noted below.
#   - Must be run as a normal user, NOT as root — sudo is used internally
#     per-command, and it's set up for you automatically if it isn't
#     already there.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Persistent home for custom.hosts/overrides-user.js, independent of wherever
# this script itself is run from — the cloned repo folder might not exist
# anymore by the time `upgrade` needs these later, so they're copied here
# once (without clobbering any edits already made here) and read from here
# from then on, by both this script and `upgrade`.
readonly PRIVACYOS_CONFIG_DIR="$HOME/.config/privacyos"

# ============================================================
# Defaults — "" means "not decided yet, ask interactively"
# ============================================================
DNS_PROVIDER="quad9"        # quad9 | nextdns | opendns | none
WANT_THEME=""                # yes | no | "" (ask)
WANT_APPS=""                  # yes | no | "" (ask)
WANT_LIBREWOLF="yes"
WANT_FIREFOX="yes"
WANT_TOR="yes"
WANT_WATERFOX="yes"
WANT_CHROMIUM="yes"
NONINTERACTIVE="no"
PROMPT_BACKEND=""            # resolved at runtime: zenity | yad | tty

# ============================================================
# Small helpers
# ============================================================
log()  { printf '\n\033[1;32m[privacyos]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[privacyos] warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[privacyos] error:\033[0m %s\n' "$*" >&2; exit 1; }
# A beat after announcing a phase, before its (often noisy) output starts --
# long enough to actually read the line, not so long it drags out testing.
pause() { sleep "${1:-3}"; }
# Confirmed via testing: VMs with NAT-style networking (this project's own
# dev/test setup included) often hand out IPv6 addresses that aren't
# actually routable — wget tries IPv6 first by default, and "Network is
# unreachable" on every IPv6 attempt before falling back to IPv4 adds real,
# felt delay across every single fetch in this script, compounding into
# something that looks like a hang. -4 skips straight to IPv4. Also
# bounded rather than left to wget's own default timeout/retry behavior,
# so a genuine network hiccup fails fast and visibly instead of sitting
# there looking stuck.
fetch() { wget -4 --timeout=15 --tries=2 "$@"; }

usage() {
  cat <<'EOF'
privacyos.sh — hardened, privacy-first Debian 13 (Trixie) setup

  --dns=PROVIDER      quad9 (default) | nextdns | opendns | none
  --theme / --no-theme         desktop theming extras (asks if omitted)
  --apps  / --no-apps           creative/media/dev app bundle (asks if omitted)
  --no-librewolf                skip LibreWolf     (included by default)
  --no-firefox                  skip Firefox        (included by default)
  --no-tor                      skip Tor Browser    (included by default)
  --no-waterfox                 skip Waterfox       (included by default)
  --no-chromium                  skip Chromium (the no-extensions fallback browser)
  --yes                         non-interactive: accept defaults for anything
                                 not given an explicit flag (theme=no, apps=no)
  -h, --help                    show this help and exit

Examples:
  ./privacyos.sh --theme --no-apps --dns=quad9
  ./privacyos.sh --yes --no-tor --no-waterfox
EOF
}

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dns=*)        DNS_PROVIDER="${1#*=}" ;;
      --theme)        WANT_THEME="yes" ;;
      --no-theme)     WANT_THEME="no" ;;
      --apps)         WANT_APPS="yes" ;;
      --no-apps)      WANT_APPS="no" ;;
      --no-librewolf) WANT_LIBREWOLF="no" ;;
      --no-firefox)   WANT_FIREFOX="no" ;;
      --no-tor)       WANT_TOR="no" ;;
      --no-waterfox)  WANT_WATERFOX="no" ;;
      --no-chromium)  WANT_CHROMIUM="no" ;;
      --yes)          NONINTERACTIVE="yes" ;;
      -h|--help)      usage; exit 0 ;;
      *) die "Unknown flag: $1 (see --help)" ;;
    esac
    shift
  done

  case "$DNS_PROVIDER" in
    quad9|nextdns|opendns|none) ;;
    *) die "--dns must be one of: quad9, nextdns, opendns, none (got '$DNS_PROVIDER')" ;;
  esac
}

# ============================================================
# Sanity checks
# ============================================================
require_not_root() {
  # NOT "[[ cond ]] && die ..." -- under set -e, a false [[ ]] test makes
  # that whole line exit 1, which kills the script right here, silently,
  # every single time the condition is (correctly, normally) false. Real
  # bug, found via actual testing -- see the project notes for the story.
  if [[ "${EUID}" -eq 0 ]]; then
    die "Run this as your normal user, not root — it calls sudo itself where needed."
  fi
}

require_debian_trixie() {
  local id="" codename=""
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    id="${ID:-}"
    codename="${VERSION_CODENAME:-}"
  fi
  if [[ "$id" != "debian" || "$codename" != "trixie" ]]; then
    warn "This is built for Debian 13 (Trixie). Detected: ${id:-unknown} ${codename:-unknown}."
    warn "Continuing anyway — expect rough edges on anything else."
  fi
}

confirm_fresh_install() {
  # Same pattern ISPConfig's own installer uses for exactly this reason:
  # this reconfigures a lot, it's built for a machine with nothing on it
  # you care about yet, and a typed "yes" (not a y/N keypress, not a GUI
  # button) is a deliberately higher bar for a genuinely consequential
  # confirmation — easy to fat-finger a click, harder to type the wrong
  # word by accident.
  if [[ "$NONINTERACTIVE" == "yes" ]]; then
    warn "Skipping the fresh-install confirmation because of --yes — make sure that's really what you meant."
    return
  fi
  cat <<'EOF'

==============================================================================
 This script reconfigures a lot: package sources, installed packages,
 /etc/hosts, browser profiles, and more.

 It's built for a FRESH Debian install — a machine with nothing on it you
 care about yet. Running it on a system you're already using, with real
 data or configuration you don't want touched, is not supported and can
 change or remove things you didn't expect.

 If that's this machine, stop now.
==============================================================================

EOF
  local reply
  read -r -p "Type 'yes' to confirm this is a fresh install you're OK with changing: " reply
  [[ "$reply" == "yes" ]] || die "Not confirmed — exiting without changing anything."
}

ensure_sudo_or_fix_and_exit() {
  # Fresh Debian installs don't always leave the user in the sudo group --
  # depends on whether a root password was set during Debian's installer
  # (the traditional Debian way; different from Ubuntu, which leaves root
  # disabled and adds the user to sudo automatically instead). If sudo
  # already works, there's nothing to do here.
  if sudo -n true 2>/dev/null || sudo -v 2>/dev/null; then
    return
  fi
  cat <<'EOF'

Your user doesn't have sudo access yet.

This is normal if you set a root password during Debian's installer.
Enter your ROOT password (not your user password) below to fix this:
EOF
  # Full path, not just "usermod" — su without a login shell doesn't load
  # root's PATH, and usermod lives in /usr/sbin, which your own PATH
  # almost certainly doesn't include. Learned this the hard way — see the
  # project notes if curious.
  su -c "/usr/sbin/usermod -aG sudo $(whoami)"
  cat <<'EOF'

Done — your user now has sudo access, but it needs a full reboot to
actually take effect. Logging out and back in was tested directly and
confirmed NOT enough on this setup (Cinnamon's session can hold onto
enough state to skip re-checking group membership) — a real reboot is
needed, not just a shorter alternative to one.

The rest of this script runs almost entirely through sudo, so it can't
continue until your sudo access is actually active — which means this
reboot has to happen first. Not optional, just asking when, not if.

If you say yes below, you'll be asked for your root password one more
time — su asks fresh each time, it doesn't remember the one you just
typed — that's what actually triggers the reboot itself.
EOF
  local reply
  read -r -p "Reboot now? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    # su, not sudo -- you don't have sudo yet, that's the whole reason
    # we're here. Full path again, same PATH reason as usermod above.
    su -c "/usr/sbin/reboot"
  else
    echo "OK — reboot whenever you're ready, then run ./privacyos.sh again to continue."
  fi
  exit 0
}

install_basic_tools() {
  log "Now we begin the OS update/upgrade..."
  pause
  sudo apt update -y
  sudo apt upgrade -y

  log "Now we install a small tool set for the rest of the PrivacyOS installation..."
  # wget and gnupg specifically aren't optional -- this script calls wget
  # and gpg internally further down (fetching blocklists/prefs, dearmoring
  # repo keys) and can't get past those steps without them. git and curl
  # round out a baseline toolset worth having on a system like this
  # regardless of whether this script itself happens to need them today.
  pause
  sudo apt install -y wget gnupg git curl
}

keep_sudo_alive() {
  sudo -v || die "This script needs sudo access."
  ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

# ============================================================
# Interactive prompt backend — GUI first, terminal fallback
# ============================================================
ensure_prompt_backend() {
  if command -v zenity >/dev/null 2>&1; then PROMPT_BACKEND="zenity"; return; fi
  if command -v yad    >/dev/null 2>&1; then PROMPT_BACKEND="yad";    return; fi
  # Try a quiet, best-effort install; fall back to plain terminal prompts if it fails.
  if sudo apt-get install -y zenity >/dev/null 2>&1; then
    PROMPT_BACKEND="zenity"
  else
    PROMPT_BACKEND="tty"
    warn "No GUI dialog tool available — falling back to plain terminal prompts."
  fi
}

# ask_yesno "Question text" -> returns 0 for yes, 1 for no
ask_yesno() {
  local question="$1"
  case "$PROMPT_BACKEND" in
    zenity) zenity --question --title="PrivacyOS setup" --width=420 --text="$question" ;;
    yad)    yad --question --title="PrivacyOS setup" --width=420 --text="$question" ;;
    *)
      local reply
      read -r -p "$question [y/N] " reply
      [[ "$reply" =~ ^[Yy]$ ]]
      ;;
  esac
}

resolve_interactive_choices() {
  if [[ -z "$WANT_THEME" ]]; then
    if [[ "$NONINTERACTIVE" == "yes" ]]; then
      WANT_THEME="no"
    elif ask_yesno "Install desktop theming (Cinnamon config, Mint-Y-Dark theme, icons, wallpapers)?\n\nThis only changes how the desktop looks — skip it and you still get the full hardening/privacy setup."; then
      WANT_THEME="yes"
    else
      WANT_THEME="no"
    fi
  fi

  if [[ -z "$WANT_APPS" ]]; then
    if [[ "$NONINTERACTIVE" == "yes" ]]; then
      WANT_APPS="no"
    elif ask_yesno "Install the creative/media/dev app bundle (GIMP, Inkscape, darktable, VSCodium, and more)?\n\nNone of this is hardening — it's the extras. Skip it for a minimal install."; then
      WANT_APPS="yes"
    else
      WANT_APPS="no"
    fi
  fi
}

# ============================================================
# apt helpers
# ============================================================
apt_update()  { sudo apt-get update; }
apt_upgrade() { sudo apt-get upgrade -y; }
apt_install() { sudo apt-get install -y "$@"; }
apt_purge()   { sudo apt-get remove --purge -y "$@" || warn "Some packages in that purge list weren't installed — that's fine, continuing."; }
purge_old_kernels() {
  # Every apt_upgrade that includes a new kernel leaves the old one behind —
  # autoremove alone doesn't always catch these. Never touches the kernel
  # actually running right now.
  #
  # This whole pipeline is wrapped rather than run bare, for a real,
  # confirmed-via-testing reason: with pipefail active, dpkg -l returns
  # non-zero the instant EITHER pattern matches nothing at all (e.g. no
  # linux-headers-* installed, common on a desktop image) even though the
  # OTHER pattern found real packages to purge -- and grep returns
  # non-zero too if there's simply nothing left to purge (also common,
  # e.g. right after a fresh install with only one kernel). Either one
  # poisons the whole pipeline's exit status and set -e kills the entire
  # script right after a purge that actually succeeded, silently, no
  # error. This is a tidy-up step, not load-bearing -- let it be
  # best-effort rather than fatal.
  local old_kernels
  old_kernels="$(dpkg -l 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null \
    | awk '/^ii/{print $2}' \
    | grep -v -- "$(uname -r | cut -f1,2 -d'-')" \
    | grep -e '[0-9]')" || true
  if [[ -n "$old_kernels" ]]; then
    echo "$old_kernels" | xargs -r sudo apt-get -y purge \
      || warn "Couldn't purge some old kernel packages — not fatal, continuing."
  fi
}
apt_cleanup() { purge_old_kernels; sudo apt-get clean -y; sudo apt-get autoclean -y; sudo apt-get autoremove --purge -y; }

# ============================================================
# Sections
# ============================================================

configure_sources_list() {
  log "Everything from here is unattended — no more prompts until it's done. This is where the real changes actually happen: packages, repos, DNS, the hosts file, browser hardening. Expect 15-20 minutes depending on your connection and hardware — long quiet stretches are normal while apt or a download works in the background, not a sign it's stuck."
  pause 5
  log "Writing /etc/apt/sources.list for Debian 13 (Trixie)..."
  # Explicit codename, never the generic "stable" alias — keeps this script's
  # target fixed even after the next Debian release ships and stable moves on.
  sudo tee /etc/apt/sources.list > /dev/null <<'EOF'
# sources.list written by PrivacyOS (privacyos.sh)
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
  sudo mkdir -p /etc/apt/keyrings
  apt_update
}

purge_bloat() {
  log "Removing default apps this project doesn't need..."
  apt_purge xterm remmina hexchat gnote brasero pidgin gnome-sound-recorder \
    sound-juicer shotwell firefox-esr transmission-gtk deja-dup rhythmbox \
    totem gnome-games
  apt_cleanup
}

add_repos() {
  log "Adding browser/tool repositories (all real vendor apt repos, no one-off downloads)..."

  if [[ "$WANT_LIBREWOLF" == "yes" ]]; then
    apt_install extrepo
    sudo extrepo enable librewolf
  fi

  if [[ "$WANT_FIREFOX" == "yes" ]]; then
    fetch -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
      | sudo tee /etc/apt/keyrings/mozilla.org.asc > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
      | sudo tee /etc/apt/sources.list.d/mozilla.list > /dev/null
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
      | sudo tee /etc/apt/preferences.d/mozilla > /dev/null
  fi

  if [[ "$WANT_WATERFOX" == "yes" ]]; then
    # BrowserWorks' own repo (hosted on openSUSE Build Service) — the
    # LEAP/hawkeye116477 repo it replaced is retired, don't use it.
    curl -fsSL https://download.opensuse.org/repositories/isv:/BrowserWorks/Debian_13/Release.key \
      | gpg --dearmor | sudo tee /usr/share/keyrings/waterfox.gpg > /dev/null
    echo 'deb [signed-by=/usr/share/keyrings/waterfox.gpg] https://download.opensuse.org/repositories/isv:/BrowserWorks/Debian_13/ /' \
      | sudo tee /etc/apt/sources.list.d/waterfox.list > /dev/null
  fi

  if [[ "$WANT_APPS" == "yes" ]]; then
    fetch -qO- https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
      | gpg --dearmor | sudo tee /etc/apt/keyrings/vscodium.gpg > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/vscodium.gpg] https://download.vscodium.com/debs vscodium main" \
      | sudo tee /etc/apt/sources.list.d/vscodium.list > /dev/null
  fi

  apt_update
}

install_core_packages() {
  log "Installing core privacy/security tooling..."
  # wireshark-common's installer normally asks whether to let non-root
  # users capture packets (via the "wireshark" group + setcap on dumpcap,
  # the recommended way — better than running the whole GUI as root).
  # Default is "no" either way, seen or not, which means the group never
  # gets created and the usermod right after this would fail outright.
  # Pre-answer it so this doesn't depend on how that prompt gets handled.
  echo "wireshark-common wireshark-common/install-setuid boolean true" | sudo debconf-set-selections
  apt_install secure-delete wipe bleachbit riseup-vpn tor keepassxc wireshark
  sudo dpkg-reconfigure -f noninteractive wireshark-common
  sudo usermod -a -G wireshark "$USER" \
    || warn "Couldn't add you to the wireshark group — non-root packet capture may not work, but continuing anyway."
  # Doesn't take effect for this session until the next login — the
  # script's own final reboot at the end handles that.

  mkdir -p "$HOME/.local/share/nemo/scripts"
  printf '#!/bin/sh\nsrm -llrv "$@"\n' > "$HOME/.local/share/nemo/scripts/Secure-Delete"
  chmod +x "$HOME/.local/share/nemo/scripts/Secure-Delete"

  log "Installing browsers..."
  # Same set -e trap as require_not_root above -- these were the more
  # serious instances of it: every one of --no-librewolf/--no-firefox/
  # --no-tor/--no-waterfox/--no-chromium would have killed the script
  # silently the moment it evaluated the browser you opted out of.
  local browsers=()
  if [[ "$WANT_LIBREWOLF" == "yes" ]]; then browsers+=(librewolf); fi
  if [[ "$WANT_FIREFOX"   == "yes" ]]; then browsers+=(firefox); fi
  if [[ "$WANT_TOR"       == "yes" ]]; then browsers+=(torbrowser-launcher); fi
  if [[ "$WANT_WATERFOX"  == "yes" ]]; then browsers+=(waterfox); fi
  if [[ "$WANT_CHROMIUM"  == "yes" ]]; then browsers+=(chromium); fi
  if ((${#browsers[@]})); then apt_install "${browsers[@]}"; fi
  # Chromium is deliberately left bare — no extensions, no config changes.
  # It exists purely as a fallback for the rare site a hardened browser breaks.

  log "Installing Thunderbird..."
  apt_install thunderbird
}

configure_dns() {
  if [[ "$DNS_PROVIDER" == "none" ]]; then
    log "Leaving DNS resolver at whatever the network/ISP provides (--dns=none)."
    return
  fi

  if [[ "$DNS_PROVIDER" == "nextdns" ]]; then
    warn "NextDNS uses a per-account config ID, not a shared address — it can't be"
    warn "wired in generically here. See https://my.nextdns.io for your own ID and"
    warn "https://github.com/nextdns/nextdns for their official Linux client."
    return
  fi

  log "Configuring encrypted DNS ($DNS_PROVIDER) via systemd-resolved..."
  # Unlike Ubuntu, Debian doesn't install or enable systemd-resolved by
  # default — NetworkManager writes /etc/resolv.conf directly instead, and
  # the service unit genuinely isn't there until installed. Confirmed via
  # testing, not assumed — it's a real, separate package on Trixie, not
  # bundled into systemd itself.
  apt_install systemd-resolved
  sudo systemctl enable --now systemd-resolved

  local dns_setting dot_enabled="yes"
  case "$DNS_PROVIDER" in
    quad9)   dns_setting="9.9.9.9#dns.quad9.net" ;;
    opendns)
      dns_setting="208.67.222.222 208.67.220.220"
      dot_enabled="no"
      warn "OpenDNS's DNS-over-TLS support isn't well established — configuring plain DNS only, not encrypted."
      ;;
  esac

  sudo mkdir -p /etc/systemd/resolved.conf.d
  {
    echo "[Resolve]"
    echo "DNS=$dns_setting"
    echo "DNSOverTLS=$dot_enabled"
  } | sudo tee /etc/systemd/resolved.conf.d/privacyos-dns.conf > /dev/null

  # Keep NetworkManager from overriding this with per-connection DHCP-provided DNS.
  sudo mkdir -p /etc/NetworkManager/conf.d
  printf '[main]\ndns=systemd-resolved\n' \
    | sudo tee /etc/NetworkManager/conf.d/privacyos-dns.conf > /dev/null

  sudo systemctl restart systemd-resolved \
    || warn "Couldn't restart systemd-resolved — DNS config may not be active yet, but continuing."
  sudo systemctl restart NetworkManager 2>/dev/null || true
  warn "DNS config is a first pass — verify 'resolvectl status' shows it after reboot; network-manager interactions can vary by hardware."
}

init_config_dir() {
  mkdir -p "$PRIVACYOS_CONFIG_DIR"
  # Bundled defaults are embedded directly below (this script is meant to
  # be fetched and run as a single file — no sibling files to depend on)
  # and only written out if not already there — a second run (or `upgrade`
  # later) must never clobber edits already made here.
  if [[ ! -f "$PRIVACYOS_CONFIG_DIR/custom.hosts" ]]; then
    cat > "$PRIVACYOS_CONFIG_DIR/custom.hosts" <<'CUSTOM_HOSTS_EOF'
# custom.hosts — your own additions, merged into /etc/hosts ahead of the
# StevenBlack list every time privacyos.sh or upgrade runs. Nothing in
# this file is downloaded from anywhere; it's yours to edit.
#
# Same format as any hosts file — one entry per line:
#   0.0.0.0 some-domain-you-want-blocked.com
#
# Empty by default. Add whatever you personally want blocked (or, for
# entries you need to make sure *aren't* blocked, see the README's note
# on resolving conflicts with the StevenBlack list — this file is merged
# in first, so an entry here takes priority over anything StevenBlack
# blocks for the same hostname).
CUSTOM_HOSTS_EOF
  fi
  if [[ ! -f "$PRIVACYOS_CONFIG_DIR/overrides-user.js" ]]; then
    cat > "$PRIVACYOS_CONFIG_DIR/overrides-user.js" <<'OVERRIDES_EOF'
// PrivacyOS overrides-user.js
//
// Applied on top of Arkenfox + Betterfox (Firefox/Waterfox), or by itself on
// LibreWolf (which already hardens its own defaults heavily — layering the
// full Arkenfox/Betterfox set on it risks fighting settings it made on
// purpose). This file is intentionally small: a starting point, not a
// complete hardening profile — that's what Arkenfox/Betterfox already are.
// Add to it as real usage turns up more.

// Turn off Firefox Sync / accounts prompts — this project doesn't want
// browser profiles phoning home to a Mozilla account by default.
user_pref("identity.fxaccounts.enabled", false);

// Pocket is a third-party save-for-later service wired into the UI by
// default — no reason for it to be on in a privacy-first browser.
user_pref("extensions.pocket.enabled", false);

// Suppress the "make this your default browser" startup nag. LibreWolf is
// set as the actual system default by privacyos.sh itself (see
// set_default_browser()), so Firefox and Waterfox don't need to keep
// asking. Redundant on LibreWolf — its own policies.json already sets
// DontCheckDefaultBrowser — but harmless to also set here.
user_pref("browser.shell.checkDefaultBrowser", false);
OVERRIDES_EOF
  fi
}

build_hosts_blocklist() {
  log "Building /etc/hosts from the StevenBlack list + your own custom.hosts..."
  # Deliberately just one blocklist source, not a stack of them. Stacking
  # several different maintainers' lists compounds the risk of an
  # overzealous or stale entry blackholing a domain some site actually
  # needs — real, repeated breakage from exactly that is why this project
  # settled on StevenBlack alone: well-maintained, good coverage-vs-false-
  # positive balance, and one source means one thing that can go stale.
  local workdir
  workdir="$(mktemp -d)"
  : > "$workdir/hosts.new"
  printf '127.0.0.1 localhost\n127.0.1.1 privacyos\n::1 localhost ip6-localhost ip6-loopback\n\n' >> "$workdir/hosts.new"

  # custom.hosts lives in $PRIVACYOS_CONFIG_DIR (not next to the script —
  # see init_config_dir) so it survives even if the cloned repo folder gets
  # deleted later. Never downloaded — it's the place to hand-add your own
  # entries. Merged in first, same as the old script's .PrivacyOS.hosts did.
  local custom_hosts="$PRIVACYOS_CONFIG_DIR/custom.hosts"
  if [[ -f "$custom_hosts" ]]; then cat "$custom_hosts" >> "$workdir/hosts.new"; fi

  if fetch -qO- https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts >> "$workdir/hosts.new" 2>/dev/null; then
    log "  merged StevenBlack/hosts"
  else
    warn "  couldn't fetch the StevenBlack list this run — /etc/hosts will only have your custom.hosts entries"
  fi

  sudo cp "$workdir/hosts.new" /etc/hosts
  rm -rf "$workdir"
}

# bootstrap_and_rename_profile <browser_cmd> <profile_root> <user_js_source> <new_name>
#
# Firefox-family browsers discover their profile via profiles.ini/
# installs.ini (each install's own section, keyed by a CityHash64 of its
# install directory -- confirmed against Mozilla's own source, not guessed:
# toolkit/mozapps/update/common/commonupdatedir.cpp) -- not by scanning for a
# folder that looks right. On a genuinely fresh install (browser installed
# via apt, never launched) that manifest doesn't exist yet, so there's no
# profile to drop user.js into. Used to mean harden_browsers() silently did
# nothing for every browser, every single fresh-install run -- caught via
# real testing, not caught by anything in the script itself (see CLAUDE.md,
# "user.js not landing on a truly fresh install").
#
# Fixed by having the script create that first-launch moment itself: a brief
# --headless run (no window, no display server needed -- a real Gecko
# engine feature, not an Xvfb-style hack) is enough to make the browser
# bootstrap its own real profile and register its own real, correctly-
# computed install-hash, for wherever this specific machine's package
# actually put the binary -- nothing hardcoded or precomputed. Immediately
# after, that freshly-registered profile is renamed (folder moved, then
# Default=/Name=/Path= rewritten in its own profiles.ini to match -- the
# install-hash section itself is never touched) to a fixed, known name so
# later steps (and `upgrade`) can find it without guessing either. This
# exact rename was tested directly, by hand, on real installs of all three
# browsers before being scripted here: zero orphaned duplicate profiles, and
# on Waterfox specifically, a real profile with real bookmarks survived the
# round-trip intact.
bootstrap_and_rename_profile() {
  local browser_cmd="$1" profile_root="$2" user_js_source="$3" new_name="$4"
  command -v "$browser_cmd" >/dev/null 2>&1 || return

  timeout 20 "$browser_cmd" --headless >/dev/null 2>&1 &
  local pid=$!
  sleep 6
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  local ini="$profile_root/profiles.ini"
  if [[ ! -f "$ini" ]]; then
    warn "$browser_cmd didn't create a profile after a headless launch -- skipping its hardening this run. Launch it once yourself, then re-run this script."
    return
  fi

  # The install-hash section's Default= line names whatever random-salt
  # folder the browser just generated for itself -- read that back rather
  # than assume a naming pattern.
  local old_name
  old_name="$(sed -n 's/^Default=//p' "$ini" | head -n1)" || true
  if [[ -z "$old_name" || ! -d "$profile_root/$old_name" ]]; then
    warn "Couldn't identify $browser_cmd's freshly-created profile -- skipping its hardening this run."
    return
  fi

  if ! mv "$profile_root/$old_name" "$profile_root/$new_name" 2>/dev/null; then
    warn "Couldn't rename $browser_cmd's profile folder -- skipping its hardening this run."
    return
  fi
  sed -i -E "s/^(Default=).*/\1$new_name/; s/^(Name=).*/\1$new_name/; s/^(Path=).*/\1$new_name/" "$ini" \
    || warn "Renamed $browser_cmd's profile folder but couldn't update profiles.ini to match -- it may not be found correctly."
  cp "$user_js_source" "$profile_root/$new_name/user.js" \
    || warn "Couldn't copy hardened preferences into $browser_cmd's profile."
}

harden_browsers() {
  log "Building hardened browser preferences (Arkenfox + Betterfox)..."
  local workdir
  workdir="$(mktemp -d)"
  fetch -qO "$workdir/arkenfox-user.js" https://raw.githubusercontent.com/arkenfox/user.js/master/user.js \
    || warn "couldn't fetch Arkenfox user.js"
  fetch -qO "$workdir/betterfox-user.js" https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js \
    || warn "couldn't fetch Betterfox user.js"
  local overrides="$PRIVACYOS_CONFIG_DIR/overrides-user.js"
  cat "$workdir"/arkenfox-user.js "$workdir"/betterfox-user.js "$overrides" \
    > "$workdir/full-user.js" 2>/dev/null || cat "$workdir"/arkenfox-user.js "$workdir"/betterfox-user.js > "$workdir/full-user.js"

  # LibreWolf already hardens its own defaults heavily — layering the full
  # Arkenfox/Betterfox set on top risks fighting settings it already made
  # deliberately. Give it just the project's own small overrides instead.
  if [[ "$WANT_LIBREWOLF" == "yes" ]]; then
    bootstrap_and_rename_profile librewolf "$HOME/.librewolf" "$overrides" PrivacyOS
  fi
  if [[ "$WANT_FIREFOX" == "yes" ]]; then
    bootstrap_and_rename_profile firefox "$HOME/.mozilla/firefox" "$workdir/full-user.js" PrivacyOS
  fi
  if [[ "$WANT_WATERFOX" == "yes" ]]; then
    bootstrap_and_rename_profile waterfox "$HOME/.waterfox" "$workdir/full-user.js" PrivacyOS
  fi

  rm -rf "$workdir"
}

configure_extensions() {
  log "Force-installing the standard extension set via policies.json..."
  # All IDs/slugs below were pulled from each extension's real .xpi manifest,
  # not guessed — see the project's commit history for how.
  #
  # uBlock Origin is left out of Waterfox's list on purpose: Waterfox has its
  # own native ad-blocking engine built in (Brave's engine, using uBlock
  # Origin's own filter lists) rather than the extension, so installing the
  # actual extension on top of it would just be redundant.
  #
  # LibreWolf's block below is a MERGE, not a fresh file: Firefox-family
  # browsers use exactly one policies.json (picked by priority, never
  # merged with any other), and LibreWolf ships its own — pulled directly
  # from https://codeberg.org/librewolf/settings/src/branch/master/distribution/policies.json
  # (2026-09-07) and reproduced here in full, with this project's extensions
  # added into its existing ExtensionSettings block. LibreWolf's own file
  # already installs uBlock Origin itself (installation_mode:
  # normal_installed — pre-installed but removable, not locked) — left
  # exactly as LibreWolf has it, not touched or upgraded to force_installed.
  # If LibreWolf changes their own defaults later, this copy will drift out
  # of sync — worth re-diffing against their settings repo occasionally, not
  # a one-time copy to trust forever.

  if [[ "$WANT_FIREFOX" == "yes" ]]; then
    sudo mkdir -p /etc/firefox/policies
    sudo tee /etc/firefox/policies/policies.json > /dev/null <<'JSON'
{
  "policies": {
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi",
        "installation_mode": "force_installed"
      },
      "{74145f27-f039-47ce-a470-a662b129930a}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/clearurls/latest.xpi",
        "installation_mode": "force_installed"
      },
      "dont-track-me-google@robwu.nl": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/dont-track-me-google1/latest.xpi",
        "installation_mode": "force_installed"
      },
      "keepassxc-browser@keepassxc.org": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/keepassxc-browser/latest.xpi",
        "installation_mode": "force_installed"
      },
      "{b86e4813-687a-43e6-ab65-0bde4ab75758}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/localcdn-fork-of-decentraleyes/latest.xpi",
        "installation_mode": "force_installed"
      },
      "{d3300f05-ef12-4598-a6a4-2432b935ef59}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/tortm-browser-button/latest.xpi",
        "installation_mode": "force_installed"
      },
      "{6c00218c-707a-4977-84cf-36df1cef310f}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/port-authority/latest.xpi",
        "installation_mode": "force_installed"
      },
      "sponsorBlocker@ajay.app": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/sponsorblock/latest.xpi",
        "installation_mode": "force_installed"
      }
    },
    "SearchEngines": {
      "Add": [
        {
          "Name": "ProxySearch",
          "URLTemplate": "https://proxysearch.org/search.php?q={searchTerms}",
          "Method": "GET",
          "IconURL": "https://proxysearch.org/favicon.svg",
          "Alias": "ps",
          "Description": "Privacy-respecting meta search — proxysearch.org"
        }
      ],
      "Default": "ProxySearch"
    }
  }
}
JSON
  fi

  if [[ "$WANT_WATERFOX" == "yes" ]]; then
    # Same path convention as LibreWolf's, substituting Waterfox's own name —
    # unconfirmed on real hardware yet, flagged like the DNS section is.
    sudo mkdir -p /etc/waterfox/policies
    sudo tee /etc/waterfox/policies/policies.json > /dev/null <<'JSON'
{
  "policies": {
    "ExtensionSettings": {
      "{74145f27-f039-47ce-a470-a662b129930a}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/clearurls/latest.xpi",
        "installation_mode": "force_installed"
      },
      "dont-track-me-google@robwu.nl": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/dont-track-me-google1/latest.xpi",
        "installation_mode": "force_installed"
      },
      "keepassxc-browser@keepassxc.org": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/keepassxc-browser/latest.xpi",
        "installation_mode": "force_installed"
      },
      "{b86e4813-687a-43e6-ab65-0bde4ab75758}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/localcdn-fork-of-decentraleyes/latest.xpi",
        "installation_mode": "force_installed"
      },
      "{d3300f05-ef12-4598-a6a4-2432b935ef59}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/tortm-browser-button/latest.xpi",
        "installation_mode": "force_installed"
      },
      "{6c00218c-707a-4977-84cf-36df1cef310f}": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/port-authority/latest.xpi",
        "installation_mode": "force_installed"
      },
      "sponsorBlocker@ajay.app": {
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/sponsorblock/latest.xpi",
        "installation_mode": "force_installed"
      }
    },
    "SearchEngines": {
      "Add": [
        {
          "Name": "ProxySearch",
          "URLTemplate": "https://proxysearch.org/search.php?q={searchTerms}",
          "Method": "GET",
          "IconURL": "https://proxysearch.org/favicon.svg",
          "Alias": "ps",
          "Description": "Privacy-respecting meta search — proxysearch.org"
        }
      ],
      "Default": "ProxySearch"
    }
  }
}
JSON
  fi

  if [[ "$WANT_LIBREWOLF" == "yes" ]]; then
    sudo mkdir -p /etc/librewolf/policies
    sudo tee /etc/librewolf/policies/policies.json > /dev/null <<'JSON'
{
    "__COMMENT__ More Information": "https://github.com/mozilla/policy-templates/blob/master/README.md",
    "policies": {
        "AIControls": {
            "Translations": { "Value": "available" },
            "PDFAltText": { "Value": "blocked" },
            "SmartTabGroups": { "Value": "blocked" },
            "LinkPreviewKeyPoints": { "Value": "blocked" },
            "SidebarChatbot": { "Value": "blocked" },
            "SmartWindow": { "Value": "blocked" }
        },
        "AppUpdateURL": "https://localhost",
        "DisableAppUpdate": true,
        "DisableDefaultBrowserAgent": true,
        "DisableFeedbackCommands": true,
        "DisableFirefoxStudies": true,
        "DisableRemoteImprovements": true,
        "DisableSetDesktopBackground": false,
        "DisableTelemetry": true,
        "DontCheckDefaultBrowser": true,
        "WebsiteFilter": {
            "Block": ["https://localhost/*"],
            "Exceptions": ["https://localhost/*"]
        },
        "EncryptedMediaExtensions": { "Enabled": false },
        "ExtensionSettings": {
            "*": {
                "blocked_install_message": "LibreWolf does not allow installing Language Packs.",
                "installation_mode": "allowed",
                "allowed_types": ["dictionary", "extension", "sitepermission", "theme"]
            },
            "uBlock0@raymondhill.net": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/uBlock0@raymondhill.net/latest.xpi",
                "installation_mode": "normal_installed",
                "private_browsing": true
            },
            "{74145f27-f039-47ce-a470-a662b129930a}": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/clearurls/latest.xpi",
                "installation_mode": "force_installed"
            },
            "dont-track-me-google@robwu.nl": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/dont-track-me-google1/latest.xpi",
                "installation_mode": "force_installed"
            },
            "keepassxc-browser@keepassxc.org": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/keepassxc-browser/latest.xpi",
                "installation_mode": "force_installed"
            },
            "{b86e4813-687a-43e6-ab65-0bde4ab75758}": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/localcdn-fork-of-decentraleyes/latest.xpi",
                "installation_mode": "force_installed"
            },
            "{d3300f05-ef12-4598-a6a4-2432b935ef59}": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/tortm-browser-button/latest.xpi",
                "installation_mode": "force_installed"
            },
            "{6c00218c-707a-4977-84cf-36df1cef310f}": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/port-authority/latest.xpi",
                "installation_mode": "force_installed"
            },
            "sponsorBlocker@ajay.app": {
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/sponsorblock/latest.xpi",
                "installation_mode": "force_installed"
            }
        },
        "FirefoxHome": {
            "Weather": false, "TopSites": false, "SponsoredTopSites": false,
            "Highlights": false, "Stories": false, "SponsoredStories": false
        },
        "FirefoxSuggest": {
            "WebSuggestions": false, "SponsoredSuggestions": false, "ImproveSuggest": false
        },
        "HttpsOnlyMode": "enabled",
        "LocalNetworkAccess": { "Enabled": true, "BlockTrackers": true, "EnablePrompting": true },
        "NoDefaultBookmarks": true,
        "OverridePostUpdatePage": "",
        "SearchEngines": {
            "Add": [
                {
                    "Name": "ProxySearch",
                    "URLTemplate": "https://proxysearch.org/search.php?q={searchTerms}",
                    "Method": "GET",
                    "IconURL": "https://proxysearch.org/favicon.svg",
                    "Alias": "ps",
                    "Description": "Privacy-respecting meta search — proxysearch.org"
                }
            ],
            "Default": "ProxySearch"
        },
        "SkipTermsOfUse": true,
        "SupportMenu": { "Title": "LibreWolf Issue Tracker", "URL": "https://codeberg.org/librewolf/issues" },
        "UserMessaging": {
            "UrlbarInterventions": false, "SkipOnboarding": true, "MoreFromMozilla": false, "FirefoxLabs": false
        }
    }
}
JSON
  fi

  warn "policies.json paths are unconfirmed on real hardware — verify the extensions actually appear after first launch, per browser."
  warn "SearchEngines (ProxySearch as default) is also unconfirmed on real hardware — verify each browser actually offers/defaults to it after first launch."
}

set_default_browser() {
  if [[ "$WANT_LIBREWOLF" != "yes" ]]; then
    return
  fi
  log "Setting LibreWolf as the default browser..."
  # xdg-settings (from xdg-utils) is the standard, desktop-environment-aware
  # way to do this -- it updates ~/.config/mimeapps.list itself. Confirmed
  # via LibreWolf's own Debian packaging (gitlab.com/librewolf-community/
  # browser/linux) that the native .deb installs its desktop file as
  # librewolf.desktop under /usr/share/applications -- not the Flatpak ID
  # (io.gitlab.librewolf-community.desktop), which doesn't apply here since
  # this project only ever installs the native apt package.
  apt_install xdg-utils
  xdg-settings set default-web-browser librewolf.desktop \
    || warn "Couldn't set LibreWolf as the default browser automatically — set it manually in Cinnamon's Preferred Applications if it matters to you."
}

install_theme_extras() {
  log "Desktop theming: not bundled in this script yet — see extras/theme/ in the repo."
  # Intentionally separate from core, per the project's own decision: someone
  # who just wants the hardening shouldn't be forced into these opinions.
}

install_apps_extras() {
  log "Installing the creative/media/dev app bundle..."
  apt_install gimp inkscape darktable rawtherapee scribus flowblade audacity \
    audacious mpv celluloid deluge filezilla simplescreenrecorder codium \
    terminator mintstick dconf-editor gnome-clocks

  log "Installing a small, deliberately curated set of basic games..."
  # Explicitly not the old gnome-games bundle (already purged in core) --
  # a specific, chosen list instead of everything that used to ship
  # together, so this doesn't reintroduce the exact bloat that got removed.
  apt_install gnome-mahjongg gnome-mines moon-lander iagno aisleriot \
    gnome-sudoku tali
}

install_upgrade_command() {
  log "Installing the 'upgrade' command..."
  mkdir -p "$HOME/.local/bin"
  # Embedded rather than copied from a sibling file — this script is meant
  # to be fetched and run standalone. Keep this in sync with the repo's
  # own top-level `upgrade` file if either changes; they're meant to be
  # identical.
  cat > "$HOME/.local/bin/upgrade" <<'UPGRADE_EOF'
#!/usr/bin/env bash
#
# upgrade — keep a PrivacyOS install current in one command: system
# packages, old kernels, the hosts blocklist, and hardened browser
# preferences. Installed to ~/.local/bin/upgrade by privacyos.sh — meant to
# be run as part of your normal routine, as often as you'd otherwise run
# `apt update && apt upgrade` by hand.
#
# Reads custom.hosts/overrides-user.js from ~/.config/privacyos/ (set up by
# privacyos.sh at install time) — edit those there for your own additions,
# they aren't touched by this script, only read.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PRIVACYOS_CONFIG_DIR="$HOME/.config/privacyos"

log()  { printf '\n\033[1;32m[upgrade]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[upgrade] warning:\033[0m %s\n' "$*" >&2; }
# VMs with NAT-style networking often hand out unroutable IPv6 addresses —
# wget tries those first by default, and "Network is unreachable" on each
# one before falling back to IPv4 adds real delay to every fetch. -4 skips
# straight to IPv4; also bounded rather than wget's own default so a real
# network hiccup fails fast and visibly instead of sitting there looking
# stuck.
fetch() { wget -4 --timeout=15 --tries=2 "$@"; }

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this as your normal user, not root — it calls sudo itself where needed." >&2
  exit 1
fi

sudo -v || { echo "Needs sudo access." >&2; exit 1; }
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

log "Updating and upgrading installed packages..."
sudo apt-get update
sudo apt-get upgrade -y

log "Removing old kernels no longer in use..."
# Wrapped rather than run bare -- with pipefail active, dpkg -l returns
# non-zero if EITHER pattern matches nothing (e.g. no linux-headers-*
# installed) even when the other found real packages, and grep returns
# non-zero too if there's simply nothing left to purge. Either one would
# poison the pipeline's exit status and kill this whole script via set -e
# right after a purge that actually succeeded. Best-effort, not fatal.
old_kernels="$(dpkg -l 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null \
  | awk '/^ii/{print $2}' \
  | grep -v -- "$(uname -r | cut -f1,2 -d'-')" \
  | grep -e '[0-9]')" || true
if [[ -n "$old_kernels" ]]; then
  echo "$old_kernels" | xargs -r sudo apt-get -y purge \
    || warn "Couldn't purge some old kernel packages — not fatal, continuing."
fi

sudo apt-get clean -y
sudo apt-get autoclean -y
sudo apt-get autoremove --purge -y

log "Rebuilding /etc/hosts from StevenBlack + your custom.hosts..."
workdir="$(mktemp -d)"
: > "$workdir/hosts.new"
printf '127.0.0.1 localhost\n127.0.1.1 privacyos\n::1 localhost ip6-localhost ip6-loopback\n\n' >> "$workdir/hosts.new"
custom_hosts="$PRIVACYOS_CONFIG_DIR/custom.hosts"
if [[ -f "$custom_hosts" ]]; then cat "$custom_hosts" >> "$workdir/hosts.new"; fi
if fetch -qO- https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts >> "$workdir/hosts.new" 2>/dev/null; then
  log "  merged StevenBlack/hosts"
else
  warn "  couldn't fetch the StevenBlack list this run — /etc/hosts will only have your custom.hosts entries"
fi
sudo cp "$workdir/hosts.new" /etc/hosts
rm -rf "$workdir"

log "Rebuilding hardened browser preferences (Arkenfox + Betterfox)..."
workdir="$(mktemp -d)"
fetch -qO "$workdir/arkenfox-user.js" https://raw.githubusercontent.com/arkenfox/user.js/master/user.js \
  || warn "couldn't fetch Arkenfox user.js"
fetch -qO "$workdir/betterfox-user.js" https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js \
  || warn "couldn't fetch Betterfox user.js"
overrides="$PRIVACYOS_CONFIG_DIR/overrides-user.js"
cat "$workdir"/arkenfox-user.js "$workdir"/betterfox-user.js "$overrides" \
  > "$workdir/full-user.js" 2>/dev/null || cat "$workdir"/arkenfox-user.js "$workdir"/betterfox-user.js > "$workdir/full-user.js"

# Same split as privacyos.sh's own harden_browsers(): LibreWolf already
# hardens its own defaults, so it gets just the small overrides file, not
# the full Arkenfox/Betterfox stack — keep these two in sync if either
# changes.
#
# Looks for a profile folder named exactly "PrivacyOS" — that's the fixed
# name privacyos.sh's own bootstrap_and_rename_profile() renames every
# profile to at install time, replacing whatever random salt name the
# browser generated for itself. Not a *.default* pattern anymore: our
# renamed profiles don't contain "default" in the name at all.
# || true: find on a path that doesn't exist yet returns non-zero, and
# under pipefail that kills the whole script even though "no profile yet"
# is a normal state to find a browser in.
profile_dir="$(find "$HOME/.librewolf" -maxdepth 1 -name 'PrivacyOS' 2>/dev/null | head -n1)" || true
if [[ -n "$profile_dir" ]]; then cp "$overrides" "$profile_dir/user.js" 2>/dev/null || true; fi

for browser_home in "$HOME/.mozilla/firefox" "$HOME/.waterfox"; do
  profile_dir="$(find "$browser_home" -maxdepth 1 -name 'PrivacyOS' 2>/dev/null | head -n1)" || true
  if [[ -n "$profile_dir" ]]; then cp "$workdir/full-user.js" "$profile_dir/user.js" 2>/dev/null || true; fi
done
rm -rf "$workdir"

log "All done."
UPGRADE_EOF
  chmod +x "$HOME/.local/bin/upgrade"
  # ~/.local/bin is on PATH by default on Debian (added via the standard
  # skel .profile) — if it somehow isn't for this user, `upgrade` still
  # works as ~/.local/bin/upgrade, just not bare by name.
}

install_welcome_message() {
  log "Setting up the first-login welcome message..."
  mkdir -p "$HOME/.local/bin" "$HOME/.config/autostart"

  # A real script file, same pattern as `upgrade` above, rather than
  # cramming this into the .desktop file's Exec= line directly — avoids
  # fighting Desktop Entry Spec quoting/escaping for a multi-paragraph
  # message. Nested heredoc (this script's own zenity call) is the same
  # pattern already used for `upgrade`'s embed above — proven to work.
  cat > "$HOME/.local/bin/privacyos-welcome" <<'WELCOME_SCRIPT_EOF'
#!/usr/bin/env bash
# privacyos-welcome — one-time summary of what privacyos.sh actually
# hardened, shown on first login after the install finishes. Runs via
# XDG autostart (~/.config/autostart/); the marker file below is what
# keeps this to showing exactly once. Delete the marker to see it again.
set -euo pipefail
marker="$HOME/.config/privacyos/.welcome-shown"
if [[ -f "$marker" ]]; then exit 0; fi
command -v zenity >/dev/null 2>&1 || exit 0

zenity --text-info --title="Welcome to PrivacyOS" --width=600 --height=500 <<'MSG_EOF'
Welcome to PrivacyOS

Your system has been hardened. Most of this isn't visible at a glance, so here's a plain summary of what actually changed.

BROWSERS
LibreWolf (your primary browser), Firefox, and Waterfox all got hardened preferences (Arkenfox + Betterfox, or LibreWolf's own strong defaults) plus a curated set of privacy extensions: an ad/tracker blocker, a URL cleaner, Google link-tracking removal, password manager integration, and a few more. Tor Browser is installed for real Tor browsing. Chromium is kept deliberately bare, no extensions - it's there on purpose, but not for everyday use. Every now and then a site just won't work right under a hardened browser - strict tracking protection or an ad blocker gets in its way, job-application sites being a common example. Rather than turning off your hardening to deal with one stubborn site, open Chromium, do that one thing, then close it and go back to your real browser. A one-off tool, not a second daily driver.

DNS AND NETWORK
DNS queries go out encrypted, through Quad9, instead of in the clear through your ISP. RiseupVPN and Tor are both installed and ready whenever you want them.

AD AND TRACKER BLOCKING
/etc/hosts was rebuilt from the StevenBlack blocklist plus anything in your own custom.hosts file.

PASSWORDS AND PACKET CAPTURE
KeePassXC is installed with its browser extension wired in. Wireshark works for your user without needing sudo - that's already set up.

SECURE DELETE
Right-click any file or folder in the Nemo file manager, look for "Scripts" in the menu, then "Secure-Delete" inside it. That overwrites and deletes it for good, not just to the trash.

KEEPING IT CURRENT
Running "sudo apt update && sudo apt upgrade" on its own keeps packages current, but won't refresh your hosts blocklist or browser hardening - those can quietly drift out of date. Instead, just type "upgrade" in a terminal any time. It'll ask for your password, then handle all of it in one pass: the full system upgrade, old kernel cleanup, a rebuilt hosts file, and refreshed browser preferences - everything hardened here, kept current, in one command.

Read privacyos.sh itself any time to see exactly what was done - nothing here is hidden.

(This won't show again. Delete ~/.config/privacyos/.welcome-shown if you ever want to see it once more.)
MSG_EOF

mkdir -p "$(dirname "$marker")"
touch "$marker"
WELCOME_SCRIPT_EOF
  chmod +x "$HOME/.local/bin/privacyos-welcome"

  # $HOME expanded now, into the file, since privacyos.sh already knows
  # the real path — sidesteps any ambiguity about whether Desktop Entry
  # Spec parsing would expand $HOME itself at launch time (it doesn't).
  cat > "$HOME/.config/autostart/privacyos-welcome.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PrivacyOS Welcome
Exec=$HOME/.local/bin/privacyos-welcome
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
}

set_hostname() {
  log "Setting hostname to 'privacyos'..."
  echo privacyos | sudo tee /etc/hostname > /dev/null
  sudo hostnamectl set-hostname privacyos 2>/dev/null || true
}

final_update_and_reboot() {
  log "Final update pass before reboot..."
  apt_update
  apt_upgrade
  apt_cleanup
  log "Done. Rebooting in 10 seconds — Ctrl+C now to cancel and reboot manually later."
  sleep 10
  sudo reboot
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  require_not_root
  require_debian_trixie
  confirm_fresh_install
  ensure_sudo_or_fix_and_exit
  keep_sudo_alive
  install_basic_tools
  ensure_prompt_backend
  resolve_interactive_choices
  init_config_dir

  configure_sources_list
  purge_bloat
  add_repos
  install_core_packages
  configure_dns
  build_hosts_blocklist
  harden_browsers
  configure_extensions
  set_default_browser
  # The most serious instance of this whole bug class: declining theme
  # (the recommended default!) would have silently ended the entire
  # script right here under the old "[[ ]] && fn" form -- never setting
  # the hostname, never doing the final update, never rebooting.
  if [[ "$WANT_THEME" == "yes" ]]; then install_theme_extras; fi
  if [[ "$WANT_APPS"  == "yes" ]]; then install_apps_extras; fi
  install_upgrade_command
  install_welcome_message
  set_hostname
  final_update_and_reboot
}

main "$@"
