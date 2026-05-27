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
# Idempotent. Safe to re-run after `setup.sh --install`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/helper"
APP_PATH="${APPLE_PIM_HELPER_APP:-$HOME/Applications/PIMHelper.app}"

if [[ ! -f "$SRC_DIR/Info.plist" || ! -f "$SRC_DIR/pim-helper" ]]; then
    echo "build-helper-app: missing helper sources at $SRC_DIR" >&2
    exit 1
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

# Ad-hoc sign the bundle. --force overwrites any prior signature; --deep
# walks contents (the bundle is shallow but this future-proofs nested files).
codesign --force --deep --sign - "$APP_PATH" >/dev/null

# Register with Launch Services so `open -a` resolves the bundle id.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "Installed PIMHelper.app at: $APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | grep -E '^(Identifier|Format|Signature|Info\.plist|Sealed Resources)' | sed 's/^/  /'
