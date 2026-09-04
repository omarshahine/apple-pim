#!/usr/bin/env bash
#
# Tests for the install-time verifier in scripts/verify-signed-clis.sh.
#
# The refusal paths are what matter here — this script decides whether bytes
# from the network are put on PATH and later handed the user's calendar,
# contacts, and mail. Every refusal case below uses a REAL binary with a REAL
# signature (or absence of one) rather than a mock, because the failure mode
# worth defending against is "validly signed, just not by us", and that is
# indistinguishable from correct unless the team pin actually works.
#
# The accept path is exercised through the two injectable seams
# (pim_signature_valid, pim_designated_requirement) since producing a genuine
# Developer ID signature requires a certificate that is deliberately not kept
# on developer machines. The requirement string fed through that seam is real
# output captured from a binary signed with the production certificate.
#
# Usage: scripts/test/verify-signed-clis.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
cleanup() { [[ -n "${TMPROOT:-}" && -d "$TMPROOT" ]] && /bin/rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Real Developer ID output, captured 2026-09-04 from a calendar-cli signed
# with "Developer ID Application: OmarKnows LLC (N9DRSTM2U6)".
REAL_DEVID_DR='identifier "IDENTIFIER" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = N9DRSTM2U6'

ADHOC_SOURCE="${ADHOC_SOURCE:-$HOME/.local/bin/mail-cli}"
FOREIGN_SOURCE="${FOREIGN_SOURCE:-/opt/homebrew/bin/bun}"

check() {
    label="$1"; want="$2"; got="$3"; detail="${4:-}"
    if [[ "$got" == "$want" ]]; then
        printf '  ok   %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n       want exit=%s got exit=%s\n' "$label" "$want" "$got"
        [[ -n "$detail" ]] && printf '       %s\n' "$detail"
        FAIL=$((FAIL + 1))
    fi
}

# --------------------------------------------------------- accept path
# Both seams overridden: signatures "valid", requirement is the real captured
# Developer ID string with the per-binary identifier substituted in.
(
    pim_signature_valid() { return 0; }
    . "$REPO_ROOT/scripts/verify-signed-clis.sh"
    pim_designated_requirement() {
        _name="$(basename "$1")"
        printf '%s' "${REAL_DEVID_DR/IDENTIFIER/com.omarshahine.apple-pim.$_name}"
    }
    d="$TMPROOT/good"; mkdir -p "$d"
    for c in calendar-cli reminder-cli contacts-cli mail-cli; do : > "$d/$c"; done
    pim_verify_dir "$d" false >"$TMPROOT/good.out" 2>&1
)
rc=$?
check "correctly signed set is accepted" 0 "$rc" "$(head -2 "$TMPROOT/good.out" 2>/dev/null)"

# --------------------------------------------------------- missing binary
(
    pim_signature_valid() { return 0; }
    . "$REPO_ROOT/scripts/verify-signed-clis.sh"
    pim_designated_requirement() {
        _name="$(basename "$1")"
        printf '%s' "${REAL_DEVID_DR/IDENTIFIER/com.omarshahine.apple-pim.$_name}"
    }
    d="$TMPROOT/incomplete"; mkdir -p "$d"
    for c in calendar-cli reminder-cli contacts-cli; do : > "$d/$c"; done  # mail-cli absent
    pim_verify_dir "$d" false >/dev/null 2>&1
)
check "an incomplete artifact is refused" 1 $?

# --------------------------------------------- signature fails to verify
(
    pim_signature_valid() { return 1; }   # simulates a tampered/truncated download
    . "$REPO_ROOT/scripts/verify-signed-clis.sh"
    pim_designated_requirement() {
        _name="$(basename "$1")"
        printf '%s' "${REAL_DEVID_DR/IDENTIFIER/com.omarshahine.apple-pim.$_name}"
    }
    d="$TMPROOT/tampered"; mkdir -p "$d"
    for c in calendar-cli reminder-cli contacts-cli mail-cli; do : > "$d/$c"; done
    pim_verify_dir "$d" false >/dev/null 2>&1
)
check "a signature that does not verify is refused" 1 $?

# ----------------------------------------------- real ad-hoc binaries
if [[ -f "$ADHOC_SOURCE" ]]; then
    d="$TMPROOT/adhoc"; mkdir -p "$d"
    for c in calendar-cli reminder-cli contacts-cli mail-cli; do cp "$ADHOC_SOURCE" "$d/$c"; done
    /bin/bash "$REPO_ROOT/scripts/verify-signed-clis.sh" "$d" >"$TMPROOT/adhoc.out" 2>&1
    rc=$?
    check "real ad-hoc signed binaries are refused" 1 "$rc" "$(head -1 "$TMPROOT/adhoc.out")"
else
    printf '  skip ad-hoc fixture unavailable (%s)\n' "$ADHOC_SOURCE"
fi

# ------------------------------- real, valid, foreign-team Developer ID
# The important one: a genuinely notarized binary from another developer.
# "Is it signed?" says yes. Only the team pin says no.
if [[ -x "$FOREIGN_SOURCE" ]]; then
    d="$TMPROOT/foreign"; mkdir -p "$d"
    for c in calendar-cli reminder-cli contacts-cli mail-cli; do ln -s "$FOREIGN_SOURCE" "$d/$c"; done
    /bin/bash "$REPO_ROOT/scripts/verify-signed-clis.sh" "$d" >"$TMPROOT/foreign.out" 2>&1
    rc=$?
    check "a valid Developer ID from another team is refused" 1 $rc "$(head -1 "$TMPROOT/foreign.out")"
    if grep -q "different team" "$TMPROOT/foreign.out"; then
        printf '  ok   refusal names the team mismatch as the reason\n'; PASS=$((PASS + 1))
    else
        printf '  FAIL refusal did not name the team mismatch\n'; FAIL=$((FAIL + 1))
    fi
else
    printf '  skip foreign-team fixture unavailable (%s)\n' "$FOREIGN_SOURCE"
fi

# -------------------------------- foreign team, without needing a fixture
# The real-binary version of this case (below/above, using bun) only runs
# where that binary happens to exist, which is not CI. This seam-based twin
# uses the real captured designated requirement of /opt/homebrew/bin/discrawl
# -- a genuinely valid, notarized, foreign-team Developer ID signature -- so
# the most security-relevant refusal is covered on every platform.
(
    pim_signature_valid() { return 0; }
    . "$REPO_ROOT/scripts/verify-signed-clis.sh"
    pim_designated_requirement() {
        printf '%s' 'identifier "org.openclaw.discrawl" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = FWJYW4S8P8'
    }
    d="$TMPROOT/foreign-seam"; mkdir -p "$d"
    for c in calendar-cli reminder-cli contacts-cli mail-cli; do : > "$d/$c"; done
    pim_verify_dir "$d" false >"$TMPROOT/foreign-seam.out" 2>&1
)
rc=$?
check "foreign-team Developer ID is refused (platform-independent)" 1 "$rc"
if grep -q "different team" "$TMPROOT/foreign-seam.out" 2>/dev/null; then
    printf '  ok   platform-independent refusal names the team mismatch\n'; PASS=$((PASS + 1))
else
    printf '  FAIL platform-independent refusal did not name the team mismatch\n'; FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------ wrong identifier
(
    pim_signature_valid() { return 0; }
    . "$REPO_ROOT/scripts/verify-signed-clis.sh"
    # Right team, but every binary claims to be calendar-cli.
    pim_designated_requirement() {
        printf '%s' "${REAL_DEVID_DR/IDENTIFIER/com.omarshahine.apple-pim.calendar-cli}"
    }
    d="$TMPROOT/misid"; mkdir -p "$d"
    for c in calendar-cli reminder-cli contacts-cli mail-cli; do : > "$d/$c"; done
    pim_verify_dir "$d" false >/dev/null 2>&1
)
check "our team under the wrong identifier is refused" 1 $?

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
