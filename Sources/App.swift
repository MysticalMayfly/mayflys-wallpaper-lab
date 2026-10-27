import AppKit
import SwiftUI

/// What the desktop shows. The lock screen always plays the video.
enum DesktopMode: String, CaseIterable, Identifiable {
    case still = "Video's first frame"
    case picture = "A picture"
    case system = "macOS default (aerial)"
    var id: String { rawValue }
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    /// The library item that is (or, while it converts, will be) the wallpaper.
    @AppStorage("currentID") var currentID = ""
    @AppStorage("desktopMode") var desktopModeRaw = DesktopMode.still.rawValue
    @AppStorage("desktopPicturePath") var desktopPicturePath = ""
    @AppStorage("keepScreenOn") var keepScreenOn = true { didSet { applyKeepAwake() } }
    @AppStorage("keepScreenOnMinutes") var keepScreenOnMinutes = 2 { didSet { applyKeepAwake() } }
    @AppStorage("rotationInterval") var rotationIntervalRaw = RotationInterval.off.rawValue
    @AppStorage("rotationShuffle") var shuffle = false
    /// When the wallpaper last changed (seconds since 1970); the rotation timer counts from here.
    @AppStorage("lastChange") var lastChange = Date().timeIntervalSince1970
    // LiveLock 1.x played videos straight from a folder; read once to import it into the library.
    @AppStorage("folderPath") private var legacyFolderPath = ""
    @AppStorage("currentName") private var legacyCurrentName = ""

    @Published var status = ""
    private var repairTimer: Timer?
    @Published var openAtLogin = LoginItem.isEnabled

    var current: LibraryItem? { Library.shared.item(currentID) }
    var desktopMode: DesktopMode {
        get { DesktopMode(rawValue: desktopModeRaw) ?? .still }
        set { desktopModeRaw = newValue.rawValue; refreshDesktop() }
    }
    var rotationInterval: RotationInterval {
        get { RotationInterval(rawValue: rotationIntervalRaw) ?? .off }
        set { rotationIntervalRaw = newValue.rawValue; lastChange = Date().timeIntervalSince1970 }
    }

    static let stillFile = Engine.supportDir.appendingPathComponent("desktop-still.png")

