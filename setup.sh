#!/bin/bash
# Apple PIM Plugin Setup Script
# Run this after installing the plugin to build Swift CLIs and install MCP dependencies
#
# Usage:
#   ./setup.sh                     # Build only
#   ./setup.sh --install           # Build and install CLIs to ~/.local/bin (copies)
#   ./setup.sh --install --link    # Dev mode: symlink into ~/.local/bin instead
#
# Why copies are the default: a symlinked install points into this checkout,
# so renaming, moving, or cleaning the repo silently bricks every consumer
# (the MCP server, the OpenClaw plugin, PIMHelper.app). Copies survive all
# of that; rebuild + re-run --install to update them. --link restores the
# old rebuild-updates-in-place behavior for active CLI development.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
CLIS=(calendar-cli reminder-cli contacts-cli mail-cli)

INSTALL=false
LINK_MODE=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --link) LINK_MODE=true ;;
    esac
done

echo "Building Swift CLI tools..."
cd "$SCRIPT_DIR/swift"
swift build -c release

echo ""
echo "Installing shared dependencies..."
cd "$SCRIPT_DIR"
npm install

echo ""
echo "Installing MCP server dependencies..."
cd "$SCRIPT_DIR/mcp-server"
npm install

if [ "$INSTALL" = true ]; then
    echo ""
    mkdir -p "$INSTALL_DIR"
    if [ "$LINK_MODE" = true ]; then
        echo "Installing CLIs to $INSTALL_DIR (symlinks — dev mode)..."
        echo "  NOTE: these links break if this repo is moved, renamed, or cleaned."
    else
        echo "Installing CLIs to $INSTALL_DIR (copies)..."
    fi
    for cli in "${CLIS[@]}"; do
        src="$SCRIPT_DIR/swift/.build/release/$cli"
        dest="$INSTALL_DIR/$cli"
        # Remove whatever is there (file or symlink, including dangling)
        # so a mode switch never leaves a stale artifact behind.
        rm -f "$dest"
        if [ "$LINK_MODE" = true ]; then
            echo "  Linking $cli -> $src"
            ln -s "$src" "$dest"
        else
            echo "  Copying $cli"
            cp -f "$src" "$dest"
            chmod +x "$dest"
        fi
    done
    echo ""
    # Check if INSTALL_DIR is on PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "Add this to your ~/.zshrc (or ~/.bashrc) to put CLIs on your PATH:"
        echo ""
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
        echo "Then restart your shell or run: source ~/.zshrc"
    else
        echo "CLIs installed! You can now run them from anywhere:"
        for cli in "${CLIS[@]}"; do
            echo "  $cli --help"
        done
    fi

    echo ""
    echo "Installing PIMHelper.app (TCC bridge for embedded shells)..."
    "$SCRIPT_DIR/scripts/build-helper-app.sh"
else
    echo ""
    echo "Tip: Run './setup.sh --install' to make CLIs available globally."
fi

echo ""
echo "Setup complete!"
echo ""
echo "The plugin is now ready to use. Restart Claude Code to load the MCP server."
echo ""
echo "Test commands:"
echo "  /apple-pim:calendars list"
echo "  /apple-pim:reminders lists"
echo "  /apple-pim:contacts search \"John\""
echo "  /apple-pim:mail accounts"
echo ""
echo "Note: Mail.app must be running for mail commands to work."
echo ""
echo "Permissions needed (System Settings > Privacy & Security):"
echo "  - Calendars: Grant access to Terminal / Claude Code"
echo "  - Reminders: Grant access to Terminal / Claude Code"
echo "  - Contacts: Grant access to Terminal / Claude Code"
echo "  - Automation: Allow Terminal / Claude Code to control Mail.app"
echo ""
echo "Optional: Configure which domains and items are accessible:"
echo "  /apple-pim:configure"
echo ""
echo "Or manually create ~/.config/apple-pim/config.json"
echo "See README.md for configuration options."
