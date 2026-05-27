#!/bin/bash
# Apple PIM Plugin Setup Script
# Run this after installing the plugin to build Swift CLIs and install MCP dependencies
#
# Usage:
#   ./setup.sh             # Build only
#   ./setup.sh --install   # Build and install CLIs to /usr/local/bin

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
CLIS=(calendar-cli reminder-cli contacts-cli mail-cli)

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

if [ "$1" = "--install" ]; then
    echo ""
    mkdir -p "$INSTALL_DIR"
    echo "Installing CLIs to $INSTALL_DIR..."
    for cli in "${CLIS[@]}"; do
        src="$SCRIPT_DIR/swift/.build/release/$cli"
        dest="$INSTALL_DIR/$cli"
        if [ -L "$dest" ] || [ -e "$dest" ]; then
            echo "  Updating $cli -> $src"
            ln -sf "$src" "$dest"
        else
            echo "  Installing $cli -> $src"
            ln -s "$src" "$dest"
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
