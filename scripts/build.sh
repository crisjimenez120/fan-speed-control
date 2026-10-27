#!/bin/zsh
# Builds Fan Control (Release) and installs it to /Applications.
#   ./scripts/build.sh               build, install, launch
#   ./scripts/build.sh --no-install  build only
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

# Sign with your Apple Development certificate when you have one (free with any Apple ID in Xcode),
# otherwise ad hoc. Delete Config/Local.xcconfig to re-detect.
if [[ ! -f Config/Local.xcconfig ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
  if [[ -n "$IDENTITY" ]]; then
    TEAM=$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
    printf 'CODE_SIGN_IDENTITY = %s\nDEVELOPMENT_TEAM = %s\n' "$IDENTITY" "$TEAM" > Config/Local.xcconfig
    echo "Signing with: $IDENTITY (team $TEAM)"
  else
    printf '// No Apple Development certificate found; using ad hoc signing.\n' > Config/Local.xcconfig
    echo "No Apple Development certificate found; signing ad hoc."
  fi
fi

xcodegen generate --quiet
xcodebuild -project FanControl.xcodeproj -scheme FanControl -configuration Release \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' -quiet build

APP="build/Build/Products/Release/Fan Control.app"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built $APP"
  exit 0
fi

osascript -e 'tell application id "com.crisjimenez.FanControl" to quit' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Fan Control.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Fan Control.app"
open "/Applications/Fan Control.app"
