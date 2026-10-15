// Capjump — jump to any window by pressing one letter.
//
// Runs as a menu-bar-less background app. The hotkey (built in, or SIGUSR1
// from your own hotkey daemon via `capjump toggle`) shows a panel where every
// window has a letter; pressing it focuses that window.

import AppKit

let usage = """
    capjump — jump to any window by pressing one letter

    usage:
      capjump                run the switcher (normally started at login)
      capjump toggle         show/hide the panel of the running instance
      capjump reload         re-read hotkey settings in the running instance
      capjump list           print windows and their letters

    options:
      --config <path>       config file (default ~/.config/capjump/config.json)
    """

/// Other capjump processes, found by name so it works whether we were started
/// from the .app bundle, a symlink, or a bare binary.
func otherInstances() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) * 2)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(count, 0))).filter { pid in
        guard pid > 0, pid != getpid() else { return false }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, 256)
        return String(cString: name) == "capjump"
    }
}

func signalRunning(_ sig: Int32) -> Never {
    let pids = otherInstances()
    guard !pids.isEmpty else {
        FileHandle.standardError.write("capjump: not running\n".data(using: .utf8)!)
        exit(1)
    }
    pids.forEach { kill($0, sig) }
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--config"), i + 1 < args.count {
    configPath = NSString(string: args[i + 1]).expandingTildeInPath
    args.removeSubrange(i...i + 1)
}

switch args.first {
case "toggle":
    signalRunning(SIGUSR1)
case "reload":
    signalRunning(SIGHUP)
case "list":
    for e in entries(loadConfig()).1 {
        let space = e.win.space > 0 ? "  [space \(e.win.space)]" : ""
        print("\(String(e.key).uppercased())  \(e.win.app) — \(e.win.title)\(space)")
    }
    exit(0)
case "-h", "--help", "help":
    print(usage)
    exit(0)
case nil:
    break
default:
    FileHandle.standardError.write("\(usage)\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - Daemon

if !otherInstances().isEmpty {
    FileHandle.standardError.write("capjump: already running\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let switcher = Switcher()
let hotkeys = HotkeyManager()
hotkeyAction = { switcher.toggle() }

func applySettings() {
    let config = loadConfig()
    if let spec = config.hotkeySpec {
        if let hk = Hotkey(spec) {
            hotkeys.register(hk)
        } else {
            FileHandle.standardError.write("capjump: can't parse hotkey \"\(spec)\"\n".data(using: .utf8)!)
            hotkeys.register(nil)
        }
    } else {
        hotkeys.register(nil)
    }
    FileHandle.standardError.write(
        "capjump: accessibility=\(AXIsProcessTrusted()) screen-recording=\(CGPreflightScreenCaptureAccess())\n"
            .data(using: .utf8)!)
    // The native backend needs Accessibility to raise windows and read
    // titles; ask once up front rather than on first use.
    if config.backend == "native" || (config.backend != "yabai" && YabaiBackend().windows() == nil) {
        if !AXIsProcessTrusted() { requestAccessibility() }
    }
}
applySettings()

signal(SIGUSR1, SIG_IGN)
let toggleSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
toggleSignal.setEventHandler { switcher.toggle() }
toggleSignal.resume()

signal(SIGHUP, SIG_IGN)
let reloadSignal = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
reloadSignal.setEventHandler { applySettings() }
reloadSignal.resume()

for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
    appIcon(a.processIdentifier)
}

// Start tracking focus history right away, so Tab has a previous window to
// go back to even on the first open (yabai tracks its own).
_ = NativeBackend.shared

// The native backend resolves each new window through Accessibility once
// (~70ms per app for windows on other Spaces). Do that ahead of time while
// the panel is closed, so opening it stays instant.
func warmUp() {
    let backend = loadConfig().backend
    guard backend == "native" || (backend != "yabai" && YabaiBackend.path == nil) else { return }
    _ = NativeBackend.shared.windows()
}
warmUp()
let warmTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
    if !switcher.panel.isVisible { warmUp() }
}

app.run()
