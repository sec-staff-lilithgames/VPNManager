//
//  VPNShortcutController.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 3/30/26.
//

import Carbon
import Foundation

final class VPNShortcutController {
    private enum ShortcutHotKey: UInt32 {
        case toggleCurrentVPN = 1
    }

    private let shortcutHotKeySignature: OSType = 0x56504E4D // 'VPNM'
    private var hotKeyEventHandler: EventHandlerRef?
    private var registeredHotKeys: [ShortcutHotKey: EventHotKeyRef?] = [:]
    private let actionHandler: (ShortcutAction) -> Void

    init(actionHandler: @escaping (ShortcutAction) -> Void) {
        self.actionHandler = actionHandler
    }

    deinit {
        unregisterHotKeys()
    }

    func start() {
        installHotKeyHandlerIfNeeded()
        let status = registerHotKey(identifier: .toggleCurrentVPN,
                                    keyCode: UInt32(kVK_ANSI_A),
                                    modifiers: UInt32(controlKey))
        if status == noErr {
            AppLogger.shared.log("Registered Control + A shortcut for toggling current VPN.")
        } else if status == eventHotKeyExistsErr {
            AppLogger.shared.log("Control + A shortcut registration skipped because the combination is already used by another application.")
        } else {
            AppLogger.shared.log("Failed to register Control + A shortcut. OSStatus=\(status)")
        }
    }
}

private extension VPNShortcutController {
    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyEventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData = userData else { return noErr }
            let controller = Unmanaged<VPNShortcutController>.fromOpaque(userData).takeUnretainedValue()
            return controller.handleHotKey(eventRef: eventRef)
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyEventHandler
        )
    }

    @discardableResult
    private func registerHotKey(identifier: ShortcutHotKey,
                                keyCode: UInt32,
                                modifiers: UInt32) -> OSStatus {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: shortcutHotKeySignature, id: identifier.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            registeredHotKeys[identifier] = hotKeyRef
        }

        return status
    }

    private func unregisterHotKeys() {
        for (_, hotKeyRef) in registeredHotKeys {
            if let hotKeyRef = hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        registeredHotKeys.removeAll()
    }

    private func handleHotKey(eventRef: EventRef?) -> OSStatus {
        guard let eventRef = eventRef else { return noErr }
        var hotKeyID = EventHotKeyID()
        let result = GetEventParameter(
            eventRef,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard result == noErr,
              hotKeyID.signature == shortcutHotKeySignature,
              let identifier = ShortcutHotKey(rawValue: hotKeyID.id)
        else {
            return noErr
        }

        switch identifier {
        case .toggleCurrentVPN:
            actionHandler(.toggleCurrentVPN)
        }

        return noErr
    }
}
