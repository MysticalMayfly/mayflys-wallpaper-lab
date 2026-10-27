import AppKit

/// The lock screen always shows the desktop wallpaper, which is now our aerial. To give the desktop
/// a different picture, the Lab covers the wallpaper with its own borderless window, one per screen,
/// just above the wallpaper and below the desktop icons. The lock screen draws over everything,
/// so the video still plays there.
@MainActor
final class DesktopOverlay {
    static let shared = DesktopOverlay()

    private var windows: [NSWindow] = []
    private var image: NSImage?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopOverlay.shared.rebuild() }
        }
    }

    func show(_ image: NSImage?) {
        self.image = image
        rebuild()
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guard let image else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            windows.append(window)
        }
    }
}
