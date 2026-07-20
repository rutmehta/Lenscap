# Lenscap

**Open-source, 100% local screenshot & screen-recording app for macOS — a CleanShot X-style tool with no cloud, no accounts, no analytics.**

Lenscap lives in your menu bar and captures your screen with ScreenCaptureKit. Everything happens on your Mac: captures go to a local folder and/or your clipboard, history is a local JSON index, and the app never touches the network.

> **Screenshots coming soon.**

## Features

- **Area capture** — full-screen dimming overlay with crosshair drag-to-select across every display; press ⏎ during selection to grab the whole screen.
- **Window capture** — capture a single window (currently grabs the window under the cursor; a hover-highlight picker is in progress).
- **Fullscreen capture** — grab the entire display under the cursor.
- **Timed capture** — optional 0–10 s countdown delay before any still capture.
- **Capture Text (OCR)** — select an area and the recognized text (Vision framework, accurate mode) lands on your clipboard.
- **Scrolling capture** *(experimental)* — stitch a scrolling area into one tall image. Currently a stub: the menu item exists but stitching is not implemented yet.
- **Screen recording** *(in progress)* — record an area or the full screen to MP4 with optional system audio and configurable FPS. Selection flow and settings are wired; the SCStream/AVAssetWriter encoder is landing.
- **GIF recording** *(in progress)* — same flow, GIF output.
- **Annotation editor** — opens captures in an editor window. The full tool set (arrows, shapes, text, highlight, blur/pixelate, crop, background tool) is in progress; today it opens the capture for viewing.
- **Pin to screen** — float any capture (or the clipboard image) as an always-on-top panel; drag to move, double-click to close.
- **Quick access overlay** *(in progress)* — post-capture thumbnail with quick actions; currently a HUD confirmation.
- **History browser** — local index of your last 300 captures. The dedicated browser window is in progress; today "History" reveals your save folder in Finder.
- **Hide desktop icons** *(in progress)* — declutter the desktop before capturing.
- **Customizable global hotkeys** — every action can be rebound or disabled (persisted per action); the Settings UI for editing them is in progress.
- **Flexible output** — PNG or JPEG, `@2x` Retina naming or downscale-to-1x, custom filename prefix and save folder, clipboard copy, capture sound.

Feature notes above are kept honest against the code: items marked *experimental* or *in progress* are stubbed or partial in the current source.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ / Swift 5.9 toolchain to build from source

## Install / Build

Lenscap has no external dependencies — it is a single Swift Package.

```sh
git clone https://github.com/rutmehta/Lenscap.git
cd Lenscap
swift build -c release
```

To get a proper menu-bar app bundle:

```sh
bash Scripts/make-app.sh
```

This produces `dist/Lenscap.app` (ad-hoc signed). On first launch, right-click the app and choose **Open** since it is not notarized.

## Permissions

| Permission | Needed for | Required? |
|---|---|---|
| **Screen Recording** | All captures and recordings (ScreenCaptureKit) | Yes — grant in System Settings → Privacy & Security → Screen Recording |
| **Accessibility** | Auto-scroll during scrolling capture | Optional (only for scrolling capture) |

Lenscap never asks for network, contacts, or anything else — there is nothing to phone home to.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Capture Area | ⌘⇧7 |
| Capture Window | ⌘⇧8 |
| Capture Fullscreen | ⌘⇧9 |
| Capture Text (OCR) | ⌘⇧2 |
| Scrolling Capture | ⌘⇧6 |
| Record Video | ⌘⇧0 |
| Record GIF | — (unassigned) |
| Open History | — (unassigned) |

All shortcuts are system-wide and can be changed or disabled in Settings.

## Project structure

```
Sources/Lenscap/
├── main.swift, AppDelegate.swift     # Accessory (menu-bar-only) app entry
├── AppCoordinator.swift              # Central hub: wires menus, hotkeys, capture pipeline
├── StatusBarController.swift         # Menu bar icon + menu
├── Capture/
│   ├── SelectionOverlay.swift        # Dimming overlay, crosshair drag-to-select
│   ├── CaptureEngine.swift           # ScreenCaptureKit still captures
│   ├── WindowPicker.swift            # Pick a window to capture
│   ├── OCRService.swift              # Vision text recognition
│   └── ScrollingCapture.swift        # Scrolling capture (experimental)
├── Recording/ScreenRecorder.swift    # MP4 / GIF recording
├── Editor/AnnotationEditor.swift     # Annotation editor window
├── Overlay/
│   ├── QuickAccessOverlay.swift      # Post-capture thumbnail overlay
│   ├── PinController.swift           # Pin image to screen
│   └── DesktopIconsHider.swift       # Hide desktop icons
├── History/                          # Local capture history (JSON index + browser)
├── Settings/SettingsWindow.swift     # Settings UI
├── Models/CaptureItem.swift          # Capture model
└── Support/                          # Settings store, hotkeys, HUD toast, image writer
```

## FAQ

**Why no cloud?**
By design. Screenshots often contain sensitive information; Lenscap keeps everything on your Mac. There are no accounts, no uploads, no analytics, and no network code at all.

**Where do my captures go?**
`~/Pictures/Lenscap` by default (configurable), and optionally the clipboard. History metadata lives in `~/Library/Application Support/Lenscap/history.json`.

**Why does macOS ask for Screen Recording permission?**
ScreenCaptureKit requires it for any capture — even stills. macOS may require you to relaunch the app after granting it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: `swift build`, match the existing style, no external dependencies.

## License

[MIT](LICENSE) © 2026 Rut Mehta

---

*Lenscap is an independent open-source project. It is not affiliated with, endorsed by, or associated with MakeTheWeb s.c. CleanShot is a trademark of its respective owner; it is referenced only to describe the category of tool.*
