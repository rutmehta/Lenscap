import AppKit
import LenscapPermission
import ScreenCaptureKit

/// Central hub that wires the menu bar, hotkeys, and capture pipeline together.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    private(set) var statusBar: StatusBarController?
    let settings = SettingsStore.shared
    let history = HistoryStore.shared

    private init() {}

    func start() {
        statusBar = StatusBarController()
        HotkeyManager.shared.registerAll()
    }

    // MARK: - Screen Recording permission gate (single choke point)

    /// Every user-initiated capture funnels through here. Returns `true` to run
    /// the capture; when access is missing it presents the durable permission
    /// panel and returns `false`. Once the user grants access and returns / taps
    /// Retry, the panel calls `retry`, which re-enters the originating action.
    ///
    /// This centralizes the gate instead of patching eight call sites, and it
    /// always re-reads `CGPreflight` (a fresh controller each call) so the old
    /// one-shot-flag trap cannot recur.
    private func beginScreenCapture(retry: @escaping @MainActor () -> Void) -> Bool {
        let controller = ScreenCapturePermissionController(provider: LiveScreenCapturePermissionProvider())
        guard controller.canCapture else {
            ScreenCapturePermissionPresenter.shared.present(pending: {
                Task { @MainActor in retry() }
            })
            return false
        }
        return true
    }

    // MARK: - Still captures

    func captureArea() {
        guard beginScreenCapture(retry: { [weak self] in self?.captureArea() }) else { return }
        SelectionOverlayController.selectRect(prompt: "Drag to select an area") { [weak self] result in
            guard let self, let result else { return }
            self.afterDelay {
                do {
                    let image = try await CaptureEngine.captureRect(result)
                    self.ingest(cgImage: image, kind: .screenshot, scale: result.screen.backingScaleFactor)
                } catch {
                    HUD.show("Capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func captureWindow() {
        guard beginScreenCapture(retry: { [weak self] in self?.captureWindow() }) else { return }
        WindowPickerController.pickWindow { [weak self] window in
            guard let self, let window else { return }
            self.afterDelay {
                do {
                    let image = try await CaptureEngine.captureWindow(window)
                    self.ingest(cgImage: image, kind: .screenshot,
                                scale: CGFloat(image.width) / max(1, window.frame.width))
                } catch {
                    HUD.show("Capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func captureFullscreen() {
        guard beginScreenCapture(retry: { [weak self] in self?.captureFullscreen() }) else { return }
        let screen = NSScreen.underMouse ?? NSScreen.main
        guard let screen else { return }
        afterDelay {
            do {
                let image = try await CaptureEngine.captureFullDisplay(containing: screen)
                self.ingest(cgImage: image, kind: .screenshot, scale: screen.backingScaleFactor)
            } catch {
                HUD.show("Capture failed: \(error.localizedDescription)")
            }
        }
    }

    func captureText() {
        guard beginScreenCapture(retry: { [weak self] in self?.captureText() }) else { return }
        SelectionOverlayController.selectRect(prompt: "Select an area to copy its text") { result in
            guard let result else { return }
            Task { @MainActor in
                do {
                    let image = try await CaptureEngine.captureRect(result)
                    let text = try await OCRService.recognizeText(in: image)
                    if text.isEmpty {
                        HUD.show("No text found", symbol: "text.viewfinder")
                    } else {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        HUD.show("Text copied to clipboard", symbol: "text.viewfinder")
                    }
                } catch {
                    HUD.show("Text recognition failed")
                }
            }
        }
    }

    func startScrollingCapture() {
        guard beginScreenCapture(retry: { [weak self] in self?.startScrollingCapture() }) else { return }
        ScrollingCaptureController.shared.begin()
    }

    // MARK: - Recording

    func toggleRecording(mode: RecordingMode) {
        if ScreenRecorder.shared.isRecording {
            Task { await ScreenRecorder.shared.stopAndSave() }
            return
        }
        guard beginScreenCapture(retry: { [weak self] in self?.toggleRecording(mode: mode) }) else { return }
        SelectionOverlayController.selectRect(prompt: "Select an area to record — press ⏎ for the full screen") { result in
            guard let result else { return }
            Task { @MainActor in
                await ScreenRecorder.shared.start(selection: result, mode: mode)
            }
        }
    }

    func stopRecordingIfNeeded() {
        guard ScreenRecorder.shared.isRecording else { return }
        Task { await ScreenRecorder.shared.stopAndSave() }
    }

    // MARK: - Tools

    func pinFromClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            HUD.show("No image on the clipboard", symbol: "pin")
            return
        }
        PinController.pin(image: image, at: nil)
    }

    func toggleDesktopIcons() {
        DesktopIconsHider.shared.toggle()
        statusBar?.refreshMenuState()
    }

    func openHistory() {
        HistoryWindowController.open()
    }

    func openSettings() {
        SettingsWindowController.open()
    }

    func openEditor(image: NSImage, sourceURL: URL?) {
        AnnotationEditorController.open(image: image, sourceURL: sourceURL)
    }

    // MARK: - Post-capture pipeline

    /// Every still capture funnels through here: save, clipboard, sound, history, quick access.
    /// `scale` is the source display's points → pixels factor (nil when unknown).
    func ingest(cgImage: CGImage, kind: CaptureItem.Kind, scale: CGFloat? = nil) {
        let pointScale = max(1, scale ?? 1)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / pointScale,
                                                           height: CGFloat(cgImage.height) / pointScale))
        var item = CaptureItem(kind: kind, image: image, fileURL: nil)

        if settings.saveToDisk {
            if let url = ImageWriter.save(cgImage: cgImage, scale: scale) {
                item.fileURL = url
                history.add(url: url, kind: kind)
            }
        }
        if settings.copyToClipboard {
            ImageWriter.copyToClipboard(cgImage: cgImage, fileURL: item.fileURL)
        }
        playCaptureSoundIfEnabled()

        if settings.showQuickAccess {
            QuickAccessOverlayController.shared.show(item)
        } else if settings.copyToClipboard && !settings.saveToDisk {
            HUD.show("Copied to clipboard", symbol: "doc.on.clipboard")
        }
    }

    /// Recordings land here once the file is finalized on disk.
    func ingestRecording(url: URL, kind: CaptureItem.Kind, thumbnail: NSImage?) {
        history.add(url: url, kind: kind)
        playCaptureSoundIfEnabled()
        let item = CaptureItem(kind: kind, image: thumbnail ?? NSImage(), fileURL: url)
        if settings.showQuickAccess {
            QuickAccessOverlayController.shared.show(item)
        } else {
            HUD.show("Recording saved", symbol: "record.circle")
        }
    }

    func playCaptureSoundIfEnabled() {
        guard settings.playSound else { return }
        NSSound(named: "Pop")?.play()
    }

    /// Applies the user's capture delay, plus a beat for overlays to fade out of the frame.
    private func afterDelay(_ body: @escaping @MainActor () async -> Void) {
        let delay = max(0.15, Double(settings.captureDelay))
        Task { @MainActor in
            if settings.captureDelay > 0 {
                HUD.show("Capturing in \(settings.captureDelay)s…", symbol: "timer", duration: Double(settings.captureDelay))
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await body()
        }
    }
}
