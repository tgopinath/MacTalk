import Carbon.HIToolbox
import Foundation

/// System-wide speed-dial shortcuts: ⌃1 … ⌃9 call friends 1 … 9 in the speed-dial order.
/// Uses Carbon `RegisterEventHotKey`, which works without Accessibility permission and
/// only fires for these exact key combinations.
@MainActor
final class SpeedDialHotkeys {
    var onSlot: ((Int) -> Void)?
    private(set) var failedSlots: [Int] = []

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4D54_4B31 // "MTK1"
    private static let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                   kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    func register(modifier: SpeedDialModifier) {
        unregister()
        installHandlerIfNeeded()
        let mods: Int = switch modifier {
        case .control: controlKey
        case .controlOption: controlKey | optionKey
        case .controlCommand: controlKey | cmdKey
        }
        failedSlots = []
        for (index, code) in Self.keyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failedSlots.append(index + 1) }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == SpeedDialHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            let slot = Int(id.id)
            let hotkeys = Unmanaged<SpeedDialHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.onSlot?(slot) }
            return noErr
        }, 1, &spec, context, &handler)
    }
}
