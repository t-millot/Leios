// ButtonCaptureZone.swift
// Leios — a drop zone that adds a mouse button by having the user press it.

import SwiftUI
import AppKit
import LeiosShared

/// Outcome of a press inside the capture zone, shown as transient feedback.
enum ButtonCaptureResult: Equatable {
    /// The button is new and was added to the config.
    case added(Int)
    /// The button already has a section in the list.
    case alreadyMapped(Int)
    /// The left or right button was pressed; those keep their system behavior.
    case primaryButton
    /// The button number is outside the range Leios can remap.
    case outOfRange(Int)

    /// Classifies a captured press. Pure counterpart of `ButtonsSettingsView.capture(_:)`, which
    /// applies the config change this describes.
    static func classify(button: Int, isAlreadyMapped: Bool) -> ButtonCaptureResult {
        guard button >= LeiosConstants.minButton, button <= LeiosConstants.maxButton else {
            return button < LeiosConstants.minButton ? .primaryButton : .outOfRange(button)
        }
        return isAlreadyMapped ? .alreadyMapped(button) : .added(button)
    }
}

struct ButtonCaptureZone: View {
    /// Called with the Leios button number (middle button is 3) of every press inside the zone.
    let onCapture: @MainActor (Int) -> ButtonCaptureResult
    /// Arms the helper to swallow and report one press. Suspends until a button is pressed or the wait expires.
    let armHelper: @MainActor (TimeInterval) async -> ButtonCaptureOutcome
    /// Disarms the helper when the pointer leaves the zone.
    let disarmHelper: @MainActor () -> Void

    /// How long one armed capture lasts before it is renewed.
    private static let armDuration: TimeInterval = 60

    @Environment(\.controlActiveState) private var controlActiveState

    @State private var isHovering = false
    @State private var isPressed = false
    @State private var result: ButtonCaptureResult?
    @State private var resetTask: Task<Void, Never>?
    @State private var armTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(fillColor)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(strokeColor, style: StrokeStyle(lineWidth: 1.5, dash: result == nil ? [6, 4] : []))
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 22))
                    .foregroundStyle(tintColor)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(result == nil ? Color.primary : tintColor)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 74)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            ButtonCaptureCatcher(
                onButton: { handle(onCapture($0)) },
                onPrimaryButton: { handle(.primaryButton) },
                onPressedChange: { isPressed = $0 },
                onHoverChange: { hovering in
                    isHovering = hovering
                    setArmed(hovering && controlActiveState == .key)
                })
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .animation(.easeOut(duration: 0.15), value: result)
        .accessibilityElement()
        .accessibilityLabel("Add a button")
        .accessibilityValue(title)
        // Never keep swallowing clicks once the window stops being the one the user is working in.
        .onChange(of: controlActiveState) { _, state in
            if state != .key { isHovering = false; isPressed = false }
            setArmed(isHovering && state == .key)
        }
        .onDisappear {
            resetTask?.cancel()
            setArmed(false)
        }
    }

    // MARK: Helper capture

    /// While armed, the helper reports the next press over XPC — that is the only way to see a
    /// button whose assignment makes the engine swallow it before the app ever gets the event.
    private func setArmed(_ armed: Bool) {
        guard armed else {
            armTask?.cancel()
            armTask = nil
            disarmHelper()
            return
        }
        guard armTask == nil else { return }
        armTask = Task { @MainActor in
            while !Task.isCancelled {
                switch await armHelper(Self.armDuration) {
                case .captured(let button):
                    guard !Task.isCancelled else { return }
                    handle(onCapture(button))
                case .timedOut:
                    continue
                case .unavailable:
                    return // The in-app catcher still handles buttons that aren't mapped yet.
                }
            }
        }
    }

    // MARK: Feedback

    private func handle(_ newResult: ButtonCaptureResult) {
        result = newResult
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            result = nil
        }
    }

    private var title: String {
        switch result {
        case .added(let button): return "Added \(MouseButtonNaming.name(button))."
        case .alreadyMapped(let button): return "\(MouseButtonNaming.name(button)) is already in the list."
        case .primaryButton: return "The left and right buttons can't be remapped."
        case .outOfRange(let button): return "Button \(button) is out of range."
        case nil: return "Click a button on your mouse here to add it"
        }
    }

    private var subtitle: String {
        switch result {
        case .added: return "Set what it should do above."
        case .alreadyMapped: return "Scroll up to change what it does."
        case .primaryButton: return "Use the middle button or any extra button instead."
        case .outOfRange: return "Leios supports buttons \(LeiosConstants.minButton) through \(LeiosConstants.maxButton)."
        case nil: return "Point here, then press the middle button or one of your mouse's extra buttons."
        }
    }

    private var symbolName: String {
        switch result {
        case .added: return "checkmark.circle.fill"
        case .alreadyMapped: return "info.circle.fill"
        case .primaryButton, .outOfRange: return "exclamationmark.triangle.fill"
        case nil: return "computermouse.fill"
        }
    }

    private var tintColor: Color {
        switch result {
        case .added: return .green
        case .alreadyMapped: return .accentColor
        case .primaryButton, .outOfRange: return .orange
        case nil: return isHovering ? .accentColor : .secondary
        }
    }

    private var strokeColor: Color {
        result == nil ? tintColor.opacity(isHovering ? 0.8 : 0.35) : tintColor.opacity(0.8)
    }

    private var fillColor: Color {
        let base = result == nil ? Color.accentColor : tintColor
        return base.opacity(isPressed ? 0.18 : (isHovering || result != nil) ? 0.09 : 0.04)
    }
}

