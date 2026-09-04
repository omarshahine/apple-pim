#!/usr/bin/env bash
#
# Classify the code signature of the installed Apple PIM binaries.
#
# Why this exists: macOS TCC stores a client's designated requirement verbatim.
# An ad-hoc signature has no certificate to anchor to, so codesign synthesises
#
#     cdhash H"2f67bf86387f6ba74b5935050b7aa95ba6aebeba"
#
# which pins the exact bytes of the binary. Every rebuild changes the cdhash,
# the stored requirement stops matching, and the user is re-prompted for
# Calendar / Reminders / Contacts access. Nothing errors; the permission
# dialogs just come back. This script makes that condition visible and
# nameable instead of mysterious.
#
# A correctly signed binary yields a content-independent requirement anchored
# on the identifier and the team OU, which survives both rebuilds and
# certificate renewal.
#
# Usage:
#   scripts/check-signing.sh [--bin-dir DIR] [--quiet]
#
# Exit code: 0 = every binary is correctly signed, 1 = at least one is not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/signing-identities.sh
. "$SCRIPT_DIR/lib/signing-identities.sh"

# ---------------------------------------------------------------- classifier
#
# pim_classify_requirement <designated-requirement-text> <expected-identifier>
#
# Pure: takes text, returns a verdict on stdout. No filesystem, no codesign.
# That is deliberate — it is the whole reason this logic is unit-testable
# without a signing certificate (see scripts/test/check-signing.test.sh).
#
# Verdicts:
#   ok               correctly signed by us; grants will survive upgrades
#   adhoc            cdhash-pinned; grants die on the next rebuild
#   unsigned         no signature at all
#   wrong-team       signed, but by a team that is not ours
#   wrong-identifier signed by us, but under an unexpected identifier
#   unknown          signed, but the requirement has a shape we do not model
pim_classify_requirement() {
    req="$1"
    expected_id="$2"

    # codesign writes "code object is not signed at all" to stderr and emits
    # no requirement; callers pass through whatever they captured.
    case "$req" in
        "" | *"not signed"*) printf 'unsigned'; return ;;
    esac

    # An ad-hoc requirement is exactly a cdhash pin and nothing else. Check it
    # before anything else: it is the condition this script exists to find.
    case "$req" in
        *'cdhash H"'*) printf 'adhoc'; return ;;
    esac

    # Team is checked before identifier because it is the security-relevant
    # half. A binary signed by someone else's Developer ID under our
    # identifier is an impersonation attempt, not a naming mistake.
    #
    # The OU appears both quoted and bare depending on the certificate
    # (`= N9DRSTM2U6` and `= "N9DRSTM2U6"` are both emitted in the wild), so
    # the quotes are optional in the match.
    found_team="$(printf '%s' "$req" \
        | sed -nE 's/.*leaf\[subject\.OU\][[:space:]]*=[[:space:]]*"?([A-Za-z0-9]+)"?.*/\1/p')"
    if [[ -z "$found_team" ]]; then
        # Signed, but not anchored on a team OU. An "Apple Development"
        # certificate lands here: it anchors on subject.CN, which changes on
        # renewal, so it is not acceptable for shipping.
        printf 'unknown'; return
    fi
    if [[ "$found_team" != "$APPLE_PIM_TEAM_ID" ]]; then
        printf 'wrong-team'; return
    fi

    found_id="$(printf '%s' "$req" \
        | sed -nE 's/.*identifier[[:space:]]+"?([A-Za-z0-9._-]+)"?.*/\1/p')"
    if [[ "$found_id" != "$expected_id" ]]; then
        printf 'wrong-identifier'; return
    fi

    printf 'ok'
}

# Read the designated requirement of a path, or the empty string when it has
# no signature. codesign reports the requirement on stdout and diagnostics on
# stderr; the leading "# designated => " marker is present for ad-hoc output
# and absent otherwise, so it is stripped either way.
pim_designated_requirement() {
    codesign -d -r- "$1" 2>/dev/null \
        | sed -n 's/^#\{0,1\} *designated => //p'
}

# Stop here when sourced for the classifier alone, which is how the tests use
# this file. This guard sits *above* argument parsing on purpose: a sourced
# script inherits the caller's positional parameters, so parsing them first
# would make the test runner's own arguments look like ours.
case "${BASH_SOURCE[0]}" in
    "$0") ;;
    *)    return 0 2>/dev/null || true ;;
esac

# ------------------------------------------------------------------ report
BIN_DIR="${APPLE_PIM_BIN_DIR:-$HOME/.local/bin}"
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --quiet)   QUIET=true; shift ;;
        *)         echo "check-signing: unknown argument: $1" >&2; exit 2 ;;
    esac
done

FAILURES=0

say() { [[ "$QUIET" == true ]] || printf '%s\n' "$1"; }

for cli in $APPLE_PIM_SIGNED_CLIS; do
    path="$BIN_DIR/$cli"
    expected="$(pim_signing_identifier "$cli")"

    if [[ ! -e "$path" ]]; then
        say "  - $cli: not installed"
        continue
    fi

    verdict="$(pim_classify_requirement "$(pim_designated_requirement "$path")" "$expected")"
    case "$verdict" in
        ok)
            say "  ok   $cli: signed, team $APPLE_PIM_TEAM_ID — grants survive upgrades"
            ;;
        adhoc)
            say "  WARN $cli: ad-hoc signed — macOS will drop your Calendar/Reminders/Contacts"
            say "       grants the next time this binary is rebuilt. Re-run ./setup.sh to"
            say "       install signed binaries."
            FAILURES=$((FAILURES + 1))
            ;;
        unsigned)
            say "  FAIL $cli: no code signature at all"
            FAILURES=$((FAILURES + 1))
            ;;
        wrong-team)
            say "  FAIL $cli: signed by an unexpected team (expected $APPLE_PIM_TEAM_ID)."
            say "       Do not trust this binary."
            FAILURES=$((FAILURES + 1))
            ;;
        wrong-identifier)
            say "  FAIL $cli: signed under an unexpected identifier (expected $expected)."
            say "       Grants recorded for the correct identifier will not apply."
            FAILURES=$((FAILURES + 1))
            ;;
        *)
            say "  FAIL $cli: unrecognised signature shape; not anchored on a team OU"
            FAILURES=$((FAILURES + 1))
            ;;
    esac
done

exit $(( FAILURES > 0 ? 1 : 0 ))
