#!/usr/bin/env bash
#
# Build and install PIMHelper.app.
#
# Why this exists: macOS TCC attributes Calendar / Reminders / Contacts
# permissions to the responsible process (the LaunchServices-launched app),
# not to the binary that calls EventKit / Contacts. When an agent runtime
# spawns the Swift CLIs as children of its own shell, the runtime is the
# responsible process and EventKit returns notDetermined / denied without
# ever surfacing a prompt. Wrapping the CLIs in a tiny ad-hoc-signed .app
# bundle and invoking it through `open -W` makes the .app its own
# responsible process; the macOS prompt then fires against the helper's
# bundle id, and the grant persists across hosts.
#
# Idempotent in the strong sense: if the installed bundle already has the
# same content AND a valid signature, this script leaves it completely
# untouched. That matters because macOS TCC binds permission grants to the
# helper's code signature — re-signing an unchanged bundle silently drops
# every Calendar / Reminders / Contacts grant and forces the user to
# re-answer all the permission dialogs. Pass --force to rebuild anyway.
#
# Signing identity: ad-hoc ("-") by default. Set APPLE_PIM_SIGN_IDENTITY to
# a codesign identity (e.g. "Developer ID Application: ...") to use a stable
# certificate; grants then survive rebuilds on the same identity.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/helper"
APP_PATH="${APPLE_PIM_HELPER_APP:-$HOME/Applications/PIMHelper.app}"
SIGN_IDENTITY="${APPLE_PIM_SIGN_IDENTITY:--}"
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

if [[ ! -f "$SRC_DIR/Info.plist" || ! -f "$SRC_DIR/pim-helper" || ! -f "$SRC_DIR/launcher.c" ]]; then
    echo "build-helper-app: missing helper sources at $SRC_DIR" >&2
    exit 1
fi

# Hash of the launcher source that produced the installed binary. Written into
# the bundle at build time so the freshness check below can tell whether the
# compiled CFBundleExecutable is still current: the source is C and the install
# is a binary, so they cannot be compared with cmp.
LAUNCHER_STAMP_REL="Contents/Resources/.launcher-source-sha256"
launcher_source_hash() { shasum -a 256 "$SRC_DIR/launcher.c" | awk '{print $1}'; }

# True when the installed bundle's signature matches the requested identity.
# Ad-hoc shows as `Signature=adhoc` (no Authority line); a certificate shows
# its identity string as the first `Authority=` line.
installed_identity_matches() {
    local info
    info="$(codesign -dvvv "$APP_PATH" 2>&1)" || return 1
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        grep -q "^Signature=adhoc" <<<"$info"
    else
        [[ "$(awk -F= '/^Authority=/{print $2; exit}' <<<"$info")" == "$SIGN_IDENTITY" ]]
    fi
}

# Skip entirely when the install is already current: identical content and a
# signature that still verifies. This preserves existing TCC grants (macOS
# binds them to the signature). Identity is only enforced when the caller
# explicitly asked for one via APPLE_PIM_SIGN_IDENTITY — with the ad-hoc
# default, an existing valid signature of any kind is left alone rather than
# downgraded (which would drop the grants).
if [[ "$FORCE" != true && -d "$APP_PATH" ]] \
    && cmp -s "$SRC_DIR/Info.plist" "$APP_PATH/Contents/Info.plist" \
    && cmp -s "$SRC_DIR/pim-helper" "$APP_PATH/Contents/Resources/pim-helper.sh" \
    && [[ "$(cat "$APP_PATH/$LAUNCHER_STAMP_REL" 2>/dev/null)" == "$(launcher_source_hash)" ]] \
    && codesign --verify "$APP_PATH" >/dev/null 2>&1 \
    && { [[ -z "${APPLE_PIM_SIGN_IDENTITY:-}" ]] || installed_identity_matches; }; then
    echo "PIMHelper.app is up to date at: $APP_PATH (leaving untouched to preserve TCC grants)"
    exit 0
fi

# Only required once we know a rebuild is actually happening. Checking earlier
# would fail an otherwise-successful no-op install on a host without developer
# tools, which is a regression against the pre-launcher behaviour.
if ! command -v cc >/dev/null 2>&1; then
    echo "build-helper-app: no C compiler found; install Xcode Command Line Tools" >&2
    echo "build-helper-app: (xcode-select --install)" >&2
    exit 1
fi

if [[ -d "$APP_PATH" ]]; then
    echo "warning: replacing PIMHelper.app re-signs it — macOS will drop existing" >&2
    echo "warning: Calendar/Reminders/Contacts grants and re-prompt on next use." >&2
fi

mkdir -p "$(dirname "$APP_PATH")"

# Clean any previous install. Use python unlink to tolerate File Provider
# (OneDrive / iCloud) volumes that reject `trash` and `rm`.
if [[ -e "$APP_PATH" ]]; then
    if command -v trash >/dev/null 2>&1; then
        trash "$APP_PATH" 2>/dev/null || rm -rf "$APP_PATH"
    else
        rm -rf "$APP_PATH"
    fi
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

# The dispatcher script lives in Resources, NOT as CFBundleExecutable: macOS
# refuses to launch an .app whose main executable is a shell script (see
# helper/launcher.c). CFBundleExecutable is a compiled launcher that re-execs
# this script, so the bundle still becomes the TCC-responsible process.
cp "$SRC_DIR/pim-helper" "$APP_PATH/Contents/Resources/pim-helper.sh"
chmod +x "$APP_PATH/Contents/Resources/pim-helper.sh"

# Build for the running architecture. -Os keeps the stub tiny; it does nothing
# but resolve its own path and execv into /bin/zsh.
cc -Os -Wall -Wextra -o "$APP_PATH/Contents/MacOS/pim-helper" "$SRC_DIR/launcher.c"
chmod +x "$APP_PATH/Contents/MacOS/pim-helper"

# Record which launcher source built this binary so the freshness check above
# can detect launcher.c changes on a later run.
launcher_source_hash > "$APP_PATH/$LAUNCHER_STAMP_REL"

# Sign the bundle. --force overwrites any prior signature; --deep walks
# contents (the bundle is shallow but this future-proofs nested files).
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH" >/dev/null

# Register with Launch Services so `open -a` resolves the bundle id.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "Installed PIMHelper.app at: $APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | grep -E '^(Identifier|Format|Signature|Info\.plist|Sealed Resources)' | sed 's/^/  /'
