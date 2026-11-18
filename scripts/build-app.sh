#!/bin/bash
# Builds build/Portpeek.app, with the portpeek command line tool inside it.
#   --open        launch it afterwards
#   --install     copy it to /Applications, (re)launch it, and link the CLI as /usr/local/bin/portpeek (or ~/.local/bin/portpeek)
#   --dmg         also write build/Portpeek-<version>.dmg, a universal build for sharing
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift "$PWD"

ARCHS=()
case " $* " in *" --dmg "*) ARCHS=(--arch arm64 --arch x86_64) ;; esac

swift build -c release --product Portpeek ${ARCHS[@]+"${ARCHS[@]}"}
swift build -c release --product portpeek-cli ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
APP="build/Portpeek.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Portpeek" "$APP/Contents/MacOS/Portpeek"
cp "$BIN_DIR/portpeek-cli" "$APP/Contents/Resources/portpeek-cli"
# The command reports its own version, which has to be the bundle's.
CLI_VERSION="$("$APP/Contents/Resources/portpeek-cli" --version | awk '{print $2}')"
if [ "$CLI_VERSION" != "$VERSION" ]; then
  echo "Version mismatch: Info.plist says $VERSION, Sources/PortpeekCore/CLI.swift says $CLI_VERSION" >&2
  exit 1
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/Resources/portpeek-cli" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1   # ad-hoc signature so macOS will launch it locally
echo "Built $APP ($VERSION)"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x Portpeek 2>/dev/null || true
      rm -rf /Applications/Portpeek.app
      cp -R "$APP" /Applications/
      open /Applications/Portpeek.app
      echo "Installed and launched /Applications/Portpeek.app"
      for dir in /usr/local/bin "$HOME/.local/bin"; do
        if mkdir -p "$dir" 2>/dev/null && ln -sf /Applications/Portpeek.app/Contents/Resources/portpeek-cli "$dir/portpeek" 2>/dev/null; then
          echo "Linked CLI: $dir/portpeek"
          break
        fi
      done ;;
    --open)
      pkill -x Portpeek 2>/dev/null || true
      open "$APP" ;;
    --dmg)
      STAGE="$(mktemp -d)"
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      DMG="build/Portpeek-$VERSION.dmg"
      rm -f "$DMG"
      hdiutil create -volname Portpeek -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
      rm -rf "$STAGE"
      echo "Wrote $DMG" ;;
  esac
done
