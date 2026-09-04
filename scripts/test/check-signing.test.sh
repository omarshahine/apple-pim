#!/usr/bin/env bash
#
# Unit tests for the designated-requirement classifier in
# scripts/check-signing.sh.
#
# Every fixture below is real `codesign -d -r-` output captured from an actual
# binary, not invented. Hand-written approximations of this format are exactly
# how a classifier ends up passing its tests and failing in production, since
# the quoting of the team OU and the set of certificate clauses both vary
# between certificate types.
#
# Requires no certificate, no signing, no TCC, and no macOS-only tooling: the
# classifier is pure text. Runs anywhere bash does.
#
# Usage: scripts/test/check-signing.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../check-signing.sh"

PASS=0
FAIL=0

expect() {
    label="$1"; req="$2"; expected_id="$3"; want="$4"
    got="$(pim_classify_requirement "$req" "$expected_id")"
    if [[ "$got" == "$want" ]]; then
        printf '  ok   %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n       want=%s got=%s\n' "$label" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

OUR_ID="com.omarshahine.apple-pim.calendar-cli"

# Captured from ~/.local/bin/calendar-cli, ad-hoc signed by `swift build`.
# This is the condition the whole feature exists to eliminate.
expect "ad-hoc cdhash pin is flagged" \
    'cdhash H"2f67bf86387f6ba74b5935050b7aa95ba6aebeba"' \
    "$OUR_ID" adhoc

# Captured after signing with the real Developer ID Application certificate.
# Note the bare (unquoted) team OU.
expect "our Developer ID signature is accepted" \
    'identifier "com.omarshahine.apple-pim.calendar-cli" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = N9DRSTM2U6' \
    "$OUR_ID" ok

# Captured from /opt/homebrew/bin/bun. Same shape, but the OU is quoted --
# both spellings occur in the wild, so both must parse.
expect "quoted team OU parses identically" \
    'identifier "com.omarshahine.apple-pim.calendar-cli" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[subject.OU] = "N9DRSTM2U6"' \
    "$OUR_ID" ok

# Captured from /opt/homebrew/bin/discrawl: a real, valid, notarized Developer
# ID signature belonging to somebody else. Being validly signed is not enough.
expect "another team's valid Developer ID is rejected" \
    'identifier "org.openclaw.discrawl" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = FWJYW4S8P8' \
    "$OUR_ID" wrong-team

# The impersonation case: our identifier, their certificate. Must be caught by
# the team check, which is why team is tested before identifier.
expect "our identifier under a foreign team is rejected" \
    'identifier "com.omarshahine.apple-pim.calendar-cli" and anchor apple generic and certificate leaf[subject.OU] = FWJYW4S8P8' \
    "$OUR_ID" wrong-team

# Captured after signing with "Apple Development: Omar Shahine (2KUDN6J99C)".
# Anchors on subject.CN, which changes when the certificate is renewed, so
# grants would not survive renewal. Correctly not "ok".
expect "Apple Development cert is not accepted for shipping" \
    'identifier "com.omarshahine.apple-pim.calendar-cli" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Omar Shahine (2KUDN6J99C)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */' \
    "$OUR_ID" unknown

# Right team, wrong identifier: grants recorded against the expected
# identifier would not apply, so this is a real failure rather than cosmetic.
expect "our team under an unexpected identifier is rejected" \
    'identifier "com.omarshahine.apple-pim.reminder-cli" and anchor apple generic and certificate leaf[subject.OU] = N9DRSTM2U6' \
    "$OUR_ID" wrong-identifier

expect "empty requirement means unsigned" "" "$OUR_ID" unsigned

expect "codesign's not-signed message means unsigned" \
    'code object is not signed at all' "$OUR_ID" unsigned

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
