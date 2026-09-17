// ScreenDrawer.swift
// MousePilot Engine — a transparent overlay window above the cursor level, used for the puppet cursor.
// Ports Helper/Utility/ScreenDrawer.swift. Derived from Mac Mouse Fix, MMF License.

import AppKit
import QuartzCore

@MainActor
final class ScreenDrawer {

    static let shared = ScreenDrawer()

    private var canvas: NSWindow

    private init() {
        canvas = Canvas(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false, screen: nil)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alphaValue = 1.0
        canvas.level = NSWindow.Level(Int(CGWindowLevelForKey(.cursorWindow)) + 1)
        canvas.ignoresMouseEvents = true
        canvas.acceptsMouseMovedEvents = false
        canvas.collectionBehavior = [.stationary, .moveToActiveSpace]
        canvas.contentView = CanvasContent()
        canvas.disableCursorRects()
        canvas.isReleasedWhenClosed = false
        canvas.contentView?.autoresizesSubviews = false
    }

    func draw(view: NSView, atFrame frameInScreen: NSRect, onScreen screen: NSScreen) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.autoresizingMask = []
        CATransaction.begin()
        canvas.setFrame(screen.frame, display: false)
        view.frame = canvas.convertFromScreen(frameInScreen)
        view.wantsLayer = true
        view.layer?.setAffineTransform(.identity)
        canvas.contentView?.addSubview(view)
        canvas.orderFront(nil)
        CATransaction.commit()
    }

    func move(view: NSView, toOrigin newOrigin: NSPoint) {
        guard view.superview === canvas.contentView else { return }
        let origin = canvas.convertPoint(fromScreen: newOrigin)
        view.wantsLayer = true
        let current = view.frame.origin
        view.layer?.setAffineTransform(CGAffineTransform(translationX: origin.x - current.x, y: origin.y - current.y))
    }

    func undraw(view: NSView) {
        if view.superview === canvas.contentView {
            view.removeFromSuperview()
        }
        canvas.close()
    }
}

private final class CanvasContent: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {}
    override func layoutSubtreeIfNeeded() {}
    override func updateConstraintsForSubtreeIfNeeded() {}
    override var needsLayout: Bool { get { false } set {} }
    override var needsUpdateConstraints: Bool { get { false } set {} }
    override class var requiresConstraintBasedLayout: Bool { false }
}

private final class Canvas: NSWindow {
    /// Ignoring all events cuts CPU usage in half during drags with high-report-rate mice.
    override func sendEvent(_ event: NSEvent) {}
}
