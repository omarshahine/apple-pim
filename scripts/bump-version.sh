#!/usr/bin/env bash
#
# Bump all five plugin version sources to the same value, then rebuild
# mcp-server/dist/server.js so the bundled artifact reflects the new version.
#
# Usage:
#   scripts/bump-version.sh X.Y.Z
#
# Sources rewritten (see scripts/check-versions.sh):
#   - .claude-plugin/plugin.json                 .version
#   - .claude-plugin/marketplace.json            .plugins[0].version
#   - mcp-server/package.json                    .version
#   - openclaw/package.json                      .version
#   - openclaw/openclaw.plugin.json              .version
#
# After the bump: commit, tag v<new>, push — publishing workflows read
# the version from the tag.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 2
fi

new="$1"
if ! [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be semver X.Y.Z (got '$new')" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 2
fi

# Check the bundle can actually be rebuilt BEFORE writing any version file.
#
# The five JSON files are written first and mcp-server/dist/server.js is
# rebuilt last. Without this, a missing build dependency leaves a half-applied
# bump: every JSON file reads as the new version while the artifact that
# actually ships still carries the old one. The script does exit non-zero in
# that case, but the damage is already on disk, and it is easy to miss when the
# output is piped. scripts/check-versions.sh now also compares the built bundle
# so the drift cannot ship silently, but failing here first is cheaper.
missing=""
[ -x mcp-server/node_modules/.bin/esbuild ] || missing="$missing mcp-server/node_modules (esbuild)"
# lib/ pulls these from the repo root; esbuild cannot resolve them otherwise.
for dep in mailparser turndown; do
  [ -d "node_modules/$dep" ] || missing="$missing node_modules/$dep"
done
if [ -n "$missing" ]; then
  echo "error: cannot rebuild mcp-server/dist/server.js; missing:$missing" >&2
  echo "  run: npm install && npm install --prefix mcp-server" >&2
  echo "  (refusing to bump: a failed rebuild would leave the version files" >&2
  echo "   updated and the shipped bundle stale)" >&2
  exit 2
fi

set_json_field() {
  local file="$1" jq_expr="$2" tmp
  tmp=$(mktemp)
  jq "$jq_expr" "$file" > "$tmp"
  mv "$tmp" "$file"
}

set_json_field .claude-plugin/plugin.json       ".version = \"$new\""
set_json_field .claude-plugin/marketplace.json  ".plugins[0].version = \"$new\""
set_json_field mcp-server/package.json          ".version = \"$new\""
set_json_field openclaw/package.json            ".version = \"$new\""
set_json_field openclaw/openclaw.plugin.json    ".version = \"$new\""

echo "Rebuilding mcp-server/dist/server.js..."
(cd mcp-server && npm run build --silent)

echo
./scripts/check-versions.sh
echo
echo "Next: git add -p && git commit -m \"chore: release v$new\" && git tag -a v$new -m \"...\" && git push --follow-tags"
