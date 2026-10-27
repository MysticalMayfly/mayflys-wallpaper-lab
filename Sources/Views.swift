import AppKit
import SwiftUI

/// Main window — opens at launch and when the Dock icon is clicked, so the app is always reachable
/// even if the menu bar icon is hidden behind the notch.
struct WindowView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: Library

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mayfly's Wallpaper Lab").font(.title2.bold())
                    Text(model.current.map { "Now playing: \($0.name)" } ?? "No video set — pick one below")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Setup…") { Setup.shared.show() }
                    .controlSize(.large)
                Button("Browse…") { model.browse() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            if library.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Click Browse… and pick videos. Each is converted once, then you can set it with a click.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(library.items) { item in
                            LibraryTile(item: item, isCurrent: item.id == model.currentID,
                                        progress: library.progress[item.id], error: library.errors[item.id])
                                .onTapGesture { model.select(item) }
                                .contextMenu {
                                    Button("Set as Wallpaper") { model.select(item) }
                                        .disabled(library.errors[item.id] != nil)
                                    if library.errors[item.id] != nil {
                                        Button("Try Converting Again") { library.retry(item) }
                                    }
                                    Button("Show Original in Finder") {
                                        let original = FileManager.default.fileExists(atPath: item.sourcePath)
                                            ? URL(fileURLWithPath: item.sourcePath) : item.originalCopy
                                        NSWorkspace.shared.activateFileViewerSelecting([original])
                                    }
                                    Divider()
                                    Button("Remove from Library") { model.remove(item) }
                                }
                        }
                    }
                    .padding(2)
                }
                .frame(minHeight: 180, maxHeight: 360)
            }

            GroupBox("Change automatically") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Change the wallpaper", selection: Binding(get: { model.rotationInterval },
                                                                      set: { model.rotationInterval = $0 })) {
                        ForEach(RotationInterval.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Order", selection: $model.shuffle) {
                        Text("Library order").tag(false)
                        Text("Shuffle").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.rotationInterval == .off)
                    Text("Never changes while the Mac is locked. ⌃⌥⌘N, the Dock icon menu, the menu-bar menu and Finder's right-click menu skip to the next video.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Desktop & lock screen") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Desktop shows", selection: Binding(get: { model.desktopMode }, set: { model.desktopMode = $0 })) {
                        ForEach(DesktopMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.desktopMode == .picture {
                        HStack {
                            Text(model.desktopPicturePath.isEmpty ? "No picture chosen" : (model.desktopPicturePath as NSString).lastPathComponent)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose Picture…") { model.chooseDesktopPicture() }
                        }
                    }
                    HStack {
                        Toggle("Keep the screen on while locked for", isOn: $model.keepScreenOn)
                        Picker("", selection: $model.keepScreenOnMinutes) {
                            ForEach([1, 2, 5, 10, 30], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!model.keepScreenOn)
                    }
                    Toggle("Open at login (keeps the desktop picture and automatic change after a restart)",
                           isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                    HStack {
                        Spacer()
                        Button("Remove Lab Aerial & Restore") { model.restore() }
                    }
                }
                .font(.callout)
                .padding(4)
            }

            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 600)
    }
}

/// A library video: thumbnail, name, and its conversion state.
struct LibraryTile: View {
    let item: LibraryItem
    let isCurrent: Bool
    let progress: Double?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let thumb = Thumbnails.image(for: item) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                }
                if let progress {
                    VStack(spacing: 4) {
                        ProgressView(value: progress).frame(width: 110)
                        Text(item.isReady ? "Improving \(Int(progress * 100))%" : "Converting \(Int(progress * 100))%").font(.caption2)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                } else if let error {
                    Label("Couldn't convert", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .help(error)
                } else if !item.isReady {
                    Text("Waiting to convert…").font(.caption2)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 3))
            .overlay(alignment: .topLeading) {
                if isCurrent {
                    Label("Now playing", systemImage: "play.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .help(isCurrent ? "Now playing" : item.isReady ? "Click to set as the lock screen wallpaper" : "Converting — click to set it as soon as it's ready")
    }
}

/// Small thumbnails, loaded once.
@MainActor
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]

    static func image(for item: LibraryItem) -> NSImage? {
        if let image = cache[item.id] { return image }
        guard let image = NSImage(contentsOf: item.files.thumb) else { return nil }
        cache[item.id] = image
        return image
    }
}

struct MenuView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: Library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.current.map { "Now: \($0.name)" } ?? "No video set")
        if !model.status.isEmpty { Text(model.status) }
        Divider()
        Button("Next Wallpaper") { model.next() }
            .disabled(library.readyItems.isEmpty)
        Button("Add Videos…") { model.browse() }
        Divider()
        Button("Setup…") { openWindow(id: "main"); Setup.shared.show() }
        Button("Restore Original Wallpaper") { model.restore() }
        Button("Quit Mayfly's Wallpaper Lab") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
