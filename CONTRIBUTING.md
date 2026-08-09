# Contributing to Lenscap

Thanks for your interest in contributing!

## Building

Lenscap is a plain Swift Package (swift-tools 5.9), macOS 14+:

```sh
swift build            # debug
swift build -c release # release
swift run Lenscap      # run from the command line
bash Scripts/make-app.sh  # assemble dist/Lenscap.app
```

You can also open `Package.swift` directly in Xcode.

## Code style

- Match the existing code: 4-space indentation, `// MARK: -` sections, doc
  comments only where behavior is non-obvious.
- `@MainActor` on classes that touch AppKit/UI.
- **One external dependency: Sparkle** (for auto-updates), pulled in via Swift
  Package Manager. Everything else is AppKit/SwiftUI plus system frameworks
  (ScreenCaptureKit, AVFoundation, Vision, Carbon hotkeys).
- Lenscap runs as a non-bundled executable during development: never use
  `UNUserNotificationCenter`; use the existing `HUD` for user feedback.
- Everything stays local — the only network traffic is the optional Sparkle
  update check (no analytics, telemetry, or other phone-home code of any kind
  will be accepted).

## Pull requests

- Keep PRs focused on one change; small PRs get reviewed faster.
- Describe what changed and why, and how you tested it (which capture modes,
  single vs. multiple displays, Retina vs. non-Retina if relevant).
- Make sure `swift build -c release` succeeds with no new warnings.
- For larger features, open an issue first so we can discuss the approach.
