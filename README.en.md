# FocusApp

FocusApp is a free macOS menu bar app that keeps the windows you use sharp and blurs the background live, without screen capture.

[Download FocusApp.dmg](https://github.com/JuanCarlosAcostaPeraba/focusapp/releases/latest/download/FocusApp.dmg) · [Release notes](https://github.com/JuanCarlosAcostaPeraba/focusapp/releases/latest) · [Español](README.md)

## Install

FocusApp requires **macOS 14 or later**. The universal installer includes Apple Silicon and Intel builds.

1. Open the downloaded DMG and drag **FocusApp** into **Applications**.
2. Open it from Applications and click the viewfinder icon in the menu bar.
3. Choose **Activar desenfoque** to start. The interface is in Spanish.

The public build is ad hoc signed and unnotarized. If macOS blocks the first launch and you trust the download, close the alert and look for **Open Anyway** in **System Settings → Privacy & Security**. You can also build the app from source. [Apple’s guide](https://support.apple.com/en-us/102445)

## Customize

- Keep the active window or all visible windows of the active app sharp.
- Blur one display or all displays, with optional blur for Stage Manager thumbnails.
- Adjust blur, monochrome, grain and tint or use an appearance preset.
- Set a global keyboard shortcut or shake the pointer to toggle the effect.
- Exclude individual apps or group apps so they stay sharp together. Teleprompter is excluded by default.

Preferences are stored locally. The app uses window metadata and does not request Screen Recording or Accessibility permission. When the Core Animation filters are unavailable or **Reduce transparency** is enabled, it falls back to the AppKit material, where monochrome is unavailable.

## Updates

FocusApp checks GitHub for a stable release at startup and daily while it is running. A dot appears on the menu bar icon when a newer version is available. Open **Ajustes → Actualizaciones** to check manually or choose **Descargar DMG** to download and open a verified installer. Quit FocusApp and drag the new app into Applications to replace the previous version.

## Build

Select Xcode 26 or later and run these commands from the repository root:

```sh
./scripts/build-app.sh
open DerivedData/Build/Products/Release/FocusApp.app
```

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) and run `./scripts/build-dmg.sh` to create the installer and SHA-256 checksum in `dist/`. See the [release guide](docs/releasing.md).
