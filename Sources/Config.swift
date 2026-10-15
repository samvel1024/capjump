import Foundation

/// Matches windows by app name and/or title (case-insensitive regexes).
/// In `rules` it also pins `key` to the matching window; in `ignore` the
/// matching windows are hidden from the switcher.
struct Rule: Decodable {
    let key: String?
    let app: String?
    let title: String?

    func matches(_ w: Win) -> Bool {
        func m(_ pattern: String?, _ s: String) -> Bool {
            guard let pattern else { return true }
            return s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return (app != nil || title != nil) && m(app, w.app) && m(title, w.title)
    }
}

struct Config: Decodable {
    /// e.g. "alt+tab", "cmd+tab", "ctrl+alt+space", "f19". "none" disables the
    /// built-in hotkey (toggle with `capjump toggle` from your own hotkey tool).
    var hotkey: String?
    /// "keyboard" (windows drawn on a QWERTY map) or "list".
    var layout: String?
    /// "auto" (yabai when it's running, otherwise native), "yabai" or "native".
    var backend: String?
    /// Overall size multiplier for the panel.
    var scale: Double?
    /// Key that jumps back to the previously focused window: "tab" (default),
    /// "space", "return", or any single character such as "j". A character is
    /// reserved, so no window gets it.
    var previousKey: String?
    var rules: [Rule]?
    var ignore: [Rule]?

    var previous: PreviousKey { PreviousKey(previousKey ?? "tab") }

    var hotkeySpec: String? {
        let h = hotkey ?? "alt+tab"
        return ["", "none", "off"].contains(h.lowercased()) ? nil : h
    }
}

/// The "go back" key inside the panel: a named key, or a reserved character.
enum PreviousKey: Equatable {
    case code(UInt16, label: String)
    case char(Character)

    init(_ spec: String) {
        switch spec.lowercased() {
        case "tab": self = .code(48, label: "tab")
        case "space": self = .code(49, label: "space")
        case "return", "enter": self = .code(36, label: "return")
        case let s where s.count == 1: self = .char(s.first!)
        default: self = .code(48, label: "tab")
        }
    }

    var reservedChar: Character? {
        if case .char(let c) = self { return c }
        return nil
    }

    var label: String {
        switch self {
        case .code(_, let label): return label
        case .char(let c): return String(c).uppercased()
        }
    }

    func matches(_ keyCode: UInt16, _ chars: String?) -> Bool {
        switch self {
        case .code(let code, _): return keyCode == code
        case .char(let c): return chars?.lowercased().first == c
        }
    }
}

var configPath = NSString(string: "~/.config/capjump/config.json").expandingTildeInPath

func loadConfig() -> Config {
    guard let data = FileManager.default.contents(atPath: configPath) else {
        return Config()
    }
    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        FileHandle.standardError.write("capjump: ignoring bad config \(configPath): \(error)\n".data(using: .utf8)!)
        return Config()
    }
}
