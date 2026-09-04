#!/usr/bin/env bash
#
# Verify that all plugin version sources agree.
# Exits non-zero if any disagree; prints a table either way.
#
# Sources:
#   - .claude-plugin/plugin.json                 .version
#   - .claude-plugin/marketplace.json            .plugins[0].version
#   - mcp-server/package.json                    .version
#   - openclaw/package.json                      .version
#   - openclaw/openclaw.plugin.json              .version
#   - mcp-server/dist/server.js                  embedded `version: "X.Y.Z"`
#
# The bundle is included because it is the artifact that actually ships, and it
# is generated: scripts/bump-version.sh writes the five JSON files first and
# rebuilds the bundle afterwards, so a failed rebuild leaves the bundle at the
# previous version while every JSON file reads as correct. The CI "Version
# Consistency" action compares JSON paths and cannot see inside a JS bundle, so
# without this check that drift is invisible and ships.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq / apt-get install jq)" >&2
  exit 2
fi

read -r v_plugin        < <(jq -r '.version'             .claude-plugin/plugin.json)
read -r v_marketplace   < <(jq -r '.plugins[0].version'  .claude-plugin/marketplace.json)
read -r v_mcp           < <(jq -r '.version'             mcp-server/package.json)
read -r v_openclaw_pkg  < <(jq -r '.version'             openclaw/package.json)
read -r v_openclaw_man  < <(jq -r '.version'             openclaw/openclaw.plugin.json)

# Generated artifact: absent in a fresh checkout that has not built yet, which
# is not a version mismatch. Only compared when it exists.
#
# Anchored on the package identity, not position: the bundle inlines its
# dependencies' package.json objects too, and one of those (encoding-japanese)
# appears first. Matching the first `version:` literal would compare the wrong
# package and fail for the wrong reason.
v_bundle=""
if [ -f mcp-server/dist/server.js ]; then
  v_bundle=$(grep -A1 '"apple-pim-mcp"' mcp-server/dist/server.js \
    | sed -n 's/.*version:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' | head -1)
fi

printf "%-40s %s\n" "File" "Version"
printf "%-40s %s\n" "----" "-------"
printf "%-40s %s\n" ".claude-plugin/plugin.json"        "$v_plugin"
printf "%-40s %s\n" ".claude-plugin/marketplace.json"   "$v_marketplace"
printf "%-40s %s\n" "mcp-server/package.json"           "$v_mcp"
printf "%-40s %s\n" "openclaw/package.json"             "$v_openclaw_pkg"
printf "%-40s %s\n" "openclaw/openclaw.plugin.json"     "$v_openclaw_man"
if [ -n "$v_bundle" ]; then
  printf "%-40s %s\n" "mcp-server/dist/server.js (built)" "$v_bundle"
else
  printf "%-40s %s\n" "mcp-server/dist/server.js (built)" "(not built)"
fi

all="$v_plugin $v_marketplace $v_mcp $v_openclaw_pkg $v_openclaw_man"
[ -n "$v_bundle" ] && all="$all $v_bundle"
uniq=$(printf '%s\n' $all | sort -u | wc -l | tr -d ' ')

if [ "$uniq" != "1" ]; then
  echo
  echo "FAIL: version sources disagree." >&2
  echo "Run scripts/bump-version.sh <X.Y.Z> to align them." >&2
  exit 1
fi

echo
echo "OK: all version sources agree on $v_plugin"
