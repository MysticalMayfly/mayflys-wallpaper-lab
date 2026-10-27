import AVFoundation
import Foundation

/// Mayfly's Wallpaper Lab — build of "option B": instead of overwriting one of Apple's aerials (LiveLock borrows
/// "Jacks"), it adds its *own* aerial to macOS's aerial list and points the wallpaper at it.
///
/// What macOS needs (found by experiment on macOS 27.0.1):
/// - an entry in ~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json, shaped like a
///   real Apple entry (category, subcategory, preview image…) — a hand-made entry missing those is ignored and
///   the wallpaper silently falls back to another aerial. So the entry is a copy of a downloaded Apple entry
///   with its own ID, name and video address. The packed manifest.tar doesn't need changing.
/// - the video at aerials/videos/<ID>.mov, with the extended attributes the aerial downloader leaves on files it
///   downloaded (SourceURL = the entry's address, LastETag); without them macOS tries to download it.
/// - the desktop wallpaper choice in Store/Index.plist set to that ID, then WallpaperAgent restarted.
/// When Apple publishes a new aerial catalogue, macOS replaces entries.json and the entry is gone; `repair()`
/// adds it back (at launch and every 10 minutes).
enum Engine {
    static let entryID = "1E5A6B7C-0D4F-4A3B-9C2D-11F1A0C0FFEE"
    static let entryName = "Mayfly's Wallpaper Lab"
    /// Never fetched: `.invalid` can't resolve. It only has to match the file's SourceURL attribute.
    static let entryURL = "https://mayfly-wallpaper-lab.invalid/\(entryID).mov"

    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser
    static let wallpaperDir = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    static let aerialsDir = wallpaperDir.appendingPathComponent("aerials")
    static let videosDir = aerialsDir.appendingPathComponent("videos")
    static let manifestFile = aerialsDir.appendingPathComponent("manifest/entries.json")
    static let indexPlist = wallpaperDir.appendingPathComponent("Store/Index.plist")
    static let entryVideo = videosDir.appendingPathComponent("\(entryID).mov")
    static let entryThumbnail = aerialsDir.appendingPathComponent("thumbnails/\(entryID).png")

    static let supportDir = home.appendingPathComponent("Library/Application Support/Mayfly's Wallpaper Lab")
    /// Where this app kept its files while it was called "LiveLock Lab" (moved at first launch, see `Rename`).
    static let oldSupportDir = home.appendingPathComponent("Library/Application Support/LiveLock Lab")
    static let libraryDir = supportDir.appendingPathComponent("library")
    /// Not used here (the Lab never had a folder-based version); kept so the shared library code compiles.
    static let oldCacheDir = supportDir.appendingPathComponent("converted")
    static let backupIndex = supportDir.appendingPathComponent("Index.plist.original")

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    enum Failure: LocalizedError {
        case noVideos, exportFailed(String), badIndex, noTemplate
        var errorDescription: String? {
            switch self {
            case .noVideos: return "No ready videos in the library yet."
            case .exportFailed(let m): return "Converting the video failed: \(m)"
            case .badIndex: return "Couldn't read the wallpaper settings file."
            case .noTemplate: return "Couldn't read macOS's aerial list. Download any aerial in System Settings → Wallpaper first."
            }
        }
    }

    static func videos(in folder: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return items.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Installs an already-converted loop as the "Mayfly's Wallpaper Lab" aerial and makes it the wallpaper.
    static func apply(loop: URL, still: URL? = nil) throws {
        backUpOriginals()
        try addEntry()
        // Copy next to the destination (an instant clone on APFS), label it as downloaded, swap it in atomically.
        let tmp = videosDir.appendingPathComponent(".mayfly-wallpaper-lab-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: loop, to: tmp)
        markAsDownloaded(tmp)
        if fm.fileExists(atPath: entryVideo.path) {
            _ = try fm.replaceItemAt(entryVideo, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: entryVideo)
        }
        if let still { try? writeThumbnail(from: still) }
        try pointDesktop(at: entryID)
        restartWallpaper()
    }

    /// Adds the entry back if macOS replaced the aerial list. Returns whether anything had to be repaired.
    @discardableResult
    static func repair() -> Bool {
        guard fm.fileExists(atPath: entryVideo.path) else { return false }
        if entryExists() {
            // An entry from before the rename keeps working but shows the old name; bring it up to date.
            guard (try? renameEntry()) == true else { return false }
            markAsDownloaded(entryVideo)
        } else {
            guard (try? addEntry()) != nil else { return false }
        }
        restartWallpaper()
        return true
    }

    /// Removes the Lab's aerial and puts the wallpaper settings from before the first use back.
    static func restore() throws {
        try? removeEntry()
        try? fm.removeItem(at: entryVideo)
        try? fm.removeItem(at: entryThumbnail)
        if fm.fileExists(atPath: backupIndex.path) {
            _ = try fm.replaceItemAt(indexPlist, withItemAt: copyToTemp(backupIndex))
        }
        restartWallpaper()
    }

    // MARK: - The aerial list

    private static func loadManifest() throws -> [String: Any] {
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any],
              manifest["assets"] is [[String: Any]] else { throw Failure.noTemplate }
        return manifest
    }

    private static func saveManifest(_ manifest: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestFile, options: .atomic)
    }

