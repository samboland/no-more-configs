#!/bin/bash
set -euo pipefail

echo ">>> Initializing GSD (Get Shit Done) framework..."

# Update GSD to latest on every container start
echo "Updating GSD to latest version..."
npm install -g get-shit-done-cc@latest 2>/dev/null || echo "Warning: GSD update failed, using cached version"

# Always refresh slash commands (picks up new/changed commands from updates)
echo "Installing GSD commands into Claude config..."
npx get-shit-done-cc --claude --global
echo "Installing GSD commands into Codex config..."
npx get-shit-done-cc --codex --global

# Report .planning status
if [ -d "/workspace/.planning" ]; then
    echo "GSD .planning directory already exists"
else
    echo "Note: Run /gsd:new-project in Claude Code to initialize project planning"
fi

echo ">>> GSD initialization complete."
