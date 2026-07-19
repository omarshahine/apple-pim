#!/usr/bin/env bash
#
# apple-pim doctor — verify the installed state end to end.
#
# Checks every link in the chain a tool call depends on, in order:
#   1. Swift CLI binaries in ~/.local/bin (dangling symlinks, executability)
#   2. PATH visibility
#   3. PIMHelper.app (presence, signature, Launch Services)
#   4. Stuck helper instances (the -1712 wedge)
#   5. TCC authorization per domain (prompt-free)
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
STUCK_PIDS=()
while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    # anything older than 60s cannot be serving a live call (default timeout 30s)
    secs=0
    if [[ "$etime" == *-* ]]; then
        secs=999999
    else
        IFS=: read -r a b c <<<"$etime"
        if [[ -n "${c:-}" ]]; then secs=$((10#$a * 3600 + 10#$b * 60 + 10#$c));
        elif [[ -n "${b:-}" ]]; then secs=$((10#$a * 60 + 10#$b)); fi
    fi
    if (( secs > 60 )); then
        STUCK_PIDS+=("$pid")
        fail "stuck pim-helper (pid $pid, age ${etime:-?}) — blocks ALL helper calls with error -1712"
    else
        ok "pim-helper running (pid $pid, age ${etime:-?}) — likely serving a live call"
    fi
done < <(pgrep -f "PIMHelper.app/Contents/MacOS/pim-helper" 2>/dev/null || true)
if [[ ${#STUCK_PIDS[@]} -eq 0 ]] && ! pgrep -f "PIMHelper.app/Contents/MacOS/pim-helper" >/dev/null 2>&1; then
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
            if [[ -d "$APP_PATH" ]]; then
                ok "$domain: notDetermined here, routed via PIMHelper (normal for embedded shells)"
                echo "      If helper calls fail, the helper's own grant may be missing — its first"
                echo "      call will raise the macOS dialog; answer it within 2 minutes."
            else
                fail "$domain: notDetermined and no PIMHelper installed — no path to a grant"
            fi
            ;;
        denied)
            warn "$domain: denied for this process tree (helper route may still work;"
            echo "      or enable in System Settings > Privacy & Security > ${domain^})"
            ;;
        *)
            warn "$domain: could not determine auth status ($auth)"
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
