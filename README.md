# PrivacyOS

> **🚧 Work in progress — currently in testing.** Nothing here has been run
> end-to-end on real hardware yet, so treat it as a preview: you're welcome
> to try it and see how it goes, but expect rough edges until that testing
> is done. Aiming to have this fully ready **by September 20, 2026**.

A single script that turns a fresh Debian 13 (Trixie) install into a hardened,
privacy-first desktop — get networking working, run the script, done.

Everything it installs comes through `apt`: Debian's own repositories, or a
vendor repository added the same way LibreWolf's/Waterfox's/Mozilla's/
VSCodium's are. Nothing here is a one-off `.deb` download, a tarball, an
AppImage, or a Flatpak — one update mechanism (`apt update && apt upgrade`)
covers everything, and nothing sits around unmanaged outside the package
manager's tracking.

Read the script before you run it. That's the point — there's nothing here
you can't see for yourself.

## Why Debian, not Ubuntu or Linux Mint

Both are themselves built on Debian — Ubuntu is a Debian derivative, and Mint is
built on top of *Ubuntu*, so it's two layers removed from Debian itself. This
project builds directly on Debian instead, deliberately, for reasons that matter
specifically for a hardening project rather than being a knock on either:

- Fewer layers between an upstream security fix and your machine — packages come
  from Debian's own archive or a vendor's own repo, not a derivative's repackaging
  of one.
- Debian doesn't carry Ubuntu's Snap-by-default packaging or its history of
  bundling things like commercial search integration — starting from the plainer,
  more scrutinized base means less to audit and undo before any hardening even
  starts.
- It matches this project's own APT-only rule: everything stays one hop from
  upstream, not two.

## Requirements

- A fresh install of **Debian 13 (Trixie)** with the **Cinnamon** desktop
  already installed. This is a real requirement, not a suggestion — the
  Nemo file-manager integration and the bloat-purge list are both written
  specifically for what a Cinnamon install includes. Other desktops aren't
  supported.
- Easiest way to get there: Debian publishes an official **live image with
  Cinnamon already on it**, installed via Calamares (the same graphical
  installer Linux Mint itself uses) — boot it, connect to Wi-Fi through its
  normal desktop applet if you need to, install to disk from there. No
  separate desktop-selection step, no `apt install` afterward.
