#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
xcodebuild -project FocusApp.xcodeproj -scheme FocusApp \
    -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath DerivedData ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build -quiet >&2

app="$PWD/DerivedData/Build/Products/Release/FocusApp.app"
codesign --verify --strict "$app"
architectures="$(xcrun lipo -archs "$app/Contents/MacOS/FocusApp")"
if [[ " $architectures " != *' arm64 '* || " $architectures " != *' x86_64 '* ]]; then
    printf 'Se esperaba un binario universal, obtenido: %s\n' "$architectures" >&2
    exit 1
fi
printf '%s\n' "$app"
