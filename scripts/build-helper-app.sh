#!/usr/bin/env bash
#
# Build and install the Apple PIM Helper.app TCC bridge.
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
#
# A certificate-signed bundle is never replaced with an ad-hoc one. Doing so
# looks like a routine reinstall and silently costs the user every Calendar /
# Reminders / Contacts grant, because TCC pins an ad-hoc client by content hash
# and the rebuilt bundle is a different client to it. When that is what a run
# would do, the rebuild is SKIPPED with a warning rather than performed, and
# the working, granted bundle is left in place. Pass --allow-adhoc-downgrade
# to override.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/helper"

# APPLE_PIM_HELPER_APP_NAME / _LEGACY_NAME. Sourced rather than duplicated so
# the installer, the doctor, and the release workflow can never disagree about
# what the bundle is called.
# shellcheck source=lib/signing-identities.sh
. "$REPO_ROOT/scripts/lib/signing-identities.sh"

APP_PATH="${APPLE_PIM_HELPER_APP:-$HOME/Applications/$APPLE_PIM_HELPER_APP_NAME}"
SIGN_IDENTITY="${APPLE_PIM_SIGN_IDENTITY:--}"
FORCE=false
ALLOW_DOWNGRADE=false
STAGE_DIR=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

legacy_bundle_path() { printf '%s/%s' "$(dirname "$APP_PATH")" "$APPLE_PIM_HELPER_APP_LEGACY_NAME"; }

# Move a pre-rename bundle to the current name instead of rebuilding it.
#
# The bundle was renamed (PIMHelper.app -> Apple PIM Helper.app) purely so the
# TCC prompt and the Privacy pane read as English: LaunchServices takes that
# label from the bundle's FILENAME and ignores a CFBundleDisplayName that
# disagrees with it. Nothing about the bundle's IDENTITY changes, and a rename
# is the migration that proves it — `mv` leaves the code signature byte-identical
# (same CDHash), and the designated requirement TCC recorded names only the
# identifier, the Apple anchor, and the team OU, never a path. So an existing
# Calendar / Reminders / Contacts grant survives this.
#
# Rebuilding instead would NOT be safe: the new path has no bundle, so the
# freshness check below would miss and sign a fresh one. On the default ad-hoc
# identity that yields a new CDHash and silently drops every grant, and it would
# downgrade a Developer ID install (the shipped one) to ad-hoc in the process.
migrate_legacy_bundle() {
    [[ -z "$STAGE_DIR" ]] || return 0
    local legacy
    legacy="$(legacy_bundle_path)"
    [[ "$legacy" != "$APP_PATH" && -d "$legacy" && ! -e "$APP_PATH" ]] || return 0

    echo "Renaming $APPLE_PIM_HELPER_APP_LEGACY_NAME -> $APPLE_PIM_HELPER_APP_NAME (signature and TCC grants are preserved)"
    mkdir -p "$(dirname "$APP_PATH")"
    mv "$legacy" "$APP_PATH"
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -u "$legacy" >/dev/null 2>&1 || true
        "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
    fi
}

# Classify a bundle's signature: "certificate", "adhoc", or "invalid".
#
# The distinction is the whole reason grants survive an upgrade. A certificate
# signature yields a designated requirement anchored on the identifier and team
# OU, which is stable across rebuilds; an ad-hoc one is pinned to the content
# hash and is therefore a different client to TCC every time.
bundle_signature_class() {
    local info
    codesign --verify "$1" >/dev/null 2>&1 || { echo invalid; return 0; }
    info="$(codesign -dvvv "$1" 2>&1)" || { echo invalid; return 0; }
    if grep -q "^Signature=adhoc" <<<"$info"; then echo adhoc; else echo certificate; fi
}

