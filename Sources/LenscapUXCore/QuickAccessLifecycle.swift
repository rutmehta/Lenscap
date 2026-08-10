import Foundation

/// The timing and completion state machine for the post-capture quick-access UI.
///
/// This type deliberately has no AppKit dependency. Keeping the lifecycle separate
/// from panels, drag sessions, and Tasks makes the tricky replacement/hover races
/// executable in unit tests with a deterministic clock.
public final class QuickAccessLifecycle {
    public enum Visibility: Equatable {
        case hidden
        case visible
        case hovered
        case dragging
    }

    public enum DragOutcome {
        case cancelled
        case succeeded
    }

    private let now: () -> TimeInterval
    private var startedAt: TimeInterval?
    private var remaining: TimeInterval = 0
    private var currentID: Int?

    public private(set) var visibility: Visibility = .hidden

    public init(now: @escaping () -> TimeInterval) {
        self.now = now
    }

    /// Shows a new capture and invalidates every event belonging to the old one.
    @discardableResult
    public func show(id: Int, duration: TimeInterval) -> Bool {
        currentID = id
        remaining = max(0, duration)
        startedAt = now()
        visibility = .visible
        return true
    }

    public var currentCaptureID: Int? { currentID }

    public func remainingTime(for id: Int) -> TimeInterval? {
        guard currentID == id, visibility != .hidden else { return nil }
        return liveRemaining()
    }

    /// Returns the exact remaining duration after the transition, or nil for stale events.
    @discardableResult
    public func hoverChanged(for id: Int, inside: Bool) -> TimeInterval? {
        guard currentID == id, visibility != .dragging else { return nil }
        if inside {
            guard visibility == .visible else { return remainingTime(for: id) }
            remaining = liveRemaining()
            startedAt = nil
            visibility = .hovered
        } else {
            guard visibility == .hovered else { return remainingTime(for: id) }
            startedAt = now()
            visibility = .visible
        }
        return remaining
    }

    /// Pauses the timeout while an external drag is in flight.
    @discardableResult
    public func beginDrag(for id: Int) -> Bool {
        guard currentID == id, visibility != .hidden else { return false }
        if visibility == .visible {
            remaining = liveRemaining()
        }
        startedAt = nil
        visibility = .dragging
        return true
    }

    /// A successful drop dismisses. Cancellation returns to the visible state with
    /// the exact pre-drag remainder intact.
    @discardableResult
    public func finishDrag(for id: Int, outcome: DragOutcome) -> Bool {
        guard currentID == id, visibility == .dragging else { return false }
        switch outcome {
        case .succeeded:
            hideCurrent()
            return true
        case .cancelled:
            startedAt = now()
            visibility = .visible
            return false
        }
    }

    /// Called by the timeout Task. A stale timer, hover, or drag cannot dismiss a
    /// replacement capture because it must present the current capture's ID.
    @discardableResult
    public func timerFired(for id: Int) -> Bool {
        guard currentID == id, visibility == .visible else { return false }
        guard liveRemaining() <= 0 else { return false }
        hideCurrent()
        return true
    }

    @discardableResult
    public func copySucceeded(for id: Int) -> Bool {
        guard currentID == id, visibility != .hidden else { return false }
        hideCurrent()
        return true
    }

    @discardableResult
    public func dismiss(for id: Int) -> Bool {
        guard currentID == id, visibility != .hidden else { return false }
        hideCurrent()
        return true
    }

    private func liveRemaining() -> TimeInterval {
        guard let startedAt else { return remaining }
        return max(0, remaining - (now() - startedAt))
    }

    private func hideCurrent() {
        currentID = nil
        startedAt = nil
        remaining = 0
        visibility = .hidden
    }
}