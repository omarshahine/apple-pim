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
# The requirement a genuine release binary must SATISFY, for `codesign -R`.
#
# This is the trust boundary. It must never be confused with the requirement a
# binary *advertises* via `codesign -d -r-`: that string is chosen by whoever
# signed the binary, so an attacker can embed one naming our identifier and our
# team OU on a binary carrying no certificate at all. Reading the advertised
# text and comparing strings therefore proves nothing. `codesign --verify -R`
# evaluates this expression against the actual certificate chain instead.
#
# The two OIDs are what make it Developer ID specifically rather than any
# Apple-issued certificate:
#   1.2.840.113635.100.6.2.6   Developer ID intermediate CA marker
#   1.2.840.113635.100.6.1.13  Developer ID Application leaf marker
# `anchor apple generic` requires the chain to terminate at Apple's root, which
# is the part no attacker can forge.
pim_requirement_for() {
    _pim_id="$(pim_signing_identifier "$1")" || return 1
    printf 'anchor apple generic and identifier "%s" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "%s"' \
        "$_pim_id" "$APPLE_PIM_TEAM_ID"
}

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
