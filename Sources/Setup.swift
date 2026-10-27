import AppKit
import FinderSync
import SwiftUI

/// The first-run checklist. macOS doesn't let an app grant itself anything, so each step that needs the user
/// has a button that opens the right place; the ticks update when the app comes back to the front.
/// Shown at the first launch and from "Setup…" in the window and the menu-bar menu.
@MainActor
final class Setup: ObservableObject {
    static let shared = Setup()

    @AppStorage("setupShown") var shown = false
    @Published var isPresented = false
    @Published private(set) var notTranslocated = true
    @Published private(set) var aerialsReady = true
    @Published private(set) var finderEnabled = false

    var allDone: Bool { notTranslocated && aerialsReady && finderEnabled && LoginItem.isEnabled }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Setup.shared.refresh() }
        }
    }

    /// Called at launch: registers the Finder extension and opens the checklist the first time.
    func start() {
        registerFinderExtension()
        refresh()
        if !shown { shown = true; isPresented = true }
    }

    func refresh() {
        // A downloaded app that wasn't moved out of Downloads runs from a random read-only copy
        // (App Translocation): the login item and the Finder extension would point at a path that disappears.
        notTranslocated = !Bundle.main.bundlePath.contains("/AppTranslocation/")
        aerialsReady = Engine.aerialsReady
        finderEnabled = Self.finderExtensionEnabled()
        Model.shared.openAtLogin = LoginItem.isEnabled
    }

    func show() {
        refresh()
        isPresented = true
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Tells macOS about the extension inside this copy of the app, so it shows up in System Settings
    /// without the user running pluginkit.
    private func registerFinderExtension() {
        guard notTranslocated, let plugins = Bundle.main.builtInPlugInsURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-a", plugins.appendingPathComponent("MayflysWallpaperLabFinder.appex").path]
        try? process.run()
    }

    /// FIFinderSyncController.isExtensionEnabled says false for this ad-hoc signed build even when it's on;
    /// pluginkit lists an extension the user turned on with a leading "+".
    private static func finderExtensionEnabled() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", "local.mayfly.wallpaperlab.finder"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespaces).hasPrefix("+")
    }

    func openWallpaperSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }

    func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    func showApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}

struct SetupView: View {
    @ObservedObject var setup: Setup
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Mayfly's Wallpaper Lab").font(.title2.bold())
                Text("Converting videos, the lock-screen aerial, the menu-bar icon and ⌃⌥⌘N need no permissions. These steps are all macOS asks for — each is done once.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupStep(done: setup.notTranslocated, title: "Running from the Applications folder",
                      detail: "macOS is running a temporary copy because the app wasn't moved. Quit, drag Mayfly's Wallpaper Lab into Applications and open it from there.") {
                Button("Show Applications") { setup.showApplicationsFolder() }
            }

            SetupStep(done: setup.aerialsReady, title: "Apple's aerials are on this Mac",
                      detail: "The Lab's aerial is modelled on one of Apple's. In Wallpaper settings, click any aerial (Landscape, Cityscape…) and let it download once.") {
                Button("Open Wallpaper Settings") { setup.openWallpaperSettings() }
            }

            SetupStep(done: setup.finderEnabled, title: "Finder right-click menu (optional)",
                      detail: "Adds \"Next Wallpaper\" to Finder's right-click menu. Turn on Mayfly's Wallpaper Lab under Finder (or Added Extensions) in the window that opens.") {
                Button("Open Extensions") { setup.openExtensionSettings() }
            }

            SetupStep(done: model.openAtLogin, title: "Open at login (optional)",
                      detail: "Keeps the desktop picture and automatic change working after a restart. macOS shows a \"Background item added\" notice.") {
                Button("Turn On") { model.setOpenAtLogin(true) }
            }

            HStack {
                Text(setup.allDone ? "All set." : "Steps tick themselves when you come back to this window.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { setup.isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { setup.refresh() }
    }
}

private struct SetupStep<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if !done {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !done { action() }
        }
    }
}
