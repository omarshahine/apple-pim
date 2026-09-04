#!/usr/bin/env bash
#
# Tests for the install step of scripts/fetch-signed-clis.sh.
#
# The property under test is that a failed install must not leave the machine
# worse off. The naive version of this loop removes each existing CLI before
# copying its replacement, so a copy that fails partway through leaves the
# user with no calendar-cli at all -- and, because the caller keys its
# build-from-source fallback on the exit status, setup.sh would then report
# success over a broken install.
#
# Usage: scripts/test/fetch-signed-clis.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$REPO_ROOT/scripts/fetch-signed-clis.sh"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
cleanup() {
    # Restore write permission first or the cleanup itself fails.
    chmod -R u+w "$TMPROOT" 2>/dev/null
    [[ -n "${TMPROOT:-}" && -d "$TMPROOT" ]] && /bin/rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

make_src() {
    _d="$1"; mkdir -p "$_d"
    for c in $APPLE_PIM_SIGNED_CLIS; do printf 'new-%s' "$c" > "$_d/$c"; done
}

# ------------------------------------------------- clean install succeeds
src="$TMPROOT/src"; dest="$TMPROOT/empty"
make_src "$src"
if pim_install_verified "$src" "$dest" >/dev/null 2>&1; then
    missing=0
    for c in $APPLE_PIM_SIGNED_CLIS; do
        [[ -x "$dest/$c" ]] || missing=1
    done
    [[ "$missing" -eq 0 ]] && ok "clean install places all four, executable" \
                           || bad "clean install left a binary missing or non-executable"
else
    bad "clean install returned non-zero"
fi

# --------------------------------------------- no staging files left over
leftovers="$(find "$dest" -name '.*.incoming.*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$leftovers" == "0" ]] && ok "no staging artifacts left behind" \
                          || bad "left $leftovers staging artifacts in place"

# ------------------------------------------------ replacing an older set
dest2="$TMPROOT/existing"; mkdir -p "$dest2"
for c in $APPLE_PIM_SIGNED_CLIS; do printf 'OLD' > "$dest2/$c"; chmod +x "$dest2/$c"; done
if pim_install_verified "$src" "$dest2" >/dev/null 2>&1 \
   && [[ "$(cat "$dest2/calendar-cli")" == "new-calendar-cli" ]]; then
    ok "replaces an existing install"
else
    bad "did not replace an existing install"
fi

# ---------------------------------- THE regression: failure changes nothing
# A source missing one binary models a truncated extract. The originals must
# survive untouched and the status must be non-zero.
partial="$TMPROOT/partial"; mkdir -p "$partial"
for c in calendar-cli reminder-cli contacts-cli; do printf 'new' > "$partial/$c"; done  # mail-cli absent
dest3="$TMPROOT/keepme"; mkdir -p "$dest3"
for c in $APPLE_PIM_SIGNED_CLIS; do printf 'ORIGINAL' > "$dest3/$c"; chmod +x "$dest3/$c"; done

if pim_install_verified "$partial" "$dest3" >/dev/null 2>&1; then
    bad "an incomplete source reported success"
else
    ok "an incomplete source returns non-zero"
fi

intact=1
for c in $APPLE_PIM_SIGNED_CLIS; do
    [[ -x "$dest3/$c" && "$(cat "$dest3/$c")" == "ORIGINAL" ]] || intact=0
done
[[ "$intact" -eq 1 ]] && ok "every original binary survived the failed install" \
                      || bad "a failed install destroyed or replaced originals"

leftovers="$(find "$dest3" -name '.*.incoming.*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$leftovers" == "0" ]] && ok "failed install cleaned up its staged files" \
                          || bad "failed install left $leftovers staged files"

# ------------------------------------------- unwritable destination fails
# Skipped as root, where write permissions are not enforced.
if [[ "$(id -u)" != "0" ]]; then
    dest4="$TMPROOT/readonly"; mkdir -p "$dest4"
    for c in $APPLE_PIM_SIGNED_CLIS; do printf 'ORIGINAL' > "$dest4/$c"; done
    chmod 555 "$dest4"
    if pim_install_verified "$src" "$dest4" >/dev/null 2>&1; then
        bad "an unwritable destination reported success"
    else
        ok "an unwritable destination returns non-zero"
    fi
    chmod 755 "$dest4"
    [[ "$(cat "$dest4/calendar-cli")" == "ORIGINAL" ]] \
        && ok "originals survived an unwritable destination" \
        || bad "originals were damaged despite the failure"
else
    printf '  skip unwritable-destination case (running as root)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