# Sweep a legacy bundle that outlived the migration — the case where both names
# exist at once, so migrate_legacy_bundle declined to move anything. Launch
# Services and the Privacy pane key their ROW on the bundle on disk, so leaving
# the old one behind shows the user two entries, one of which is dead, and the
# dead one is the name they already recognize.
remove_legacy_bundle() {
    [[ -z "$STAGE_DIR" ]] || return 0
    local legacy
    legacy="$(legacy_bundle_path)"
    [[ "$legacy" != "$APP_PATH" && -d "$legacy" ]] || return 0

    # Both bundles carry the SAME bundle identifier, so TCC has recorded the
    # grant against exactly one of their signatures. Deleting the wrong one is
    # the silent grant loss this whole migration exists to avoid, and the
    # freshness check above cannot catch it: setup.sh leaves
    # APPLE_PIM_SIGN_IDENTITY unset, so a valid ad-hoc survivor is accepted
    # without ever comparing identities. A certificate-signed legacy bundle
    # outranks an ad-hoc survivor — keep it, say why, and let the user choose.
    if [[ "$(bundle_signature_class "$legacy")" == "certificate" \
       && "$(bundle_signature_class "$APP_PATH")" != "certificate" ]]; then
        echo "warning: keeping $APPLE_PIM_HELPER_APP_LEGACY_NAME — it is certificate-signed and" >&2
        echo "warning: $(basename "$APP_PATH") is not, so your Calendar/Reminders/Contacts" >&2
        echo "warning: grants are bound to the OLD bundle. Removing it would drop them." >&2
        echo "warning: Reinstall the helper from the signed release, then delete" >&2
        echo "warning: $legacy by hand. Until you do, both are registered with" >&2
        echo "warning: Launch Services and Privacy & Security lists both." >&2
        return 0
    fi

    echo "Removing superseded $APPLE_PIM_HELPER_APP_LEGACY_NAME at: $legacy"
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -u "$legacy" >/dev/null 2>&1 || true
    fi
    if command -v trash >/dev/null 2>&1; then
        trash "$legacy" 2>/dev/null || rm -rf "$legacy"
    else
        rm -rf "$legacy"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        # Permit replacing a certificate-signed bundle with an ad-hoc one.
        # Off by default because it silently drops every TCC grant; see the
        # downgrade guard below.
        --allow-adhoc-downgrade) ALLOW_DOWNGRADE=true; shift ;;
        # Assemble a release bundle into DIR instead of installing for the
        # current user. Used by the signing workflow. Staging deliberately
        # skips the freshness check, the Launch Services registration, and
        # the "leave it alone to preserve TCC grants" logic: none of those
        # apply to a build artifact on a throwaway runner, and the freshness
        # check would happily no-op a release build.
        --stage)
            STAGE_DIR="$2"
            APP_PATH="$2/$APPLE_PIM_HELPER_APP_NAME"
            FORCE=true
            shift 2
            ;;
        *) echo "build-helper-app: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$SRC_DIR/Info.plist" || ! -f "$SRC_DIR/pim-helper" || ! -f "$SRC_DIR/launcher.c" \
    || ! -f "$SRC_DIR/PIMHelper.entitlements" ]]; then
    echo "build-helper-app: missing helper sources at $SRC_DIR" >&2
    exit 1
fi

# Must run before the freshness check, which is what makes the migration a
# no-op rename rather than a re-sign.
migrate_legacy_bundle

# Hash of the launcher source that produced the installed binary. Written into
# the bundle at build time so the freshness check below can tell whether the
# compiled CFBundleExecutable is still current: the source is C and the install
# is a binary, so they cannot be compared with cmp.
LAUNCHER_STAMP_REL="Contents/Resources/.launcher-source-sha256"
launcher_source_hash() { shasum -a 256 "$SRC_DIR/launcher.c" | awk '{print $1}'; }

