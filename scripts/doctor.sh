#!/usr/bin/env bash
#
# apple-pim doctor — verify the installed state end to end.
#
# Checks every link in the chain a tool call depends on, in order:
#   1. Swift CLI binaries in ~/.local/bin (dangling symlinks, executability)
#   2. PATH visibility
#   3. PIMHelper.app (presence, signature, Launch Services)
#   4. Stuck helper instances (the -1712 wedge)
#   5. TCC authorization per domain (prompt-free) — both the direct route
#      and the PIMHelper route, which carry independent grants
#   6. MCP server build artifacts
#
# Read-only by default. `--fix` reaps stuck helper processes (the only
# known-safe automatic repair). Exit code: 0 = healthy, 1 = at least one
# failure.
#
# Usage:
#   scripts/doctor.sh [--fix]

set -uo pipefail

BIN_DIR="${APPLE_PIM_BIN_DIR:-$HOME/.local/bin}"
APP_PATH="${APPLE_PIM_HELPER_APP:-$HOME/Applications/PIMHelper.app}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIS=(calendar-cli reminder-cli contacts-cli mail-cli)
FIX=false
[[ "${1:-}" == "--fix" ]] && FIX=true

FAILURES=0
WARNINGS=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m⚠\033[0m %s\n" "$1"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# Domain slug -> the section name System Settings actually shows under
# Privacy & Security. Apple's own guides say "click Privacy & Security in the
# sidebar, then click Reminders" (and Contacts), and the calendar guide is
# "Control access to your calendars"; this repo's error strings already agree
# (CalendarCLI.swift, ReminderCLI.swift, skills/apple-pim/SKILL.md). Derived
# capitalization got two of the three wrong, so the names are mapped, not
# computed. A case statement keeps this bash-3.2-clean: macOS ships only
# bash 3.2, where the caret case-modification substitution is a fatal "bad
# substitution" that aborts the whole run (which is how these hints used to
# truncate the report) and associative arrays do not exist.
pane() {
    case "$1" in
        calendar) printf 'Calendars' ;;
        reminder) printf 'Reminders' ;;
        contacts) printf 'Contacts' ;;
        *)        printf '%s' "$1" ;;
    esac
}

# Matches the resident dispatcher process. Since the bundle gained a Mach-O
# launcher, CFBundleExecutable execv()s /bin/zsh on
# Contents/MacOS/../Resources/pim-helper.sh, so the process command line no
# longer contains "Contents/MacOS/pim-helper" — the pattern this script used
# before matched nothing, and every helper-process check silently passed.
# This pattern matches both layouts and does not match the `open -W -a
# .../PIMHelper.app` parent, whose argv carries no "Contents/".
# lib/cli-runner.js exports the same pattern as HELPER_PROC_MARKER for
# reapStaleHelpers(). The two are independent copies in different languages;
# mcp-server/test/cli-runner-helper-proc.test.js pins the JS one against a real
# pgrep, including that it does not match the `open` parent.
HELPER_PROC_MARKER='PIMHelper\.app/Contents/.*pim-helper'

helper_resident() { pgrep -f "$HELPER_PROC_MARKER" >/dev/null 2>&1; }

# Ask the helper itself what TCC says. The helper's grant binds to its bundle
# and signature, so it is independent of this shell's — and re-signing the
# bundle drops it, which the direct probe cannot see.
#
# Safe to run unattended: `auth-status` on all three CLIs reads
# EKEventStore.authorizationStatus / CNContactStore.authorizationStatus and
# never calls requestAccess, so it cannot raise a dialog or create a TCC row.
#
# Echoes the authorization string, or one of: launch-failed, timeout, unknown.
helper_auth_status() {
    local cli="$1" scratch waited seen_helper auth residue
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/pim-doctor.XXXXXX")" || { echo unknown; return 0; }
    # The scratch dir is deliberately left behind: this script deletes nothing,
    # and the OS reaps TMPDIR. Each probe leaves a few hundred bytes.

    APPLE_PIM_BIN_DIR="$BIN_DIR" /usr/bin/open -W -a "$APP_PATH" --args \
        "$cli" "$scratch/out" "$scratch/err" auth-status \
        >/dev/null 2>"$scratch/open.err"
    # `open -W`'s exit code is not trustworthy here: it CAN return 1 with
    # "Unable to block on applications (initial call to kevent() failed)"
    # even when the helper ran to completion and wrote its output (measured:
    # rc 0 on three real launches, rc 1 only sometimes), so the exit code is
    # ignored and the out-file is the result.
    #
    # stderr, by contrast, is decisive — but only read the other way round.
    # Matching known failure strings missed a real one: a bundle with no
    # Info.plist makes `open` print "cannot be opened because its executable
    # is missing", which is neither -1712 nor "Unable to find application",
    # so every domain burned its full poll and reported a false timeout. So
    # the benign set is the allowlist and everything else is a failure.
    #
    # The benign set is the "Unable to block on application" family, which
    # has more than one wording: both "applications (initial call to kevent()
    # failed)" and "application (GetProcessPID() returned <n>)" were observed
    # on runs whose helper wrote a complete, valid out-file, sometimes on
    # different domains of the SAME run. Hence the prefix match — pinning the
    # plural spelling alone reported launch-failed on a launch that worked.
    residue="$(grep -v 'Unable to block on application' "$scratch/open.err" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$residue" ]]; then
        echo "launch-failed"
        return 0
    fi

    # `open -W` may return before the helper has even started, so absence of a
    # resident helper is only evidence of completion once one has been seen.
    waited=0
    seen_helper=false
    while (( waited < 40 )); do
        [[ -s "$scratch/out" ]] && break
        if helper_resident; then
            seen_helper=true
        elif [[ "$seen_helper" == true ]]; then
            break
        fi
        sleep 0.25
        waited=$((waited + 1))
    done

    if [[ -s "$scratch/out" ]]; then
        auth="$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("authorization","unknown"))
