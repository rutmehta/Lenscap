# Lenscap

**Open-source, 100% local screenshot & screen-recording app for macOS — a CleanShot X-style tool with no cloud, no accounts, no analytics.**

Lenscap lives in your menu bar and captures your screen with ScreenCaptureKit. Everything happens on your Mac: captures go to a local folder and/or your clipboard, history is a local JSON index, and the app never touches the network.

> **Screenshots coming soon.**

## Features

- **Area capture** — full-screen dimming overlay with crosshair drag-to-select across every display; press ⏎ during selection to grab the whole screen.
- **Window capture** — interactive picker: every display dims, the window under the cursor is hover-highlighted with its app name and title, click to capture, ⎋ to cancel.
- **Fullscreen capture** — grab the entire display under the cursor.
- **Timed capture** — optional countdown delay (off / 3 / 5 / 10 s) before area, window, and fullscreen captures.
- **Capture Text (OCR)** — select an area and the recognized text (Vision framework, accurate mode) lands on your clipboard.
- **Scrolling capture** *(experimental)* — select a scrollable area, capture steps manually or let auto-scroll drive it (synthesized scroll events with bottom detection), and the frames are stitched into one tall image via overlap matching (capped at 40 frames / 20,000 px).
- **Screen recording** — record an area or the full screen to H.264 MP4 with optional system audio, configurable FPS, a 3-2-1 countdown, and a floating recording HUD; Lenscap's own windows are excluded from the capture.
- **GIF recording** — same flow with GIF output (30 s cap, longest side capped at 960 px).
- **Annotation editor** — arrows, lines, rectangles, ellipses, pen, highlighter, text, counter badges, blur/pixelate, and crop, plus a background tool (padding, rounded corners, shadow, gradient backdrops), undo/redo, color and stroke controls, Copy/Save/Save As, and drag-out.
- **Pin to screen** — float any capture (or the clipboard image) as an always-on-top panel; drag to move, double-click to close.
- **Quick access overlay** — post-capture thumbnail with quick actions (annotate, copy, save/reveal, pin, trash), drag-out to other apps, double-click to open, and a hover-aware auto-dismiss timer with configurable duration.
- **History browser** — dedicated window with a thumbnail grid (QuickLook previews), an All/Screenshots/Recordings filter, and per-item actions, over a local index of your last 300 captures.
- **Hide desktop icons** — declutter the desktop before capturing; toggled from the menu bar with wallpaper-matched cover windows.
- **Customizable global hotkeys** — every action can be rebound or disabled in the Settings Shortcuts tab (persisted per action).
- **Flexible output** — PNG or JPEG, `@2x` Retina naming or downscale-to-1x, custom filename prefix and save folder, clipboard copy, capture sound.

Feature notes above are kept honest against the code: items marked *experimental* work but are still rough around the edges in the current source.

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
