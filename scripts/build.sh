#!/bin/zsh
# Builds Fan Control (Release) and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project FanControl.xcodeproj -scheme FanControl -configuration Release \
  -derivedDataPath build -quiet build

APP="build/Build/Products/Release/Fan Control.app"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  osascript -e 'tell application id "com.crisjimenez.FanControl" to quit' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/Fan Control.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Fan Control.app"
  open "/Applications/Fan Control.app"
else
  echo "Built $APP"
fi
