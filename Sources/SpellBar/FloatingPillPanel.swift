import AppKit
import SwiftUI

public final class FloatingPillPanel: NSPanel {
    private let hostingView: NSHostingView<SpellBarView>

    public init(state: SpellBarState) {
        self.hostingView = NSHostingView(rootView: SpellBarView(state: state))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 68),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = true

        hostingView.frame = self.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Sizes the panel to fit the SwiftUI view and positions it near `anchorPoint` (AppKit bottom-left screen coordinates).
    public func show(near anchorPoint: NSPoint) {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let width = max(260, fitting.width)
        let height = max(44, fitting.height)

        let screen = NSScreen.screens.first(where: { NSMouseInRect(anchorPoint, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchorPoint.x
        // Prefer placing just below the word; if too close to bottom of screen, place above
        var y = anchorPoint.y - height - 8
        if y < visible.minY + 12 {
            y = anchorPoint.y + 28
        }

        // Clamp within visible screen bounds
        x = max(visible.minX + 12, min(x, visible.maxX - width - 12))
        y = max(visible.minY + 12, min(y, visible.maxY - height - 12))

        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        orderFrontRegardless()
    }
}