except Exception: print("unknown")' <"$scratch/out" 2>/dev/null)"
        echo "${auth:-unknown}"
    elif [[ "$seen_helper" == true ]]; then
        echo "unknown"
    else
        echo "timeout"
    fi

    # The dispatcher writes the out-file microseconds before it exits. Let it
    # go before the next domain, or the single-instance helper answers the
    # next `open` with -1712.
    waited=0
    while helper_resident && (( waited < 8 )); do
        sleep 0.25
        waited=$((waited + 1))
    done
}

echo "apple-pim doctor"
echo ""

# ---------------------------------------------------------------- binaries
echo "Swift CLI binaries ($BIN_DIR):"
LINK_MODE_SEEN=false
for cli in "${CLIS[@]}"; do
    p="$BIN_DIR/$cli"
    if [[ -L "$p" ]]; then
        target="$(readlink "$p")"
        if [[ -x "$p" ]]; then
            ok "$cli (symlink -> $target)"
            LINK_MODE_SEEN=true
        else
            fail "$cli: BROKEN symlink -> $target (source repo moved, renamed, or cleaned)"
        fi
    elif [[ -x "$p" ]]; then
        ok "$cli"
    elif [[ -e "$p" ]]; then
        fail "$cli: present but not executable (chmod +x $p)"
    else
        fail "$cli: missing (run setup.sh --install)"
    fi
done
if [[ "$LINK_MODE_SEEN" == true ]]; then
    warn "symlinked install (dev mode): renaming or cleaning the source repo will break these."
    echo "      For a rename-proof install: setup.sh --install (copies)."
fi
echo ""

# -------------------------------------------------------------------- PATH
echo "PATH:"
if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
    ok "$BIN_DIR is on PATH"
else
    warn "$BIN_DIR not on PATH (fine for the MCP server; direct shell use needs it)"
fi
echo ""

# ------------------------------------------------------------------ helper
echo "PIMHelper.app (TCC bridge for embedded shells):"
if [[ -d "$APP_PATH" ]]; then
    if [[ -x "$APP_PATH/Contents/MacOS/pim-helper" ]]; then
        ok "installed at $APP_PATH"
    else
        fail "bundle exists but dispatcher is missing/not executable (re-run scripts/build-helper-app.sh --force)"
    fi
    if codesign --verify "$APP_PATH" >/dev/null 2>&1; then
        identity="$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
        ok "signature valid (${identity:-ad-hoc})"
    else
        fail "signature invalid — TCC grants will not stick (re-run scripts/build-helper-app.sh --force)"
    fi
else
    warn "not installed. Needed when running under an agent runtime / embedded shell"
    echo "      (permission prompts can't fire there). Install: scripts/build-helper-app.sh"
fi
echo ""