- This project is currently verified against **Debian 13.6.0**, released
  2026-07-11.
  - Cinnamon live image:
    [debian-live-13.6.0-amd64-cinnamon.iso](https://cdimage.debian.org/debian-cd/13.6.0-live/amd64/iso-hybrid/debian-live-13.6.0-amd64-cinnamon.iso) (~3.8 GB) —
    links straight to the file itself, not the folder, so there's no risk of
    grabbing the GNOME/KDE/XFCE/etc. image by mistake. Debian also publishes
    a [.torrent](https://cdimage.debian.org/debian-cd/13.6.0-live/amd64/bt-hybrid/debian-live-13.6.0-amd64-cinnamon.iso.torrent)
    for it — often faster than downloading straight from Debian's own
    server, since you're pulling pieces from everyone else currently
    sharing the file at the same time instead of one single source. Any
    torrent client (Deluge, qBittorrent, Transmission, etc.) opens it
    directly.
  - Prefer a minimal/manual install instead? The plain
    [debian-13.6.0-amd64-netinst.iso](https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso) (~755 MB,
    [.torrent](https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/debian-13.6.0-amd64-netinst.iso.torrent))
    works too — just make sure to select Cinnamon in the installer's software
    selection screen (or run `sudo apt install task-cinnamon-desktop`
    afterward if you didn't). Unlike the Cinnamon live link above, both of
    these are on Debian's "current" path, so they'll silently serve whatever
    point release is newest by the time you click them, not necessarily
    13.6.0.
  - Checksums: `SHA256SUMS`/`SHA512SUMS` (+ `.sign` files) sit in the same
    directory as whichever image you pick — verify before you install.
  - Newer Debian point releases should work fine — this project is pinned to
    the `trixie` codename, not a specific point release, and it runs
    `apt update && apt upgrade` as its first real step regardless of which
    point release you installed from.

## Encrypt the disk

Do this during Debian's own installer, before `privacyos.sh` ever enters the
picture — it's the one piece of real protection that has to happen at
install time, not something the script can add afterward.

**Full-disk encryption protects everything** — not just your personal
files, but the operating system itself: browser caches, swap, temp files,
system logs, all of it. Without it, someone with physical access to a
powered-off machine (lost, stolen, seized, whatever) can just pull the
drive and read everything on it directly. With it, none of that is
readable without the passphrase, full stop.

- **Using the Cinnamon live image** (the recommended path above, installed
  via Calamares): when you get to partitioning, choose **Erase disk**, then
  enable the **Encrypt system** option before continuing. LVM gets set up
  underneath automatically as part of that same flow — nothing else to
  configure.
- **Using the netinst image** (the classic Debian installer): on the
  **Partition disks** screen, choose **Guided – use entire disk and set up
  encrypted LVM**.

Either way, you'll be asked to set an encryption passphrase during this
step. **Write it down somewhere safe before you forget it** — this isn't a
login password, it's what makes the entire disk readable at all, asked for
on every single boot before the system even starts. There is no recovery
option and no "forgot password" flow. Lose the passphrase and everything on
the disk is gone, permanently, by design — that's the same property that
makes it real protection in the first place.

## Quick start

Nothing about what's actually installed on a fresh system can be assumed
here — not `git`, not `wget`, not `curl`, and not even that your user has
`sudo` access yet (depends on a choice made during Debian's own installer).
The only thing guaranteed to be there is a **browser** — it's part of the
live image itself — so that's the one manual step:

1. Open the browser, go to
   [install.sh](https://raw.githubusercontent.com/rjc3rd/PrivacyOS/main/install.sh),
   save it (`Ctrl+S` or right-click → Save Page As) to your Downloads
   folder.
2. Open a terminal:
   ```sh
   cd ~/Downloads
   chmod +x install.sh
   ./install.sh
   ```

That one file handles everything else in order: checks whether your user
has `sudo` yet and walks you through fixing it if not (safe either way —
see [install.sh](install.sh) itself for exactly what it does and why),
updates the system, installs `git`, pulls down this repo, and hands off to
`privacyos.sh` automatically. If it tells you to log out and back in first
(the sudo-fix case), do that, then just run `./install.sh` again from the
same `~/Downloads` folder — it picks up right where it left off.

Prefer to do each step yourself instead of running a script you haven't
read line by line first? Totally reasonable, and the point of this project
is that you can — `install.sh` is short and plain, read it, then either run
it as-is or do its steps by hand.

Once you're inside the cloned repo, run it as your normal user, not
root — it calls `sudo` itself wherever it needs to.

Every optional choice is a command-line flag, so you can pre-decide exactly
what you want (and script/document it, or eventually generate the command
from a checkbox picker on `privacyos.dev`) instead of answering prompts.
Anything you don't pass a flag for gets asked interactively — as a graphical
dialog if available, a plain terminal prompt otherwise. `install.sh` passes
any flags straight through to `privacyos.sh`, so `./install.sh --theme
--dns=quad9` works the same as running that on `privacyos.sh` directly once
you're inside the cloned repo.

```
--dns=PROVIDER      quad9 (default) | nextdns | opendns | none
--theme / --no-theme          desktop theming extras (asks if omitted)
--apps  / --no-apps            creative/media/dev app bundle (asks if omitted)
--no-librewolf                 skip LibreWolf     (included by default)
--no-firefox                   skip Firefox        (included by default)
--no-tor                       skip Tor Browser    (included by default)
--no-waterfox                  skip Waterfox       (included by default)
--no-chromium                   skip Chromium (the no-extensions fallback browser)
--yes                           non-interactive: accept defaults for anything
                                 not given an explicit flag (theme=no, apps=no)
-h, --help                      show help and exit
```

## What the core install does

- Points `/etc/apt/sources.list` at Debian 13/Trixie explicitly (not the
  generic `stable` alias, so this keeps targeting Trixie even after the next
  Debian release ships).
- Removes a set of default desktop apps this project doesn't need.
- Installs core privacy/security tooling: `secure-delete`, `wipe`,
  `bleachbit`, `riseup-vpn`, `tor`, `keepassxc`, `wireshark` (plus a
  right-click "Secure Delete" action in the Nemo file manager). `tor` is the
  standalone background proxy daemon (distinct from Tor Browser, installed
  separately below) — it just runs, quietly, always available on
  `127.0.0.1:9050` for anything that wants to use it.
- Installs a privacy-focused browser set — LibreWolf (primary), Firefox
  (fallback), Tor Browser, Waterfox — plus a deliberately bare,
  no-extensions Chromium kept entirely separate. Chromium isn't just a
  compatibility fallback for sites a hardened browser breaks; it's
  deliberate browser isolation — for sites you have to use but don't trust
  (job sites, Microsoft properties, etc.), using a completely separate,
  unlinked browser means whatever they collect there can't be correlated
  with anything in your real, hardened browsing identity. Each browser is
  individually skippable via flag.
- Installs Thunderbird for mail.
- Configures an encrypted DNS resolver (Quad9 by default) via
  `systemd-resolved`.
- Builds `/etc/hosts` from the [StevenBlack](https://github.com/StevenBlack/hosts)
  list plus your own [custom.hosts](custom.hosts) (see below).
- Builds hardened browser preferences from
  [Arkenfox](https://github.com/arkenfox/user.js) +
  [Betterfox](https://github.com/yokoffing/Betterfox) plus this project's own
  small `overrides-user.js`, applied to Firefox/Waterfox. LibreWolf gets just
  the overrides file, since it already hardens its own defaults — layering
  the full Arkenfox/Betterfox set on top would fight settings it made on
  purpose.
- Force-installs a standard extension set into Firefox, Waterfox, *and*
  LibreWolf via `policies.json` (Mozilla's own enterprise mechanism for
  this) — each extension with its own out-of-the-box defaults, no custom
  rules or filters layered in:
  [uBlock Origin](https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/) (Firefox and LibreWolf only — see notes below),
  [ClearURLs](https://addons.mozilla.org/en-US/firefox/addon/clearurls/),
  [Don't track me Google](https://addons.mozilla.org/en-US/firefox/addon/dont-track-me-google1/),
  [KeePassXC-Browser](https://addons.mozilla.org/en-US/firefox/addon/keepassxc-browser/),
  [LocalCDN](https://addons.mozilla.org/en-US/firefox/addon/localcdn-fork-of-decentraleyes/),
  [Onion Browser Button](https://addons.mozilla.org/en-US/firefox/addon/tortm-browser-button/) (see note below),
  [Port Authority](https://addons.mozilla.org/en-US/firefox/addon/port-authority/),
  [SponsorBlock for YouTube](https://addons.mozilla.org/en-US/firefox/addon/sponsorblock/).
- Sets the hostname to `privacyos`.
- Finishes with `apt update && apt upgrade` and a reboot.

## Optional extras

Neither of these is "hardening" — they're kept separate so installing them
isn't forced on anyone who just wants the core setup.

- `--theme`: Cinnamon config, Mint-Y-Dark theme, icons, wallpapers. **Not yet
  built** — tracked for a future update.
- `--apps`: GIMP, Inkscape, darktable, RawTherapee, Scribus, Flowblade,
  Audacity, Audacious, mpv, Celluloid, Deluge, SimpleScreenRecorder,
  VSCodium, Terminator, mintstick, dconf-editor, gnome-clocks.

## Ad/tracker blocking

`/etc/hosts` is built from exactly one list —
[StevenBlack/hosts](https://github.com/StevenBlack/hosts) — plus
[`custom.hosts`](custom.hosts), a plain local file in this repo for your own
additions. This project used to stack several different lists from several
maintainers; real, repeated experience was that it caused more site breakage
(an overzealous or stale entry in one of them blackholing a domain some site
actually needed) than it was worth. StevenBlack alone is well-maintained and
strikes a better balance — one source is also just one thing that can go
stale or move.

`custom.hosts` is merged in **before** StevenBlack's list, which matters if
you ever want to override an entry: for a given hostname, the first matching
line in `/etc/hosts` wins, so anything you put in `custom.hosts` takes
priority over the downloaded list — useful both for adding your own blocks
and for un-blocking something StevenBlack catches that you actually need.

## Extension notes

- **uBlock Origin is excluded from Waterfox on purpose.** Waterfox has its
  own native ad-blocking engine built in (Brave's open-source adblock
  engine, using uBlock Origin's own filter lists — EasyList, EasyPrivacy,
  and more), running in the browser process rather than as an extension.
  Installing the actual extension on top would just be redundant with what's
  already running.
- **LibreWolf gets a merge, not a fresh file.** Firefox-family browsers use
  exactly one `policies.json` — picked by priority, never merged with any
  other — and LibreWolf ships its own, which does a lot more than
  extensions (disables telemetry/studies, forces HTTPS-Only, blocks local-
  network tracking, strips sponsored content, and more). Overwriting it
  blindly would have silently undone all of that. Instead, LibreWolf's real
  current defaults (pulled from
  [their own settings repo](https://codeberg.org/librewolf/settings)) are
  reproduced here with this project's extensions added into the existing
  list — nothing else touched. If LibreWolf changes their own defaults later
  this copy won't automatically follow, so it's worth re-diffing against
  their repo occasionally rather than trusting it as a one-time copy.
  LibreWolf already installs uBlock Origin itself (removable, not
  locked) — left exactly as-is, not force-installed or duplicated.
- **Privacy Possum was considered and deliberately left out** — its last
  release was 2019. Not something to include in a privacy-hardening tool
  without active maintenance behind it.
- **Onion Browser Button is not affiliated with the Tor Project** — it's an
  independently-developed convenience extension, unrelated to Tor Browser
  itself (which this project already installs separately, properly
  isolated). Its actual purpose here: this project also installs the `tor`
  package itself, which runs a local Tor SOCKS proxy in the background all
  the time — this extension is a one-click way to route regular browser
  traffic through that already-running local proxy for something quick,
  without launching the full, heavier, more isolated Tor Browser every time.
  Checked its actual source rather than just trusting the listing (it's
  open source: [github.com/jeremy-jr-benthum/onion-browser-button](https://github.com/jeremy-jr-benthum/onion-browser-button)):
  permissions are minimal (`proxy`, `storage`, `notifications` — nothing
  broader), toggling it on points Firefox's proxy settings at
  `127.0.0.1:9050` (the standard local Tor SOCKS port — not some third
  party's server) and verifies the connection against Tor Project's own
  official `check.torproject.org`, exactly matching what it claims to do.
  The one thing worth knowing: on install/update it opens a changelog tab
  on the developer's own site with the version number in the URL (visible,
  low-sensitivity — you'd see the tab open, it's not hidden) — and that tab
  doesn't open when it detects an automated testing environment. Common,
  usually-benign pattern for not spamming testers with tabs, but also the
  kind of "behaves differently under review" detail worth knowing about
  rather than glossing over. Nothing else in the code goes beyond its
  stated purpose — **this was independently verified for this project by
  reading the extension's actual shipped source, not just its store
  listing**, so it's included here on that basis, not blind trust.
  If you'd still rather not run a third-party extension for this at all,
  the extension isn't doing anything you can't do yourself by hand: in any
  Firefox-based browser, Settings → Network Settings → Manual proxy
  configuration → SOCKS Host `127.0.0.1`, Port `9050`, SOCKS v5 — that's
  the entire mechanism, one click or typed in by hand.

## DNS resolver options

- **Quad9** (default) — free, unlimited, no account, run by the nonprofit
  Quad9 Foundation. Configured via DNS-over-TLS.
- **OpenDNS** — configured as plain DNS only; its DNS-over-TLS support isn't
  well established enough to enable encryption automatically here.
- **NextDNS** — uses a personal per-account config ID rather than a shared
  address, so it can't be wired in generically. The script prints a pointer
  to [my.nextdns.io](https://my.nextdns.io) instead of guessing.
- **none** — leaves DNS at whatever the network provides.

(Mullvad's public DNS service was considered but is being shut down by
Mullvad itself, with users migrated to Quad9 — not included here for that
reason.)

## Staying up to date

Installing drops an `upgrade` command into `~/.local/bin/` (already on your
`PATH`) — run it whenever you'd otherwise run `apt update && apt upgrade` by
hand. It asks for your sudo password once, then: upgrades all packages,
removes old kernels that pile up along the way, cleans up, rebuilds
`/etc/hosts` from a fresh StevenBlack list plus your `custom.hosts`, and
rebuilds Firefox/Waterfox/LibreWolf's hardened preferences from a fresh
Arkenfox + Betterfox. One command, meant to become part of your normal
routine rather than something you reach for occasionally.

Your own additions — `custom.hosts` and `overrides-user.js` — live in
`~/.config/privacyos/` once installed, not in the cloned repo folder, so
`upgrade` still works even if you delete that folder afterward. Edit them
there; `upgrade` only ever reads them, never overwrites them.

## Roadmap

1. This script. ✅ (first draft — needs real-hardware testing; see below)
2. A Debian **preseed file** that fully automates the official Debian
   installer and runs this script automatically as its last step, so
   installing PrivacyOS is closer to one step instead of two. Planned next,
   not yet built.
3. A small companion site at `privacyos.dev` pointing here.

A full custom pre-built ISO was considered and set aside for now — a frozen
image goes stale in a way this script doesn't (it always installs current
packages at run time), and the preseed approach above gets most of the
same benefit without that trade-off.

## Status

First draft, not yet run end-to-end on real hardware. This script is written
and maintained here; actually *running* it — real `apt install`/`remove`,
editing `/etc/hosts`, live network changes — needs to happen on hardware or a
VM, by a human, since that's not something safe to automate blindly. Expect
rough edges, especially around the DNS/NetworkManager interaction, until
that's happened at least once.

## License

MIT — see [LICENSE](LICENSE).
