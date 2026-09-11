# Lenscap

**Open-source screenshot and screen-recording app for macOS, with local saving and a personal cloud library. No analytics.**

Lenscap lives in your menu bar and captures your screen with ScreenCaptureKit. Captures go to a local folder and/or your clipboard, and history is a local JSON index. Connecting your own Neon backend enables automatic private uploads of every new screenshot, finalized video, and GIF. Without a cloud connection, capture data stays local. Sparkle checks this repo's appcast for updates. No analytics or telemetry.

> **Screenshots + demo GIF** (area-capture overlay, annotation editor, history browser, quick-access overlay) — being added as part of the release pass. See *Known limitations*.

## Install

**Lenscap 1.1.2** is the first public release that includes the personal cloud. Cloud features are strictly opt-in and bring-your-own-backend: the app ships with no hosted service, no Neon account, and no API key. To use them, deploy the open-source function in `Cloud/` to your own Neon project and import the connection file it generates; see [personal cloud setup](docs/personal-cloud.md). Without that, nothing leaves your Mac except Sparkle update checks.

**Download the DMG** from the [latest release](https://github.com/rutmehta/Lenscap/releases/latest) — mount it and drag **Lenscap.app** into `/Applications`.

Or build the native app from source (a Swift Package with Sparkle resolved by Swift Package Manager):

```sh
git clone https://github.com/rutmehta/Lenscap.git
cd Lenscap
bash Scripts/make-app.sh        # produces dist/Lenscap.app and a versioned DMG
```

> **First launch:** release DMGs are ad-hoc signed (not yet notarized), so the first time macOS will ask you to **right-click → Open** the app. This is called out honestly under *Known limitations* — it goes away once notarization is configured.

## Features

- **Area capture** — full-screen dimming overlay with crosshair drag-to-select across every display; press ⏎ during selection to grab the whole screen.
- **Window capture** — interactive picker: every display dims, the window under the cursor is hover-highlighted with its app name and title, click to capture, ⎋ to cancel.
- **Fullscreen capture** — grab the entire display under the cursor.
- **Timed capture** — optional countdown delay (off / 3 / 5 / 10 s) before area, window, and fullscreen captures.
- **Capture Text (OCR)** — select an area and the recognized text (Vision framework, accurate mode) lands on your clipboard.
- **Scrolling capture** *(experimental)* — select a scrollable area, capture steps manually or let auto-scroll drive it (synthesized scroll events with bottom detection), and the frames are stitched into one tall image via overlap matching (capped at 40 frames / 20,000 px).
- **Screen recording** — record an area or the full screen to H.264 MP4 with optional system audio, configurable FPS, a 3-2-1 countdown, and a floating recording HUD; Lenscap's own windows are excluded from the capture. Videos preserve their aspect ratio within a 4K envelope (3840 × 2160, or portrait equivalent) and are optimized for playback over a network.
- **GIF recording** — same flow with GIF output (30 s cap, longest side capped at 960 px).
- **Annotation editor** — arrows, lines, rectangles, ellipses, pen, highlighter, text, counter badges, blur/pixelate, and crop, plus a background tool (padding, rounded corners, shadow, gradient backdrops), undo/redo, color and stroke controls, Copy/Save/Save As, and drag-out.
- **Pin to screen** — float any capture (or the clipboard image) as an always-on-top panel; drag to move, double-click to close.
- **Quick access overlay** — post-capture thumbnail with quick actions (annotate, copy, save/reveal, pin, trash), drag-out to other apps, double-click to open, and a hover-aware auto-dismiss timer with configurable duration.
- **History browser** — dedicated window with a thumbnail grid (QuickLook previews), an All/Screenshots/Recordings filter, and per-item actions, over a local index of your last 300 captures.
- **Personal cloud** — automatic uploads of all new normal screenshots, videos, GIFs, and explicitly saved image edits; a private cloud library; explicit share links; and visible usage and upload failures. Uploads queue locally and resume after a restart; existing history is not backfilled. Requires your own Neon project; see [personal cloud setup](docs/personal-cloud.md).
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

## Open Settings and Cloud Library

Click the Lenscap menu-bar icon normally to open its native menu. Choose **Settings…**, **Check for Updates…**, **Cloud Library**, or a capture command directly.

If the icon is hidden, reopen **Lenscap** from Applications or Spotlight. When no Lenscap windows are visible, this shows the capture-controls window titled **Lenscap**; choose its **Settings** button, then **Cloud → Open Cloud Library…**. Reopening does not automatically open Settings, and it does not replace an already-visible window. The library's **New Capture** menu starts screenshots and recordings.

Starting a capture hides Settings and the capture controls before activating the capture UI. These windows do not automatically reappear after capture; open them explicitly when needed.

Connecting a personal cloud enables automatic uploads of new captures and explicitly saved edits; it does not upload old history. Neon's Free Object Storage allowance is **5 GB shared across the account**, not 5 GB per project. Lenscap never upgrades the plan automatically. See the [verification record and limitations](docs/personal-cloud.md#verified-private-build) before relying on the cloud as your only copy.

## Auto-updates

Lenscap uses **[Sparkle](https://sparkle-project.org)** for updates. On first launch it asks whether you'd like to be checked for updates automatically. Click the menu-bar icon and choose **Check for Updates…**, or explicitly open **Settings → About → Check for Updates…**. If the icon is hidden, use the capture-controls window's **Settings** button as described above. The feed lives at [appcast.xml](appcast.xml) and is served from this GitHub repo (no CDN, no third-party tracking).

A release is produced by:

```sh
# 1. Set the signing seed (private; never committed) and pick a version.
export LENSCAP_EDDSA_KEY_FILE="$HOME/.lenscap-dist-keys/sparkle_seed.b64"
export PRODUCT_VERSION=1.1.2
export SPARKLE_BIN_DIR="$PWD/.build/artifacts/sparkle/Sparkle/bin"
# 2. Build the DMG, sign it, update + re-sign appcast.xml.
Scripts/release-update.sh
# 3. Commit the source, version metadata, and signed appcast; push the version tag.
# 4. Publish the GitHub release and attach the DMG before pushing main, so the
#    live feed never advertises a download that is not available yet.
#    The script does not push or publish on its own.
```

Signing keys, the appcast format, and the release flow are documented in
[`Scripts/release-update.sh`](Scripts/release-update.sh) and
[`Config/branding.sh`](Config/branding.sh).

> **Historical version 1.0.2:** Settings became accessible by reopening Lenscap,
> and **Check for Updates…** was added to its About tab. It included the 1.0.1 fix
> for duplicate clipboard items when copying a saved capture. The 1.1.x changes
> replace automatic Settings opening with the explicit controls described above.
> Existing Sparkle-enabled installations can update through the same feed and
> signing key. Each release must use a higher version number, and the appcast
> must be re-signed after changes.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ / Swift 5.9 toolchain to build from source

## Permissions

| Permission | Needed for | Required? |
|---|---|---|
| **Screen Recording** | All captures and recordings (ScreenCaptureKit) | Yes — grant in System Settings → Privacy & Security → Screen Recording |
| **Accessibility** | Auto-scroll during scrolling capture | Optional (only for scrolling capture) |

Lenscap does not request contacts or location access. Network access is used for optional Sparkle update checks and downloads, and for uploads and library requests when a personal Neon cloud is connected. Opening or sharing a cloud capture uses a signed storage URL. There is no analytics or telemetry.

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
├── Support/                          # Settings store, hotkeys, HUD toast, image writer
├── Support/ScreenCapturePermissionProvider.swift  # Live CGPreflight/CGRequest wrapper
├── Support/ScreenCapturePermissionPresenter.swift # Durable "grant access" permission panel
└── ../LenscapPermission/             # Testable permission controller + provider protocol
```

## FAQ

**What gets uploaded?**
After connecting a personal cloud, all new screenshots, finalized recordings, and explicitly saved image edits upload automatically. Cloud uploads also work when automatic local screenshot saving is off. Existing files are not scanned or backfilled; OCR-only selections, clipboard copies, and temporary drag files do not create cloud entries. The bucket remains private: **Open** creates a short-lived read URL, while **Copy Share Link** creates a seven-day read URL. Anyone holding either URL can access that capture while the link remains valid. Saving an edit creates a separate cloud version; it does not redact or replace an earlier upload. There is no analytics or telemetry.

**Where is the cloud connection stored?**
The personal device credential is stored in the macOS login Keychain. The app never receives Neon account, database, or S3 credentials. Queued payloads and receipts live in `~/Library/Application Support/Lenscap/Cloud/`; successful uploads release their temporary payloads, while failures remain available for retry. Neon Storage and Functions are in public beta, so keep local copies. The app never upgrades your Neon plan automatically.

**Where do my captures go?**
`~/Pictures/Lenscap` by default (configurable), and optionally the clipboard. History metadata lives in `~/Library/Application Support/Lenscap/history.json`.

**Why does macOS ask for Screen Recording permission?**
ScreenCaptureKit requires it for any capture — even stills. Lenscap gates every capture/recording on a live `CGPreflightScreenCaptureAccess()` check. If access is missing, it shows a durable panel offering **Request Access**, **Open Screen Recording Settings…**, and **Retry** — it never silently captures a black frame, and it never traps you behind a stale "granted" flag. Once you grant access and return to Lenscap (or tap Retry), the pending capture runs automatically. macOS may require you to relaunch the app after a first-time grant.

**Screen Recording permission (manual verification)**
Lenscap re-checks the permission on every capture, so you don't have to relaunch — but a freshly installed build that changed its code signature (e.g. rebuilding from source) may lose the previously granted TCC permission. To confirm/restore it:

1. Open **System Settings → Privacy & Security → Screen Recording**.
2. Make sure **Lenscap** is enabled (toggle on if not), then launch a capture.
3. If macOS doesn't pick up the grant, take the surest path:
   ```sh
   tccutil reset ScreenCapture com.rutmehta.lenscap
   ```
   then relaunch Lenscap and grant access when prompted. This clears any stale TCC row so the next grant is recorded for the current build.
   *(Changing the app's code-signing identity replaces its TCC grant — that's expected until Developer ID notarization is back in place.)*

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: `swift build`, match the existing style. Sparkle (updates) is the only external dependency, added via Swift Package Manager.

## License

[MIT](LICENSE) © 2026 Rut Mehta

---

*Lenscap is an independent open-source project. It is not affiliated with, endorsed by, or associated with MakeTheWeb s.c. CleanShot is a trademark of its respective owner; it is referenced only to describe the category of tool.*
