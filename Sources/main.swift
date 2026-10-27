import Foundation

// Command-line mode for testing:
//   MayflysWallpaperLab --convert <video> <dir>   convert into <dir> (loop.mov, still.png, thumb.jpg)
//   MayflysWallpaperLab --apply-loop <loop.mov>   put an already-converted loop on the lock screen
//   MayflysWallpaperLab --upgrade-levels <dir>  relabel a four-level library loop in <dir> (no re-encoding)
//   MayflysWallpaperLab --restore
// The UI must start synchronously: running App.main() inside an async context
// would hold the main actor forever and freeze every later main-actor update.
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--convert" {
    Task {
        do {
            let start = Date()
            try await Engine.convert(URL(fileURLWithPath: args[2]), into: URL(fileURLWithPath: args[3])) { value in
                print(String(format: "progress %.0f%%", value * 100))
            }
            print(String(format: "converted in %.1f s", Date().timeIntervalSince(start)))
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
} else if args.count >= 3, args[1] == "--upgrade-levels" {
    Task {
        do { try await Engine.upgradeLevels(in: URL(fileURLWithPath: args[2])); print("upgraded"); exit(0) }
        catch { print("error: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
} else if args.count >= 3, args[1] == "--apply-loop" {
    do { try Engine.apply(loop: URL(fileURLWithPath: args[2])); print("applied") } catch { print("error: \(error)"); exit(1) }
} else if args.count >= 2, args[1] == "--restore" {
    do { try Engine.restore(); print("restored") } catch { print("error: \(error)"); exit(1) }
} else {
    Rename.migrate()
    WallpaperLabApp.main()
}
