import AppKit
import Carbon

/// A parsed hotkey such as "alt+tab", "cmd+shift+space", "f19" or "0x5A".
struct Hotkey {
    let keyCode: UInt32
    let command, option, control, shift: Bool

    init?(_ spec: String) {
        var parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.popLast(), let code = Hotkey.keyCode(keyName) else { return nil }
        var cmd = false, opt = false, ctl = false, sft = false
        for p in parts {
            switch p {
            case "cmd", "command": cmd = true
            case "alt", "opt", "option": opt = true
            case "ctrl", "control": ctl = true
            case "shift": sft = true
            default: return nil
            }
        }
        (keyCode, command, option, control, shift) = (code, cmd, opt, ctl, sft)
    }

    /// Cmd+Tab and Cmd+` are owned by the system; RegisterEventHotKey can't
    /// take them, so those go through an event tap (needs Accessibility).
    var needsEventTap: Bool { command && !control && (keyCode == 0x30 || keyCode == 0x32) }

    var carbonModifiers: UInt32 {
        (command ? UInt32(cmdKey) : 0) | (option ? UInt32(optionKey) : 0)
            | (control ? UInt32(controlKey) : 0) | (shift ? UInt32(shiftKey) : 0)
    }

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if command { f.insert(.maskCommand) }
        if option { f.insert(.maskAlternate) }
        if control { f.insert(.maskControl) }
        if shift { f.insert(.maskShift) }
        return f
    }

    // macOS virtual key codes (ANSI positions).
    private static let names: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
        "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
    ]

    private static func keyCode(_ name: String) -> UInt32? {
        if name.hasPrefix("0x") { return UInt32(name.dropFirst(2), radix: 16) }
        return names[name]
    }
}

/// Called on the main thread whenever the hotkey fires.
var hotkeyAction: (() -> Void)?

/// Registers the configured hotkey either as a Carbon global hotkey (no
/// permissions needed) or, for system-reserved combos, as an event tap that
/// swallows the keystroke before the system switcher sees it.
final class HotkeyManager {
    private var carbonRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var retryTimer: Timer?

    func register(_ hotkey: Hotkey?) {
        unregister()
        guard let hotkey else { return }
        if hotkey.needsEventTap {
            installTap(hotkey)
        } else {
            installCarbon(hotkey)
        }
    }

    private func unregister() {
        if let carbonRef { UnregisterEventHotKey(carbonRef) }
        carbonRef = nil
        retryTimer?.invalidate()
        retryTimer = nil
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        tapPort = nil
        tapHotkey = nil
    }

    private func installCarbon(_ hk: Hotkey) {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                hotkeyAction?()
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x434A_4D50), id: 1) // 'CJMP'
        let status = RegisterEventHotKey(hk.keyCode, hk.carbonModifiers, id, GetApplicationEventTarget(), 0, &carbonRef)
        if status != noErr {
            FileHandle.standardError.write("capjump: could not register hotkey (\(status)); is it taken?\n".data(using: .utf8)!)
        }
    }

    private func installTap(_ hk: Hotkey) {
        tapHotkey = hk
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: tapCallback, userInfo: nil) else {
            // No Accessibility permission yet: ask, then keep retrying so it
            // starts working as soon as it's granted.
            requestAccessibility()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                self?.installTap(hk)
            }
            return
        }
        tapPort = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
}

private var tapPort: CFMachPort?
private var tapHotkey: Hotkey?

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    guard type == .keyDown, let hk = tapHotkey,
          event.getIntegerValueField(.keyboardEventKeycode) == Int64(hk.keyCode),
          event.flags.intersection(relevant) == hk.cgFlags else {
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        DispatchQueue.main.async { hotkeyAction?() }
    }
    return nil
}

private var accessibilityRequested = false

func requestAccessibility() {
    guard !accessibilityRequested else { return }
    accessibilityRequested = true
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}
