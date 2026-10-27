import Foundation
import IOKit.pwr_mgt

/// macOS turns the display off a few seconds after you lock, which cuts the lock screen video short.
/// While the Mac is locked, the Lab holds a "prevent display sleep" assertion (the same thing video
/// players use) for a limited time, then releases it so the display can sleep as usual.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    var enabled = false { didSet { if !enabled { release() } } }
    var minutes = 2

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    private init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.locked() }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.release() }
        }
    }

    private func locked() {
        guard enabled else { return }
        release()
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Mayfly's Wallpaper Lab: lock screen video" as CFString, &assertion)
        guard status == kIOReturnSuccess else { assertion = 0; return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.release() }
        }
    }

    private func release() {
        timer?.invalidate()
        timer = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