# Same problem for the entitlements: they are baked into the signature, not
# copied into the bundle, so nothing in the installed tree reflects a change to
# them. Without this stamp an entitlements edit would be silently skipped by the
# freshness check on every machine that already has a bundle installed.
ENTITLEMENTS_STAMP_REL="Contents/Resources/.entitlements-source-sha256"
entitlements_source_hash() { shasum -a 256 "$SRC_DIR/PIMHelper.entitlements" | awk '{print $1}'; }

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
    && [[ "$(cat "$APP_PATH/$ENTITLEMENTS_STAMP_REL" 2>/dev/null)" == "$(entitlements_source_hash)" ]] \
    && [[ "$(cat "$APP_PATH/$LAUNCHER_STAMP_REL" 2>/dev/null)" == "$(launcher_source_hash)" ]] \
    && codesign --verify "$APP_PATH" >/dev/null 2>&1 \
    && { [[ -z "${APPLE_PIM_SIGN_IDENTITY:-}" ]] || installed_identity_matches; }; then
    echo "$(basename "$APP_PATH") is up to date at: $APP_PATH (leaving untouched to preserve TCC grants)"
    remove_legacy_bundle
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

# Refuse to trade a certificate signature for an ad-hoc one. This is the
# rebuild-path counterpart to the freshness check above, which already declines
# to downgrade an up-to-date bundle; without it, a bundle that is merely STALE
# gets re-signed ad-hoc on the next `./setup.sh --install` and every grant
# silently disappears. Skipping (rather than failing) keeps setup.sh running
# and leaves the user with the bundle that still works and is still granted.
if [[ -z "$STAGE_DIR" && -d "$APP_PATH" && "$SIGN_IDENTITY" == "-" \
   && "$ALLOW_DOWNGRADE" != true \
   && "$(bundle_signature_class "$APP_PATH")" == "certificate" ]]; then
    # Capture first, then awk over a herestring. Piping codesign into an awk
    # that `exit`s on the first match gives the writer SIGPIPE, and under
    # `set -euo pipefail` that aborts the whole script (rc 141).
    signing_info="$(codesign -dvvv "$APP_PATH" 2>&1)"
    identity="$(awk -F= '/^Authority=/{print $2; exit}' <<<"$signing_info")"
    echo "warning: $(basename "$APP_PATH") is signed by \"$identity\" and is out of date," >&2
    echo "warning: but no signing identity is available here, so rebuilding it would" >&2
    echo "warning: re-sign it ad-hoc and drop your Calendar/Reminders/Contacts grants." >&2
    echo "warning: Leaving the installed bundle alone — it still works." >&2
    echo "warning:" >&2
    echo "warning: To update it without losing the grants, install the signed helper" >&2
    echo "warning: from the release (apple-pim-helper-<version>.zip), or re-run with" >&2
    echo "warning: APPLE_PIM_SIGN_IDENTITY set to the same certificate." >&2
    echo "warning: Pass --allow-adhoc-downgrade to rebuild anyway and re-grant by hand." >&2
    remove_legacy_bundle
    exit 0
fi

if [[ -d "$APP_PATH" ]]; then
    echo "warning: replacing $(basename "$APP_PATH") re-signs it — macOS will drop existing" >&2
    echo "warning: Calendar/Reminders/Contacts grants and re-prompt on next use." >&2
fi

mkdir -p "$(dirname "$APP_PATH")"

# Clean any previous install. Use python unlink to tolerate File Provider
# (OneDrive / iCloud) volumes that reject `trash` and `rm`.
remove_app_path() {
    [[ -e "$APP_PATH" ]] || return 0
    if command -v trash >/dev/null 2>&1; then
        trash "$APP_PATH" 2>/dev/null || rm -rf "$APP_PATH"
    else
        rm -rf "$APP_PATH"
    fi
}

remove_app_path

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

# The dispatcher script lives in Resources, NOT as CFBundleExecutable: macOS
# refuses to launch an .app whose main executable is a shell script (see
# helper/launcher.c). CFBundleExecutable is a compiled launcher that re-execs
# this script, so the bundle still becomes the TCC-responsible process.
cp "$SRC_DIR/pim-helper" "$APP_PATH/Contents/Resources/pim-helper.sh"
chmod +x "$APP_PATH/Contents/Resources/pim-helper.sh"

# Local installs build for the running architecture only. A staged release
# bundle must be universal: it is downloaded by machines we do not control,
# and the package's deployment target (macOS 13) still includes Intel.
# -Os keeps the stub tiny; it does nothing but resolve its own path and
# execv into /bin/zsh.
if [[ -n "$STAGE_DIR" ]]; then
    cc -Os -Wall -Wextra -arch arm64 -arch x86_64 \
        -o "$APP_PATH/Contents/MacOS/pim-helper" "$SRC_DIR/launcher.c"
