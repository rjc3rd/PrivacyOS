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