# ------------------------------------------------------------ stuck helper
echo "Helper processes:"
# A helper is stale once it outlives the longest legitimate call window —
# the 120s TCC-prompt timeout plus margin. MUST match STALE_HELPER_SECONDS
# in lib/cli-runner.js so diagnosis and auto-repair agree on "stuck".
STALE_HELPER_SECONDS=130
STUCK_PIDS=()
while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    secs=0
    if [[ "$etime" == *-* ]]; then
        secs=999999
    else
        IFS=: read -r a b c <<<"$etime"
        if [[ -n "${c:-}" ]]; then secs=$((10#$a * 3600 + 10#$b * 60 + 10#$c));
        elif [[ -n "${b:-}" ]]; then secs=$((10#$a * 60 + 10#$b)); fi
    fi
    if (( secs > STALE_HELPER_SECONDS )); then
        STUCK_PIDS+=("$pid")
        fail "stuck pim-helper (pid $pid, age ${etime:-?}) — blocks ALL helper calls with error -1712"
    else
        ok "pim-helper running (pid $pid, age ${etime:-?}) — likely serving a live call"
    fi
done < <(pgrep -f "$HELPER_PROC_MARKER" 2>/dev/null || true)
if [[ ${#STUCK_PIDS[@]} -eq 0 ]] && ! helper_resident; then
    ok "no resident helper processes"
fi
if [[ ${#STUCK_PIDS[@]} -gt 0 ]]; then
    if [[ "$FIX" == true ]]; then
        for pid in "${STUCK_PIDS[@]}"; do
            kill "$pid" 2>/dev/null && echo "      reaped pid $pid"
        done
    else
        echo "      Fix: re-run with --fix, or kill the listed PIDs."
    fi
fi
echo ""

# --------------------------------------------------------------------- TCC
echo "TCC authorization (prompt-free probe):"
# Two routes, two grants. lib/cli-runner.js sends a call through the helper
# whenever the direct probe says notDetermined or denied, so the helper's own
# status is what a real call hits in exactly that case — and a helper rebuild
# resets it without changing anything the direct probe can see.
HELPER_INSTALLED=false
[[ -d "$APP_PATH" && -x "$APP_PATH/Contents/MacOS/pim-helper" ]] && HELPER_INSTALLED=true
HELPER_PROBE="$HELPER_INSTALLED"
if [[ "$HELPER_PROBE" == true ]] && helper_resident; then
    # One helper at a time: probing now would collide with the live call.
    HELPER_PROBE=false
    warn "helper busy (resident pim-helper) — helper-route probe skipped; retry after it exits or --fix"
fi
for cli in calendar-cli reminder-cli contacts-cli; do
    p="$BIN_DIR/$cli"
    [[ -x "$p" ]] || { fail "$cli unusable — skipping auth probe"; continue; }
    auth="$("$p" auth-status 2>/dev/null | /usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("authorization","unknown"))
except Exception: print("unknown")' 2>/dev/null)"
    domain="${cli%-cli}"
    case "$auth" in
        authorized|fullAccess)
            ok "$domain: authorized (direct route)"
            ;;
        notDetermined)
            if [[ "$HELPER_INSTALLED" == true ]]; then
                if [[ "$HELPER_PROBE" == true ]]; then
                    ok "$domain: notDetermined here (direct route) — see helper route below"
                else
                    ok "$domain: notDetermined here (direct route) — helper route unprobed, see above"
                fi
            else
                fail "$domain: notDetermined and no PIMHelper installed — no path to a grant"
            fi
            ;;
        denied)
            warn "$domain: denied for this process tree (helper route may still work;"
            echo "      or enable in System Settings > Privacy & Security > $(pane "$domain"))"
            ;;
        *)
            warn "$domain: could not determine auth status ($auth)"
            ;;
    esac

    [[ "$HELPER_PROBE" == true ]] || continue
    helper_auth="$(helper_auth_status "$cli")"
    case "$helper_auth" in
        authorized|fullAccess)
            ok "$domain: authorized (helper route)"
            ;;
        notDetermined)
            if [[ "$auth" == "authorized" || "$auth" == "fullAccess" ]]; then
                warn "$domain: helper route not yet granted (fine from a normal terminal; the first embedded-shell call raises the macOS dialog — answer within 2 minutes)"
            else
                fail "$domain: helper route not granted — calls from embedded shells will block on a dialog for up to 2 minutes and wedge the helper if unanswered. Trigger it from a terminal (e.g. \`$cli auth-status\` via the helper, or any real call) and answer the prompt."
            fi
            ;;
        denied)
            if [[ "$auth" == "authorized" || "$auth" == "fullAccess" ]]; then
                warn "$domain: helper route denied (direct route works here; enable PIMHelper in System Settings > Privacy & Security > $(pane "$domain") for embedded shells)"
            else
                fail "$domain: helper route denied — enable PIMHelper in System Settings > Privacy & Security > $(pane "$domain")"
            fi
            ;;
        *)
            warn "$domain: helper probe inconclusive ($helper_auth) — see Helper processes above; retry when no helper is resident"
            ;;
    esac
done
echo ""

# --------------------------------------------------------------- MCP build
echo "MCP server artifacts:"
if [[ -f "$REPO_ROOT/mcp-server/dist/server.js" ]]; then
    ok "mcp-server/dist/server.js present"
else
    fail "mcp-server/dist/server.js missing (cd mcp-server && npm install && npm run build)"
fi
if [[ -d "$REPO_ROOT/mcp-server/node_modules" ]]; then
    ok "mcp-server dependencies installed"
else
    warn "mcp-server/node_modules missing (cd mcp-server && npm install) — dist bundle may still work"
fi
echo ""

# ----------------------------------------------------------------- summary
if (( FAILURES > 0 )); then
    echo "Result: $FAILURES failure(s), $WARNINGS warning(s)."
    exit 1
else
    echo "Result: healthy ($WARNINGS warning(s))."
fi
