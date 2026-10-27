import Cocoa
import FinderSync

/// Finder Sync extension that adds "Next Wallpaper" to Finder's right-click menu.
/// It runs sandboxed inside Finder, so it only asks the main app to act, via mayflywallpaperlab://next.
@objc(FinderSync)
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Inside the sandbox NSHomeDirectory() is the container, so look up the real home folder.
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: home + "/Desktop"),
            URL(fileURLWithPath: "/"),
        ]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        menu.addItem(withTitle: "Next Wallpaper", action: #selector(nextWallpaper(_:)), keyEquivalent: "")
        return menu
    }

    @IBAction func nextWallpaper(_ sender: AnyObject?) {
        NSWorkspace.shared.open(URL(string: "mayflywallpaperlab://next")!)
    }
}
