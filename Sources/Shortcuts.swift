import AppKit
import Carbon

final class Shortcuts {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<Shortcuts>.fromOpaque(context).takeUnretainedValue()
            owner.actions[id.id]?(); return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func clear() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); actions.removeAll() }
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) throws {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: 0x4D594354, id: id), GetApplicationEventTarget(), 0, &ref)
        guard result == noErr, let ref else { throw AppError("\(shortcut.label)은 다른 기능에서 사용 중이거나 등록할 수 없어요. 다른 단축키를 지정해 주세요.") }
        refs.append(ref); actions[id] = action
    }
    static func from(_ event: NSEvent) throws -> Shortcut {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.command, .option, .control]).isEmpty else { throw AppError("⌘, ⌥, ⌃ 중 하나 이상을 함께 눌러 주세요.") }
        var modifiers: UInt32 = 0; var labels: [String] = []
        if f.contains(.control) { modifiers |= UInt32(controlKey); labels.append("⌃") }
        if f.contains(.option) { modifiers |= UInt32(optionKey); labels.append("⌥") }
        if f.contains(.shift) { modifiers |= UInt32(shiftKey); labels.append("⇧") }
        if f.contains(.command) { modifiers |= UInt32(cmdKey); labels.append("⌘") }
        let special: [UInt16: String] = [49:"Space",36:"Return",48:"Tab",51:"Delete",123:"←",124:"→",125:"↓",126:"↑"]
        labels.append(special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
        return Shortcut(key: UInt32(event.keyCode), modifiers: modifiers, label: labels.joined(separator: " "))
    }
    deinit { clear(); if let handler { RemoveEventHandler(handler) } }
}
