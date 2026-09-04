#!/usr/bin/env bash
#
# Permanent code-signing identities for the Apple PIM binaries.
#
# THESE VALUES ARE LOAD-BEARING AND MUST NEVER CHANGE.
#
# macOS TCC stores a client's *designated requirement* verbatim. For a
# certificate-signed binary that requirement is anchored on the signing
# identifier and the team OU, e.g.
#
#   identifier "com.omarshahine.apple-pim.calendar-cli" and anchor apple generic
#   and certificate leaf[subject.OU] = N9DRSTM2U6
#
# Changing an identifier, or signing with a different team, produces a
# requirement that no longer matches what TCC recorded. The effect is not a
# build failure — nothing errors. Every user silently loses their Calendar,
# Reminders, and Contacts grants and is re-prompted. Treat these strings the
# way you would treat a database primary key.
#
# The team OU is stable across certificate renewal, which is why grants
# survive the Developer ID certificate expiring and being re-issued. (An
# "Apple Development" certificate anchors on subject.CN instead and would NOT
# survive renewal — Developer ID is required here, not merely preferred.)
#
# Sourced by scripts/check-signing.sh, scripts/verify-signed-clis.sh, and the
# release signing workflow, so the signer and the verifier can never disagree
# about what a correct signature looks like.
#
# shellcheck shell=bash

APPLE_PIM_TEAM_ID="N9DRSTM2U6"
APPLE_PIM_SIGNING_CERT="Developer ID Application: OmarKnows LLC (${APPLE_PIM_TEAM_ID})"
APPLE_PIM_IDENTIFIER_PREFIX="com.omarshahine.apple-pim"
APPLE_PIM_HELPER_BUNDLE_ID="${APPLE_PIM_IDENTIFIER_PREFIX}.helper"

# Space-separated rather than an array: macOS ships bash 3.2, and the rest of
# this repo's shell is written to stay 3.2-clean (see scripts/doctor.sh).
APPLE_PIM_SIGNED_CLIS="calendar-cli reminder-cli contacts-cli mail-cli"

# Map a binary name to its permanent signing identifier. Returns non-zero for
# anything not shipped by this repo, so a typo fails loudly instead of
# silently signing under an identifier nobody has ever granted.
pim_signing_identifier() {
    case "$1" in
        calendar-cli|reminder-cli|contacts-cli|mail-cli)
            printf '%s.%s' "$APPLE_PIM_IDENTIFIER_PREFIX" "$1"
            ;;
        helper|PIMHelper.app|PIMHelper)
            printf '%s' "$APPLE_PIM_HELPER_BUNDLE_ID"
            ;;
        *)
            return 1
            ;;
    esac
}
