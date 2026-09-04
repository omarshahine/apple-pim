#!/usr/bin/env bash
#
# Verify a set of downloaded Apple PIM binaries before they are installed.
#
# This is a security boundary, not a health check. It runs on artifacts
# fetched over the network, and its answer decides whether those bytes are
# placed on PATH and later handed the user's Calendar, Reminders, Contacts,
# and Mail. Treat a failure here as "discard the download", never as
# "install it anyway and warn".
#
# What it will not accept, and why:
#
#   - An unsigned or ad-hoc binary. Beyond the TCC problem, ad-hoc means
#     anybody can produce a binary that looks exactly as legitimate.
#   - A binary signed by any team other than ours. Checking only "is it
#     validly signed" is the classic mistake: an attacker signs their own
#     build with their own perfectly valid Developer ID and it sails
#     through. The team OU pin is the actual boundary.
#   - Our team but an unexpected identifier, which cannot inherit the
#     grants users have already given and suggests a build mistake.
#
# Deliberately NOT checked: `spctl --assess`. The CLIs are bare Mach-O
# executables, which `stapler` cannot staple, so an offline Gatekeeper
# assessment fails for a legitimately notarized binary. Notarization still
# happens; it is simply not verifiable offline for this artifact shape. The
# signature and team pin are what carry the trust here.
#
# Usage:
#   scripts/verify-signed-clis.sh <dir> [--require-universal]
#
# Exit code: 0 = every expected binary verified, 1 = refuse to install.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=check-signing.sh
. "$SCRIPT_DIR/check-signing.sh"

# THE trust gate.
#
# `-R` makes codesign evaluate the supplied requirement against the binary's
# actual certificate chain. This is categorically different from reading the
# requirement the binary advertises via `codesign -d -r-`: that text is chosen
# by whoever signed it. An ad-hoc binary carrying no certificate at all can
# advertise `... and certificate leaf[subject.OU] = N9DRSTM2U6` and pass
# `codesign --verify --strict`, because --verify only checks that the seal
# matches the bytes. Comparing advertised text is not provenance.
#
# Overridden by the test suite so the accept path can be exercised without a
# Developer ID certificate on hand.
if ! declare -f pim_signature_trusted >/dev/null 2>&1; then
    pim_signature_trusted() {
        codesign --verify --strict -R="$2" "$1" >/dev/null 2>&1
    }
fi

# Verify every expected CLI in DIR. Echoes one line per binary; returns
# non-zero if any binary is missing or unacceptable.
pim_verify_dir() {
    _dir="$1"
    _require_universal="${2:-false}"
    _bad=0

    for _cli in $APPLE_PIM_SIGNED_CLIS; do
        _path="$_dir/$_cli"
        _expected="$(pim_signing_identifier "$_cli")"

        if [[ ! -f "$_path" ]]; then
            printf 'REFUSE %s: missing from the downloaded artifact\n' "$_cli"
            _bad=$((_bad + 1))
            continue
        fi

        # Evaluated against the real chain. Everything below this point is
        # only about producing a useful message; the accept/reject decision
        # has already been made here.
        if ! pim_signature_trusted "$_path" "$(pim_requirement_for "$_cli")"; then
            case "$(pim_classify_requirement "$(pim_designated_requirement "$_path")" "$_expected")" in
                adhoc)
                    printf 'REFUSE %s: ad-hoc signed; a release artifact must never be ad-hoc\n' "$_cli" ;;
                unsigned)
                    printf 'REFUSE %s: unsigned\n' "$_cli" ;;
                wrong-team)
                    printf 'REFUSE %s: signed by a different team (expected %s)\n' "$_cli" "$APPLE_PIM_TEAM_ID" ;;
                wrong-identifier)
                    printf 'REFUSE %s: unexpected identifier (expected %s)\n' "$_cli" "$_expected" ;;
                ok)
                    # The advertised requirement says the right things but the
                    # certificate chain does not back it up: either a forged
                    # requirement on an untrusted binary, or a damaged download.
                    printf 'REFUSE %s: claims our identity but does not chain to Apple'"'"'s Developer ID anchor\n' "$_cli" ;;
                *)
                    printf 'REFUSE %s: does not satisfy the Developer ID requirement\n' "$_cli" ;;
            esac
            _bad=$((_bad + 1))
            continue
        fi

        case "$(pim_classify_requirement "$(pim_designated_requirement "$_path")" "$_expected")" in
            ok)
                if [[ "$_require_universal" == true ]] && ! pim_is_universal "$_path"; then
                    printf 'REFUSE %s: not a universal binary\n' "$_cli"
                    _bad=$((_bad + 1))
                    continue
                fi
                printf 'ok     %s: team %s, identifier %s\n' "$_cli" "$APPLE_PIM_TEAM_ID" "$_expected"
                ;;
            adhoc)
                printf 'REFUSE %s: ad-hoc signed; a release artifact must never be ad-hoc\n' "$_cli"
                _bad=$((_bad + 1))
                ;;
            unsigned)
                printf 'REFUSE %s: unsigned\n' "$_cli"
                _bad=$((_bad + 1))
                ;;
            wrong-team)
                printf 'REFUSE %s: signed by a different team (expected %s)\n' "$_cli" "$APPLE_PIM_TEAM_ID"
                _bad=$((_bad + 1))
                ;;
            wrong-identifier)
                printf 'REFUSE %s: unexpected identifier (expected %s)\n' "$_cli" "$_expected"
                _bad=$((_bad + 1))
                ;;
            *)
                printf 'REFUSE %s: signature not anchored on a team OU\n' "$_cli"
                _bad=$((_bad + 1))
                ;;
        esac
    done

    [[ "$_bad" -eq 0 ]]
}

pim_is_universal() {
    lipo -archs "$1" 2>/dev/null | grep -q 'arm64' \
        && lipo -archs "$1" 2>/dev/null | grep -q 'x86_64'
}

case "${BASH_SOURCE[0]}" in
    "$0") ;;
    *)    return 0 2>/dev/null || true ;;
esac

DIR="${1:-}"
REQUIRE_UNIVERSAL=false
[[ "${2:-}" == "--require-universal" ]] && REQUIRE_UNIVERSAL=true

if [[ -z "$DIR" || ! -d "$DIR" ]]; then
    echo "usage: verify-signed-clis.sh <dir> [--require-universal]" >&2
    exit 2
fi

if pim_verify_dir "$DIR" "$REQUIRE_UNIVERSAL"; then
    echo "All binaries verified. Safe to install."
    exit 0
fi
echo "Verification failed — refusing to install these binaries." >&2
exit 1