else
    cc -Os -Wall -Wextra -o "$APP_PATH/Contents/MacOS/pim-helper" "$SRC_DIR/launcher.c"
fi
chmod +x "$APP_PATH/Contents/MacOS/pim-helper"

# Record which launcher source built this binary so the freshness check above
# can detect launcher.c changes on a later run.
launcher_source_hash > "$APP_PATH/$LAUNCHER_STAMP_REL"
entitlements_source_hash > "$APP_PATH/$ENTITLEMENTS_STAMP_REL"

# Sign the bundle. --force overwrites any prior signature; --deep walks
# contents (the bundle is shallow but this future-proofs nested files).
#
# When signing with a real certificate, the hardened runtime and a secure
# timestamp are added: both are hard prerequisites for Developer ID
# notarization, and without them `notarytool submit` rejects the bundle and
# the whole release fails. They are deliberately NOT applied to the ad-hoc
# path, which is never notarized and where a timestamp server round-trip
# would just make a local install slower and network-dependent.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_PATH" >/dev/null
else
    # --entitlements is not optional here. Notarization requires the hardened
    # runtime, and a hardened-runtime bundle without the matching entitlement is
    # denied protected resources with no consent dialog at all -- the user is
    # left with nothing to grant. v3.17.0 shipped exactly that for Contacts
    # (issue #159); codesign --verify, spctl and notarization all pass on the
    # broken bundle, so nothing upstream catches it.
    codesign --force --deep --timestamp --options runtime \
        --entitlements "$SRC_DIR/PIMHelper.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP_PATH" >/dev/null

    # Assert rather than trust: the failure this guards against is invisible to
    # every other check in the pipeline, and only shows up as a user unable to
    # grant Contacts weeks later.
    #
    # A rejected bundle must never be left at $APP_PATH. The working helper was
    # already removed and the source stamps already written, so an installed
    # reject would satisfy the freshness check on the next run and be treated as
    # current forever -- a permanently broken helper that no rebuild repairs.
    # Removing it costs the user one rebuild; leaving it costs them Contacts.
    reject_bundle() {
        echo "build-helper-app: $1" >&2
        echo "build-helper-app: TCC would deny that resource with no prompt; refusing to ship" >&2
        remove_app_path
        echo "build-helper-app: removed the rejected bundle at $APP_PATH; re-run after fixing" >&2
        exit 1
    }

    if codesign -dvvv "$APP_PATH" 2>&1 | grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime'; then
        signed_entitlements="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)"
        for required in \
            com.apple.security.personal-information.addressbook \
            com.apple.security.personal-information.calendars \
            com.apple.security.automation.apple-events; do
            # Presence is not enough: a key present with <false/> reads as
            # declared while granting nothing, so require the boolean value.
            #
            # plutil -extract is not usable here: it treats "." as a key-path
            # separator, and every entitlement key is dotted, so it reports
            # "No value at that key path" for all of them and would reject
            # every valid bundle.
            value="$(printf '%s' "$signed_entitlements" | python3 -c '
import plistlib, sys
key = sys.argv[1]
try:
    declared = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
value = declared.get(key)
if value is None:
    sys.exit(0)
print("true" if value is True else str(value))
' "$required" 2>/dev/null || true)"
            [[ -n "$value" ]] || reject_bundle "hardened runtime is set but $required is missing"
            [[ "$value" == "true" ]] || reject_bundle "$required is present but set to '$value', not true"
        done
    fi
fi

# Register with Launch Services so `open -a` resolves the bundle id. Skipped
# when staging: a release artifact must not be registered on the build runner,
# and registration is the installing machine's job.
if [[ -z "$STAGE_DIR" && -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
fi

remove_legacy_bundle

echo "Installed $(basename "$APP_PATH") at: $APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | grep -E '^(Identifier|Format|Signature|Info\.plist|Sealed Resources)' | sed 's/^/  /'
