#!/usr/bin/env bash
#
# privacyos.sh — turn a fresh Debian 13 (Trixie) install into PrivacyOS:
# a hardened, privacy-first desktop. https://github.com/rjc3rd/PrivacyOS
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
#   - Must be run as a normal user with sudo rights, NOT as root. Sudo is
#     used internally per-command, matching how you'd run any other
#     install script.
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
  [[ "${EUID}" -eq 0 ]] && die "Run this as your normal user, not root — it calls sudo itself where needed."
}

require_debian_trixie() {
  local id="" codename=""
  [[ -r /etc/os-release ]] && { . /etc/os-release; id="${ID:-}"; codename="${VERSION_CODENAME:-}"; }
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
  dpkg -l 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' \
    | grep -v -- "$(uname -r | cut -f1,2 -d'-')" | grep -e '[0-9]' \
    | xargs -r sudo apt-get -y purge
}
apt_cleanup() { purge_old_kernels; sudo apt-get clean -y; sudo apt-get autoclean -y; sudo apt-get autoremove --purge -y; }

# ============================================================
# Sections
# ============================================================

configure_sources_list() {
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
    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
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
    wget -qO- https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
      | gpg --dearmor | sudo tee /etc/apt/keyrings/vscodium.gpg > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/vscodium.gpg] https://download.vscodium.com/debs vscodium main" \
      | sudo tee /etc/apt/sources.list.d/vscodium.list > /dev/null
  fi

  apt_update
}

install_core_packages() {
  log "Installing core privacy/security tooling..."
  apt_install secure-delete wipe bleachbit riseup-vpn tor keepassxc wireshark
  sudo usermod -a -G wireshark "$USER"

  mkdir -p "$HOME/.local/share/nemo/scripts"
  printf '#!/bin/sh\nsrm -llrv "$@"\n' > "$HOME/.local/share/nemo/scripts/Secure-Delete"
  chmod +x "$HOME/.local/share/nemo/scripts/Secure-Delete"

  log "Installing browsers..."
  local browsers=()
  [[ "$WANT_LIBREWOLF" == "yes" ]] && browsers+=(librewolf)
  [[ "$WANT_FIREFOX"   == "yes" ]] && browsers+=(firefox)
  [[ "$WANT_TOR"       == "yes" ]] && browsers+=(torbrowser-launcher)
  [[ "$WANT_WATERFOX"  == "yes" ]] && browsers+=(waterfox)
  [[ "$WANT_CHROMIUM"  == "yes" ]] && browsers+=(chromium)
  ((${#browsers[@]})) && apt_install "${browsers[@]}"
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

  sudo systemctl restart systemd-resolved
  sudo systemctl restart NetworkManager 2>/dev/null || true
  warn "DNS config is a first pass — verify 'resolvectl status' shows it after reboot; network-manager interactions can vary by hardware."
}

init_config_dir() {
  mkdir -p "$PRIVACYOS_CONFIG_DIR"
  local repo_dir
  repo_dir="$(dirname "$0")"
  # Copy in the bundled defaults only if they're not already there — a
  # second run (or `upgrade` later) must never clobber edits made here.
  [[ -f "$PRIVACYOS_CONFIG_DIR/custom.hosts" ]] || cp "$repo_dir/custom.hosts" "$PRIVACYOS_CONFIG_DIR/custom.hosts" 2>/dev/null || true
  [[ -f "$PRIVACYOS_CONFIG_DIR/overrides-user.js" ]] || cp "$repo_dir/overrides-user.js" "$PRIVACYOS_CONFIG_DIR/overrides-user.js" 2>/dev/null || true
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
  [[ -f "$custom_hosts" ]] && cat "$custom_hosts" >> "$workdir/hosts.new"

  if wget -qO- https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts >> "$workdir/hosts.new" 2>/dev/null; then
    log "  merged StevenBlack/hosts"
  else
    warn "  couldn't fetch the StevenBlack list this run — /etc/hosts will only have your custom.hosts entries"
  fi

  sudo cp "$workdir/hosts.new" /etc/hosts
  rm -rf "$workdir"
}

harden_browsers() {
  log "Building hardened browser preferences (Arkenfox + Betterfox)..."
  local workdir
  workdir="$(mktemp -d)"
  wget -qO "$workdir/arkenfox-user.js" https://raw.githubusercontent.com/arkenfox/user.js/master/user.js \
    || warn "couldn't fetch Arkenfox user.js"
  wget -qO "$workdir/betterfox-user.js" https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js \
    || warn "couldn't fetch Betterfox user.js"
  local overrides="$PRIVACYOS_CONFIG_DIR/overrides-user.js"
  cat "$workdir"/arkenfox-user.js "$workdir"/betterfox-user.js "$overrides" \
    > "$workdir/full-user.js" 2>/dev/null || cat "$workdir"/arkenfox-user.js "$workdir"/betterfox-user.js > "$workdir/full-user.js"

  # LibreWolf already hardens its own defaults heavily — layering the full
  # Arkenfox/Betterfox set on top risks fighting settings it already made
  # deliberately. Give it just the project's own small overrides instead.
  if [[ "$WANT_LIBREWOLF" == "yes" ]]; then
    local profile_dir
    profile_dir="$(find "$HOME/.librewolf" -maxdepth 1 -name '*.default*' 2>/dev/null | head -n1)"
    [[ -n "$profile_dir" ]] && cp "$overrides" "$profile_dir/user.js" 2>/dev/null || true
  fi
  for browser_home in "$HOME/.mozilla/firefox" "$HOME/.waterfox"; do
    local profile_dir
    profile_dir="$(find "$browser_home" -maxdepth 1 -name '*.default*' 2>/dev/null | head -n1)"
    [[ -n "$profile_dir" ]] && cp "$workdir/full-user.js" "$profile_dir/user.js" 2>/dev/null || true
  done
  rm -rf "$workdir"
  warn "Browser profile folders only exist after each browser's been launched once — if a user.js didn't get copied above, launch that browser once and re-run this step."
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
}

install_theme_extras() {
  log "Desktop theming: not bundled in this script yet — see extras/theme/ in the repo."
  # Intentionally separate from core, per the project's own decision: someone
  # who just wants the hardening shouldn't be forced into these opinions.
}

install_apps_extras() {
  log "Installing the creative/media/dev app bundle..."
  apt_install gimp inkscape darktable rawtherapee scribus flowblade audacity \
    audacious mpv celluloid deluge simplescreenrecorder codium terminator \
    mintstick dconf-editor gnome-clocks
}

install_upgrade_command() {
  log "Installing the 'upgrade' command..."
  mkdir -p "$HOME/.local/bin"
  cp "$(dirname "$0")/upgrade" "$HOME/.local/bin/upgrade"
  chmod +x "$HOME/.local/bin/upgrade"
  # ~/.local/bin is on PATH by default on Debian (added via the standard
  # skel .profile) — if it somehow isn't for this user, `upgrade` still
  # works as ~/.local/bin/upgrade, just not bare by name.
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
  keep_sudo_alive
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
  [[ "$WANT_THEME" == "yes" ]] && install_theme_extras
  [[ "$WANT_APPS"  == "yes" ]] && install_apps_extras
  install_upgrade_command
  set_hostname
  final_update_and_reboot
}

main "$@"
