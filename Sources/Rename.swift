import Foundation

/// This app was called "LiveLock Lab" (bundle local.livelock.lab). At the first launch under the new name it moves
/// the old settings, library and login item over, so nothing has to be set up again. The aerial entry gets its new
/// name from `Engine.repair()`.
enum Rename {
    static let oldBundleID = "local.livelock.lab"

    static func migrate() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Engine.oldSupportDir.path), !fm.fileExists(atPath: Engine.supportDir.path) {
            try? fm.moveItem(at: Engine.oldSupportDir, to: Engine.supportDir)
        }
        let defaults = UserDefaults.standard
        if let old = defaults.persistentDomain(forName: oldBundleID), let id = Bundle.main.bundleIdentifier {
            var merged = old
            merged.merge(defaults.persistentDomain(forName: id) ?? [:]) { _, new in new }
            defaults.setPersistentDomain(merged, forName: id)
            defaults.removePersistentDomain(forName: oldBundleID)
        }
        if fm.fileExists(atPath: LoginItem.oldPlist.path) {
            try? fm.removeItem(at: LoginItem.oldPlist)
            LoginItem.set(true)
        }
    }
}
