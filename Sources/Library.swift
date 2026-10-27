import AppKit
import Foundation

/// One video in the library. Its converted files live in `Engine.libraryDir/<id>/` (see Convert.swift),
/// so the original file can be moved or deleted once it has been converted.
struct LibraryItem: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var sourcePath: String
    var added: Date

    var dir: URL { Engine.libraryDir.appendingPathComponent(id) }
    var files: Engine.Output { Engine.outputs(in: dir) }
    /// The Lab's own copy of the original, so (re-)conversions never need to reach into protected
    /// folders like Desktop (macOS blocks that until you allow it, and asks again after every rebuild).
    var originalCopy: URL { dir.appendingPathComponent("original." + (sourcePath as NSString).pathExtension.lowercased()) }
    var isReady: Bool {
        FileManager.default.fileExists(atPath: files.loop.path) && FileManager.default.fileExists(atPath: files.still.path)
    }
    /// Converted with the current encoder (see `Engine.currentFormat`); if not, it's re-converted in the background.
    var isUpToDate: Bool { (try? String(contentsOf: files.format, encoding: .utf8)) == Engine.currentFormat }
}

/// The library: the list of videos, and a queue that converts new ones in the background, one at a time.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var items: [LibraryItem] = []
    /// Conversion progress (0…1) of the item being converted.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]

    /// Converted before anything else (the wallpaper that is waiting for its conversion).
    var priorityID: String?

    /// Called when an item finishes converting (Model re-applies it if it's the current wallpaper).
    var onConverted: ((LibraryItem) -> Void)?

    private let indexFile = Engine.libraryDir.appendingPathComponent("library.json")
    private var converting = false

    var exists: Bool { FileManager.default.fileExists(atPath: indexFile.path) }
    var readyItems: [LibraryItem] { items.filter(\.isReady) }

    private init() {
        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = saved
        }
    }

    func item(_ id: String) -> LibraryItem? { items.first { $0.id == id } }

    /// Adds videos and starts converting them. Videos already in the library (same file) are skipped.
    @discardableResult
    func add(_ urls: [URL]) -> [LibraryItem] {
        var added: [LibraryItem] = []
        for url in urls where Engine.videoExtensions.contains(url.pathExtension.lowercased()) {
            guard !items.contains(where: { $0.sourcePath == url.path }) else { continue }
            let item = LibraryItem(id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent,
                                   sourcePath: url.path, added: Date())
            // Copy now, while the file picker's permission for it is still valid.
            try? FileManager.default.createDirectory(at: item.dir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: url, to: item.originalCopy)
            items.append(item)
            added.append(item)
        }
        save()
        convertPending()
        return added
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        progress[item.id] = nil
        errors[item.id] = nil
        try? FileManager.default.removeItem(at: item.dir)
        save()
    }

    func retry(_ item: LibraryItem) {
        errors[item.id] = nil
        convertPending()
    }

    /// Converts every item that isn't ready yet, oldest first. Safe to call any time.
    func convertPending() {
        guard !converting else { return }
        let pending = items.filter { (!$0.isReady || !$0.isUpToDate) && errors[$0.id] == nil }
        guard let item = pending.first(where: { $0.id == priorityID }) ?? pending.first else { return }
        converting = true
        progress[item.id] = 0
        Task {
            do {
                // Items added before the Lab kept copies get one now (this may ask once for folder access).
                if !FileManager.default.fileExists(atPath: item.originalCopy.path) {
                    let source = URL(fileURLWithPath: item.sourcePath)
                    try await Task.detached { try FileManager.default.copyItem(at: source, to: item.originalCopy) }.value
                }
                if item.isReady, (try? String(contentsOf: item.files.format, encoding: .utf8)) == Engine.fourLevelFormat {
                    try await Engine.upgradeLevels(in: item.dir) // seconds: relabelling only
                } else {
                    try await Engine.convert(item.originalCopy, into: item.dir) { value in
                        Task { @MainActor in Library.shared.progress[item.id] = value }
                    }
                }
                progress[item.id] = nil
                onConverted?(item)
            } catch {
                progress[item.id] = nil
                errors[item.id] = error.localizedDescription
            }
            converting = false
            convertPending()
        }
    }

    /// The ready item after `id` in library order (wrapping), or a random other one when shuffling.
    func next(after id: String?, shuffle: Bool) -> LibraryItem? {
        let ready = readyItems
        guard !ready.isEmpty else { return nil }
        if shuffle {
            return ready.filter { $0.id != id }.randomElement() ?? ready.first
        }
        guard let index = ready.firstIndex(where: { $0.id == id }) else { return ready.first }
        return ready[(index + 1) % ready.count]
    }

    func save() {
        try? FileManager.default.createDirectory(at: Engine.libraryDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }
}

/// How often the wallpaper changes by itself.
enum RotationInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case everyUnlock = -1
    case minutes15 = 15
    case minutes30 = 30
    case hour1 = 60
    case hours3 = 180
    case hours6 = 360
    case hours12 = 720
    case daily = 1440

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Never (only when I pick)"
        case .everyUnlock: return "Every time I unlock"
        case .minutes15: return "Every 15 minutes"
        case .minutes30: return "Every 30 minutes"
        case .hour1: return "Every hour"
        case .hours3: return "Every 3 hours"
        case .hours6: return "Every 6 hours"
        case .hours12: return "Every 12 hours"
        case .daily: return "Every day"
        }
    }
}

/// Changes the wallpaper on the chosen schedule. Never while the Mac is locked (the lock screen is
/// showing it); a change that comes due then happens right after the next unlock.
@MainActor
final class Rotation {
    static let shared = Rotation()

    private(set) var isLocked = false
    private var timer: Timer?

    private init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Rotation.shared.isLocked = true }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Rotation.shared.unlocked() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Rotation.shared.check() }
        }
    }

    func start() { check() }

    private func unlocked() {
        isLocked = false
        let model = Model.shared
        if model.rotationInterval == .everyUnlock {
            // Let the unlock slow-down finish before the wallpaper restarts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Model.shared.next(automatic: true) }
        } else {
            check()
        }
    }

    private func check() {
        let model = Model.shared
        let minutes = model.rotationInterval.rawValue
        guard minutes > 0, !isLocked else { return }
        let due = Date(timeIntervalSince1970: model.lastChange).addingTimeInterval(TimeInterval(minutes * 60))
        if Date() >= due { model.next(automatic: true) }
    }
}