/// Transparent AppKit layer that catches mouse-button presses landing inside the zone.
/// SwiftUI gestures only see the left button, so the extra buttons have to come from an `NSView`.
/// Presses are consumed here: a button that is not mapped yet reaches the app untouched by the
/// helper's event tap, which only swallows buttons that already have an assignment.
private struct ButtonCaptureCatcher: NSViewRepresentable {
    let onButton: @MainActor (Int) -> Void
    let onPrimaryButton: @MainActor () -> Void
    let onPressedChange: @MainActor (Bool) -> Void
    let onHoverChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: CatcherView) {
        view.onButton = onButton
        view.onPrimaryButton = onPrimaryButton
        view.onPressedChange = onPressedChange
        view.onHoverChange = onHoverChange
    }

    final class CatcherView: NSView {
        var onButton: (@MainActor (Int) -> Void)?
        var onPrimaryButton: (@MainActor () -> Void)?
        var onPressedChange: (@MainActor (Bool) -> Void)?
        var onHoverChange: (@MainActor (Bool) -> Void)?

        private var trackingArea: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
            onPressedChange?(false)
        }

        // `buttonNumber` is zero-based (middle button is 2); Leios counts from one.
        override func otherMouseDown(with event: NSEvent) {
            onPressedChange?(true)
            onButton?(event.buttonNumber + 1)
        }

        override func otherMouseUp(with event: NSEvent) { onPressedChange?(false) }

        override func otherMouseDragged(with event: NSEvent) {}

        override func mouseDown(with event: NSEvent) {
            onPressedChange?(true)
            onPrimaryButton?()
        }

        override func mouseUp(with event: NSEvent) { onPressedChange?(false) }

        override func rightMouseDown(with event: NSEvent) { onPrimaryButton?() }

        override func rightMouseUp(with event: NSEvent) {}
    }
}

enum MouseButtonNaming {
    // nonisolated: HIDUsageNaming names button usages with it, off the main actor.
    nonisolated static func name(_ button: Int) -> String {
        switch button {
        case 1: return "Left Button"
        case 2: return "Right Button"
        case 3: return "Middle Button (3)"
        default: return "Button \(button)"
        }
    }
}
