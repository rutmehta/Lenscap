# Lenscap

**Open-source, 100% local screenshot & screen-recording app for macOS — a CleanShot X-style tool with no cloud, no accounts, no analytics.**

Lenscap lives in your menu bar and captures your screen with ScreenCaptureKit. Everything happens on your Mac: captures go to a local folder and/or your clipboard, history is a local JSON index, and the app never phones home — the *only* network traffic is an optional Sparkle update check against this repo's appcast (see **Auto-updates**). No analytics, no telemetry, no accounts.

> **Screenshots + demo GIF** (area-capture overlay, annotation editor, history browser, quick-access overlay) — being added as part of the release pass. See *Known limitations*.

## Install

**Download the DMG** from the [latest release](https://github.com/rutmehta/Lenscap/releases/latest) — mount it and drag **Lenscap.app** into `/Applications`.

Or build from source (no dependencies — a single Swift Package):

```sh
git clone https://github.com/rutmehta/Lenscap.git
cd Lenscap
bash Scripts/make-app.sh        # produces dist/Lenscap.app + dist/Lenscap-1.0.0.dmg
```

> **First launch:** release DMGs are ad-hoc signed (not yet notarized), so the first time macOS will ask you to **right-click → Open** the app. This is called out honestly under *Known limitations* — it goes away once notarization is configured.

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

## Known limitations

Being honest about the rough edges before you send this to a subreddit:

- **Scrolling capture is experimental.** Auto-scroll relies on synthesized scroll events plus overlap matching for stitching, and is capped at 40 frames / 20,000 px. It works, but can produce imperfect seams on complex or nested-scroll pages. Treat it as a preview feature.
- **Apple Silicon only (arm64).** The prebuilt DMG is a thin arm64 binary — it runs on Apple Silicon Macs (M1+), not on Intel Macs. A universal (x86_64 + arm64) build can be produced from source if there's demand.
- **Not notarized (with signed, working notarization support).** `Scripts/make-app.sh` can sign with a real identity and notarize+staple the DMG when a Developer ID certificate and `xcrun notarytool` credentials are configured. Until then releases are ad-hoc signed, so fresh Macs show a Gatekeeper warning and need right-click → Open. This is the one thing that needs an Apple Developer account + credentials on the build machine.
- **GIF recording** is soft-capped at 30 s and 960 px longest side to keep file sizes sane.

## Auto-updates

Lenscap uses **[Sparkle](https://sparkle-project.org)** for updates. On first launch it asks whether you'd like to be checked for updates automatically; you can also trigger a check any time from the menu bar via **Check for Updates…** (⌘U). The feed lives at [appcast.xml](appcast.xml) and is served from this GitHub repo (no CDN, no third-party tracking).

A release is produced by:

```sh
# 1. Set the signing seed (private; never committed) and pick a version.
export LENSCAP_EDDSA_KEY_FILE="$HOME/.lenscap-dist-keys/sparkle_seed.b64"
export PRODUCT_VERSION=1.1.0
# 2. Build the DMG, sign it, update + re-sign appcast.xml.
Scripts/release-update.sh
# 3. Manually tag + create the GitHub release and attach the DMG (see the
#    script's printed next-steps; it does not push or publish on its own).
```

Signing keys, the appcast format, and the release flow are documented in
[`Scripts/release-update.sh`](Scripts/release-update.sh) and
[`Config/branding.sh`](Config/branding.sh).

> The app is currently **version 1.0.0** with no newer release published, so
> update checks report "up to date". When you're ready to ship, run the flow
> above rather than hand-editing `appcast.xml` — it must be re-signed after any
> change or Sparkle will reject it.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ / Swift 5.9 toolchain to build from source

## Permissions

| Permission | Needed for | Required? |
|---|---|---|
| **Screen Recording** | All captures and recordings (ScreenCaptureKit) | Yes — grant in System Settings → Privacy & Security → Screen Recording |
| **Accessibility** | Auto-scroll during scrolling capture | Optional (only for scrolling capture) |

Lenscap never asks for contacts, location, or anything invasive. The only network access is the optional Sparkle update check against this repo (a single GET to the appcast — no analytics, no telemetry, nothing else phone-home).

## Default shortcuts

Defaults mirror the classic macOS / CleanShot X layout:

| Action | Shortcut |
|---|---|
| Capture Fullscreen | ⌘⇧3 |
| Capture Area | ⌘⇧4 |
| Record Video | ⌘⇧5 |
| Capture Window | ⌘⇧6 |
| Scrolling Capture | ⌘⇧7 |
| Capture Text (OCR) | ⌘⇧2 |
| Record GIF | — (unassigned) |
| Open History | — (unassigned) |

All shortcuts are system-wide and can be changed or disabled in Settings.

> **Note**: macOS's built-in screenshot shortcuts use the same keys. Disable them in
> **System Settings → Keyboard → Keyboard Shortcuts… → Screenshots** so both don't fire
> at once (this is the same step CleanShot X asks for).

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
By design. Screenshots often contain sensitive information; Lenscap keeps everything on your Mac. There are no accounts, no uploads, no analytics. The only network request in the entire app is the optional Sparkle update check against this repo's appcast (toggleable — see Auto-updates).

**Where do my captures go?**
`~/Pictures/Lenscap` by default (configurable), and optionally the clipboard. History metadata lives in `~/Library/Application Support/Lenscap/history.json`.

**Why does macOS ask for Screen Recording permission?**
ScreenCaptureKit requires it for any capture — even stills. macOS may require you to relaunch the app after granting it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: `swift build`, match the existing style. Sparkle (updates) is the only external dependency, added via Swift Package Manager.

## License

[MIT](LICENSE) © 2026 Rut Mehta

---

*Lenscap is an independent open-source project. It is not affiliated with, endorsed by, or associated with MakeTheWeb s.c. CleanShot is a trademark of its respective owner; it is referenced only to describe the category of tool.*
