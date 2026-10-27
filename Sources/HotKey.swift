import Carbon

/// System-wide ⌃⌥⌘N for Next Wallpaper. Carbon hot keys need no Accessibility permission.
enum HotKey {
    nonisolated(unsafe) private static var handler: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.handler?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D57_4C31), id: 1) // "MWL1"
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
