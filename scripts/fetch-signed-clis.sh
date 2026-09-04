#!/usr/bin/env bash
#
# Download and install the Developer ID signed Swift CLIs for this version.
#
# Prefer this over building locally, because locally built binaries are
# ad-hoc signed: macOS records their TCC grants as a bare cdhash pin, so every
# rebuild silently revokes the user's Calendar / Reminders / Contacts access
# and the permission dialogs come back. The signed release carries a stable
# identifier + team requirement instead, so a grant given once keeps working
# across every future upgrade.
#
# Fails soft on purpose. No network, no release for this version, an older
# checkout, a corporate proxy -- any of these simply mean "fall back to
# building from source", which is what setup.sh does when this exits non-zero.
# What it must never do is install something it could not verify.
#
# Usage:
#   scripts/fetch-signed-clis.sh <install-dir>
#
# Exit code: 0 = signed binaries installed, 1 = caller should build from source.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=check-signing.sh
. "$SCRIPT_DIR/check-signing.sh"

INSTALL_DIR="${1:-$HOME/.local/bin}"
REPO_SLUG="${APPLE_PIM_RELEASE_REPO:-omarshahine/apple-pim}"

note() { printf '  %s\n' "$1"; }
give_up() { note "$1"; note "Falling back to building from source."; exit 1; }

# The plugin manifest is the canonical version source (scripts/check-versions.sh
# enforces that all five agree, so any of them would do).
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1)"
[[ -n "$VERSION" ]] || give_up "Could not determine the plugin version."

ASSET="apple-pim-clis-${VERSION}-universal.zip"
BASE="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}"

TMP="$(mktemp -d)"
cleanup() { [[ -n "${TMP:-}" && -d "$TMP" ]] && /bin/rm -rf "$TMP"; }
trap cleanup EXIT

note "Looking for signed binaries for v${VERSION}..."
# --proto/--tlsv1.2 keep a redirect from downgrading the transport. -f makes
# a 404 an error rather than a saved HTML error page.
curl_get() {
    curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 120 "$1" -o "$2"
}

curl_get "$BASE/$ASSET" "$TMP/$ASSET" \
    || give_up "No signed release asset for v${VERSION}."

# Checksums are a integrity check against a truncated or corrupted download,
# not a security boundary -- they come from the same host as the asset. The
# signature check below is the real gate.
if curl_get "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"; then
    expected="$(awk -v f="./$ASSET" '$2 == f || $2 == "'"$ASSET"'" {print $1}' "$TMP/SHA256SUMS" | head -1)"
    if [[ -n "$expected" ]]; then
        actual="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || give_up "Checksum mismatch on $ASSET."
        note "Checksum verified."
    fi
fi

mkdir -p "$TMP/extract"
ditto -x -k "$TMP/$ASSET" "$TMP/extract" 2>/dev/null \
    || give_up "Could not extract $ASSET."

# THE gate. Refuses unsigned, ad-hoc, foreign-team, and wrong-identifier
# binaries. Anything that does not pass here is discarded, never installed.
if ! "$SCRIPT_DIR/verify-signed-clis.sh" "$TMP/extract" >"$TMP/verify.log" 2>&1; then
    sed 's/^/  /' "$TMP/verify.log"
    note "Refusing to install binaries that failed verification."
    exit 1
fi
note "Signatures verified (team ${APPLE_PIM_TEAM_ID})."

# One-time migration notice. Replacing ad-hoc binaries changes the recorded
# designated requirement, so macOS asks for permission again. Saying so up
# front is the difference between "the tool is explaining itself" and "the
# permission prompts are back, this thing is broken".
had_adhoc=false
for cli in $APPLE_PIM_SIGNED_CLIS; do
    [[ -e "$INSTALL_DIR/$cli" ]] || continue
    if [[ "$(pim_classify_requirement \
        "$(pim_designated_requirement "$INSTALL_DIR/$cli")" \
        "$(pim_signing_identifier "$cli")")" == "adhoc" ]]; then
        had_adhoc=true
        break
    fi
done

mkdir -p "$INSTALL_DIR"
for cli in $APPLE_PIM_SIGNED_CLIS; do
    /bin/rm -f "$INSTALL_DIR/$cli"
    cp -f "$TMP/extract/$cli" "$INSTALL_DIR/$cli"
    chmod +x "$INSTALL_DIR/$cli"
    note "Installed signed $cli"
done

if [[ "$had_adhoc" == true ]]; then
    echo ""
    note "NOTE: macOS will ask for Calendar, Reminders, and Contacts access once more."
    note "Your previous grants were tied to the unsigned builds' content hash, which"
    note "changed on every rebuild. These binaries are certificate-signed, so this is"
    note "the last time an upgrade will ask."
fi

exit 0
