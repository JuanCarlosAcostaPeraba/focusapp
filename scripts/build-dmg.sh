#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && $1 != --notarize ) ]]; then
    printf 'Uso: %s [--notarize]\n' "$0" >&2
    exit 2
fi

notarize="${1:-}"
if [[ "$notarize" == --notarize ]]; then
    identity="${FOCUSAPP_SIGN_IDENTITY:-}"
    profile="${FOCUSAPP_NOTARY_PROFILE:-}"
    if [[ "$identity" != 'Developer ID Application: '* || -z "$profile" ]]; then
        printf '%s\n' 'Configura FOCUSAPP_SIGN_IDENTITY (Developer ID Application) y FOCUSAPP_NOTARY_PROFILE.' >&2
        exit 2
    fi
    if ! security find-identity -v -p codesigning | /usr/bin/grep -F "\"$identity\"" >/dev/null; then
        printf '%s\n' 'La identidad Developer ID y su clave privada deben estar en el llavero.' >&2
        exit 2
    fi
fi

app="$(./scripts/build-app.sh)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
if [[ -n "${FOCUSAPP_RELEASE_TAG:-}" && "$FOCUSAPP_RELEASE_TAG" != "v$version" ]]; then
    printf 'La etiqueta %s debe coincidir con la versión v%s.\n' "$FOCUSAPP_RELEASE_TAG" "$version" >&2
    exit 2
fi

mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.dmg-build.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

if [[ "$notarize" == --notarize ]]; then
    ditto "$app" "$staging/FocusApp.app"
    app="$staging/FocusApp.app"
    codesign --force --sign "$identity" --options runtime --timestamp "$app"
    codesign --verify --strict "$app"
fi

image="$staging/FocusApp.dmg"
uvx --from 'dmgbuild==2.0.0' dmgbuild -s scripts/dmg-layout.py \
    -D "app=$app" -D "assets=$PWD/scripts/assets" FocusApp "$image"

if [[ "$notarize" == --notarize ]]; then
    codesign --sign "$identity" --timestamp "$image"
    result="$staging/notarization.plist"
    xcrun notarytool submit "$image" --keychain-profile "$profile" --wait --output-format plist > "$result"
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print status' "$result")" != 'Accepted' ]]; then
        cat "$result" >&2
        exit 1
    fi
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    codesign --verify --strict "$image"
fi

hdiutil verify "$image"
mv -f "$image" dist/FocusApp.dmg
(cd dist && shasum -a 256 FocusApp.dmg > FocusApp.dmg.sha256)
printf '%s\n' "$PWD/dist/FocusApp.dmg"