    /// Called once at launch.
    func start() {
        let library = Library.shared
        library.onConverted = { item in Model.shared.converted(item) }
        if !library.exists { importLegacyFolder() }
        library.convertPending()
        refreshDesktop()
        applyKeepAwake()
        Rotation.shared.start()
        // macOS replaces the aerial list when Apple publishes a new one; put the Lab's entry back if so
        // (and give an entry from before the rename its new name).
        Engine.repair()
        repairTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Engine.repair() }
    }

    /// First launch of the library version: the old folder's videos become the library, and the old
    /// cache (a different, non-interpolated format) is deleted. They convert again in the background.
    private func importLegacyFolder() {
        try? FileManager.default.removeItem(at: Engine.oldCacheDir)
        guard !legacyFolderPath.isEmpty else { Library.shared.save(); return }
        let imported = Library.shared.add(Engine.videos(in: URL(fileURLWithPath: legacyFolderPath)))
        if let playing = imported.first(where: { ($0.sourcePath as NSString).lastPathComponent == legacyCurrentName }) {
            currentID = playing.id
            Library.shared.priorityID = playing.id
        }
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose videos for the lock screen. Each is converted once and kept in the Lab's library."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let added = Library.shared.add(panel.urls)
        status = added.isEmpty ? "Those videos are already in the library."
            : "Converting \(added.count) video\(added.count == 1 ? "" : "s") in the background — they appear when ready."
    }

    /// Sets an item as the wallpaper; if it's still converting, it's set as soon as it's ready.
    func select(_ item: LibraryItem) {
        currentID = item.id
        guard item.isReady else {
            Library.shared.priorityID = item.id
            Library.shared.convertPending()
            status = "\(item.name) will be set as soon as it has converted."
            return
        }
        do {
            try Engine.apply(loop: item.files.loop, still: item.files.still)
            try? FileManager.default.removeItem(at: Self.stillFile)
            try? FileManager.default.copyItem(at: item.files.still, to: Self.stillFile)
            lastChange = Date().timeIntervalSince1970
            refreshDesktop()
            status = "Now playing \(item.name). Lock your Mac (⌃⌘Q) to see it."
        } catch {
            status = error.localizedDescription
        }
    }

    /// The next ready video (in library order, or random when shuffling). Used by the shortcuts and rotation.
    func next(automatic: Bool = false) {
        let ready = Library.shared.readyItems
        if automatic {
            lastChange = Date().timeIntervalSince1970
            guard ready.count > 1 else { return }
        }
        guard let item = Library.shared.next(after: currentID, shuffle: shuffle) else {
            status = Engine.Failure.noVideos.localizedDescription
            return
        }
        select(item)
    }

    private func converted(_ item: LibraryItem) {
        // The wallpaper waiting for this conversion, or nothing set yet: put it on now.
        if item.id == currentID || current == nil { select(item) }
    }

    func remove(_ item: LibraryItem) {
        if item.id == currentID { currentID = "" } // what's playing keeps playing until something else is picked
        Library.shared.remove(item)
    }

    func refreshDesktop() {
        switch desktopMode {
        case .still: DesktopOverlay.shared.show(NSImage(contentsOf: Self.stillFile))
        case .picture: DesktopOverlay.shared.show(NSImage(contentsOfFile: desktopPicturePath))
        case .system: DesktopOverlay.shared.show(nil)
        }
    }

    func chooseDesktopPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Picture"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        desktopPicturePath = url.path
        desktopMode = .picture
    }

    func applyKeepAwake() {
        KeepAwake.shared.enabled = keepScreenOn
        KeepAwake.shared.minutes = keepScreenOnMinutes
    }

    func setOpenAtLogin(_ on: Bool) {
        LoginItem.set(on)
        openAtLogin = LoginItem.isEnabled
    }

    func restore() {
        do {
            try Engine.restore()
            currentID = ""
            rotationInterval = .off
            desktopMode = .system
            status = "Mayfly's Wallpaper Lab's aerial removed and your previous wallpaper restored. Automatic change is off."
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Opens the Lab at login with a LaunchAgent, so the desktop picture and rotation keep working after a restart.
enum LoginItem {
    static let plist = Engine.home.appendingPathComponent("Library/LaunchAgents/local.mayfly.wallpaperlab.plist")
    static let oldPlist = Engine.home.appendingPathComponent("Library/LaunchAgents/local.livelock.lab.plist")
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ on: Bool) {
        if on {
            let agent: [String: Any] = [
                "Label": "local.mayfly.wallpaperlab",
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (agent as NSDictionary).write(to: plist)
        } else {
            try? FileManager.default.removeItem(at: plist)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // mayflywallpaperlab://next — used by the Finder right-click menu extension.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.register { Task { @MainActor in Model.shared.next() } }
        Task { @MainActor in
            Model.shared.start()
            Setup.shared.start()
        }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              URL(string: text)?.host == "next" else { return }
        Task { @MainActor in Model.shared.next() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Next Wallpaper", action: #selector(nextFromMenu), keyEquivalent: "").target = self
        return menu
    }

    @objc func nextFromMenu() {
        Task { @MainActor in Model.shared.next() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct WallpaperLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model.shared
    @StateObject private var library = Library.shared
    @StateObject private var setup = Setup.shared

    var body: some Scene {
        Window("Mayfly's Wallpaper Lab", id: "main") {
            WindowView(model: model, library: library)
                .sheet(isPresented: $setup.isPresented) { SetupView(setup: setup, model: model) }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Mayfly's Wallpaper Lab", systemImage: "flask") {
            MenuView(model: model, library: library)
        }
    }
}
