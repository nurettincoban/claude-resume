#!/bin/zsh
# Builds build/ClaudeResume.app.
#   --install     copy it to ~/Applications and launch it
#   UNIVERSAL=1   build for Apple silicon and Intel (used for releases)
set -euo pipefail
cd "$(dirname "$0")/.."

flags=(-c release)
[[ "${UNIVERSAL:-0}" == "1" ]] && flags+=(--arch arm64 --arch x86_64)

swift build "${flags[@]}"
BIN="$(swift build "${flags[@]}" --show-bin-path)/ClaudeResume"

APP=build/ClaudeResume.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeResume"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier dev.nurettin.clauderesume "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeResume"))"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ClaudeResume || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/ClaudeResume.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/ClaudeResume.app
    echo "Installed to ~/Applications/ClaudeResume.app"
fi
