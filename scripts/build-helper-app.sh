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

if [[ ! -f "$SRC_DIR/Info.plist" || ! -f "$SRC_DIR/pim-helper" ]]; then
    echo "build-helper-app: missing helper sources at $SRC_DIR" >&2
    exit 1
fi

# Skip entirely when the install is already current: identical content and
# a signature that still verifies. This preserves existing TCC grants.
if [[ "$FORCE" != true && -d "$APP_PATH" ]] \
    && cmp -s "$SRC_DIR/Info.plist" "$APP_PATH/Contents/Info.plist" \
    && cmp -s "$SRC_DIR/pim-helper" "$APP_PATH/Contents/MacOS/pim-helper" \
    && codesign --verify "$APP_PATH" >/dev/null 2>&1; then
    echo "PIMHelper.app is up to date at: $APP_PATH (leaving untouched to preserve TCC grants)"
    exit 0
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

mkdir -p "$APP_PATH/Contents/MacOS"
cp "$SRC_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$SRC_DIR/pim-helper" "$APP_PATH/Contents/MacOS/pim-helper"
chmod +x "$APP_PATH/Contents/MacOS/pim-helper"

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