    /// Whether macOS's aerial list is on this Mac with at least one of Apple's aerials downloaded (the Lab's entry
    /// is a copy of a downloaded one). Fresh Macs have neither until an aerial is picked in Wallpaper settings.
    static var aerialsReady: Bool {
        guard let manifest = try? loadManifest(), let assets = manifest["assets"] as? [[String: Any]] else { return false }
        let ids = Set(assets.compactMap { $0["id"] as? String }).subtracting([entryID])
        let downloaded = ((try? fm.contentsOfDirectory(atPath: videosDir.path)) ?? []).map { ($0 as NSString).deletingPathExtension }
        return downloaded.contains { ids.contains($0) }
    }

    static func entryExists() -> Bool {
        guard let manifest = try? loadManifest(), let assets = manifest["assets"] as? [[String: Any]] else { return false }
        return assets.contains { $0["id"] as? String == entryID }
    }

    /// Our entry, shaped like a real one: a copy of an Apple aerial whose video is downloaded on this Mac
    /// (so its category and preview image are valid), with our ID, name and address.
    private static func addEntry() throws {
        var manifest = try loadManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        if assets.contains(where: { $0["id"] as? String == entryID }) { return }
        let downloaded = Set(((try? fm.contentsOfDirectory(atPath: videosDir.path)) ?? []).map { ($0 as NSString).deletingPathExtension })
        let candidates = assets.filter {
            $0["url-4K-SDR-240FPS"] != nil && !(($0["subcategories"] as? [Any]) ?? []).isEmpty
                && !(($0["categories"] as? [Any]) ?? []).isEmpty
        }
        guard let template = candidates.first(where: { downloaded.contains($0["id"] as? String ?? "") }) ?? candidates.first,
              let position = assets.firstIndex(where: { $0["id"] as? String == template["id"] as? String }) else {
            throw Failure.noTemplate
        }
        var entry = template
        entry["id"] = entryID
        entry["accessibilityLabel"] = entryName
        entry["localizedNameKey"] = entryName // no translation exists, so macOS shows the key itself
        entry["shotID"] = "MAYFLY_WALLPAPER_LAB"
        entry["url-4K-SDR-240FPS"] = entryURL
        entry["includeInShuffle"] = false
        entry["pointsOfInterest"] = [String: Any]()
        assets.insert(entry, at: position + 1)
        manifest["assets"] = assets
        try saveManifest(manifest)
    }

    /// Gives an existing entry the current name and address. Returns whether it changed.
    private static func renameEntry() throws -> Bool {
        var manifest = try loadManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        guard let i = assets.firstIndex(where: { $0["id"] as? String == entryID }),
              assets[i]["accessibilityLabel"] as? String != entryName || assets[i]["url-4K-SDR-240FPS"] as? String != entryURL
        else { return false }
        assets[i]["accessibilityLabel"] = entryName
        assets[i]["localizedNameKey"] = entryName
        assets[i]["shotID"] = "MAYFLY_WALLPAPER_LAB"
        assets[i]["url-4K-SDR-240FPS"] = entryURL
        manifest["assets"] = assets
        try saveManifest(manifest)
        return true
    }

    private static func removeEntry() throws {
        var manifest = try loadManifest()
        manifest["assets"] = (manifest["assets"] as! [[String: Any]]).filter { $0["id"] as? String != entryID }
        try saveManifest(manifest)
    }

    /// The attributes the aerial downloader leaves on a finished download.
    private static func markAsDownloaded(_ file: URL) {
        func set(_ name: String, _ value: String) {
            _ = value.withCString { pointer in setxattr(file.path, name, pointer, strlen(pointer), 0, 0) }
        }
        set("SourceURL", entryURL)
        set("LastETag", "\"mayfly-wallpaper-lab\"")
    }

    private static func writeThumbnail(from still: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-s", "format", "png", "-Z", "1280", still.path, "--out", entryThumbnail.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - Wallpaper settings

    private static func copyToTemp(_ url: URL) throws -> URL {
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: url, to: tmp)
        return tmp
    }

    private static func backUpOriginals() {
        // Only the very first time, so the backup holds the settings from before the Lab was used.
        if !fm.fileExists(atPath: backupIndex.path) {
            try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: indexPlist, to: backupIndex)
        }
    }

    /// Sets the desktop (which the lock screen mirrors) to the given aerial for all displays and spaces.
    static func pointDesktop(at assetID: String) throws {
        let data = try Data(contentsOf: indexPlist)
        guard var root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.badIndex
        }
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let choice: [String: Any] = ["Provider": "com.apple.wallpaper.choice.aerials", "Configuration": config, "Files": []]

        func patch(_ entry: inout [String: Any]) {
            guard var desktop = entry["Desktop"] as? [String: Any],
                  var content = desktop["Content"] as? [String: Any] else { return }
            content["Choices"] = [choice]
            content["Shuffle"] = "$null"
            desktop["Content"] = content
            desktop["LastSet"] = Date()
            entry["Desktop"] = desktop
        }
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if var entry = root[key] as? [String: Any] { patch(&entry); root[key] = entry }
        }
        // Per-display / per-space overrides would beat ours, so patch those too.
        for key in ["Displays", "Spaces"] {
            guard var group = root[key] as? [String: Any] else { continue }
            for (id, value) in group {
                if var entry = value as? [String: Any] { patch(&entry); group[id] = entry }
            }
            root[key] = group
        }
        let out = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try out.write(to: indexPlist, options: .atomic)
    }

    /// Restarting only the agent is enough: launchd relaunches it and it starts fresh extensions.
    static func restartWallpaper() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        try? p.run()
        while p.isRunning { usleep(20_000) }
    }
}
