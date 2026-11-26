import Carbon.HIToolbox
import Cocoa

/// Carbon delivers only these two registered combinations; no event monitor or Accessibility access.
enum PetShortcut: UInt32, CaseIterable {
    case visibility = 1, pause
    var key: UInt32 { UInt32(self == .visibility ? kVK_ANSI_H : kVK_ANSI_P) }
    var label: String { self == .visibility ? "⌃⌥⌘H" : "⌃⌥⌘P" }
    var title: String { self == .visibility ? "显示或隐藏桌宠" : "暂停或继续流动" }
}

final class GlobalShortcuts {
    static let signature: OSType = 0x53475054 // SGPT
    private var handler: EventHandlerRef?
    private var registrations: [PetShortcut: EventHotKeyRef] = [:]
    private let perform: (PetShortcut) -> Void
    init(perform: @escaping (PetShortcut) -> Void) { self.perform = perform }

    @discardableResult func start() -> Set<PetShortcut> {
        stop()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let result = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == GlobalShortcuts.signature, let action = PetShortcut(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            guard owner.registrations[action] != nil else { return OSStatus(eventNotHandledErr) }
            owner.perform(action)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return [] }
        for action in PetShortcut.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            if RegisterEventHotKey(action.key, UInt32(controlKey | optionKey | cmdKey), id, target, UInt32(kEventHotKeyExclusive), &ref) == noErr,
               let ref { registrations[action] = ref }
        }
        return Set(registrations.keys)
    }
    func stop() {
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit { stop() }
}
