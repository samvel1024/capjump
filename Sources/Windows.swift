import AppKit

struct Win {
    let id: UInt32
    let pid: pid_t
    let app: String
    let title: String
    /// 1-based Mission Control space index, 0 when unknown.
    let space: Int
    /// CG coordinates: origin at the top-left of the primary display.
    let frame: CGRect
    let hasFocus: Bool
}

protocol Backend {
    /// All switchable windows, or nil when this backend can't be used.
    func windows() -> [Win]?
    func focus(_ w: Win)
}

/// "auto" prefers yabai when it answers, since it already knows exactly which
/// windows are real; otherwise falls back to the native backend.
func resolveWindows(_ name: String?) -> (Backend, [Win]) {
    let native = NativeBackend.shared
    switch name {
    case "native":
        return (native, native.windows() ?? [])
    case "yabai":
        return (YabaiBackend(), YabaiBackend().windows() ?? [])
    default:
        if let wins = YabaiBackend().windows() { return (YabaiBackend(), wins) }
        return (native, native.windows() ?? [])
    }
}

// MARK: - Process helper

/// Raw posix_spawn + waitpid rather than Foundation's Process, which adds
/// ~65ms of overhead per call (most of the panel's open latency).
func run(_ path: String, _ args: [String]) -> Data? {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return nil }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, fds[0])
    posix_spawn_file_actions_addclose(&actions, fds[1])
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

    let argv = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &actions, nil, argv, environ)
    close(fds[1])
    guard rc == 0 else { close(fds[0]); return nil }

    let data = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return status == 0 ? data : nil
}

// MARK: - yabai

struct YabaiBackend: Backend {
    static let path = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Frame: Decodable { let x, y, w, h: Double }

    private struct YWin: Decodable {
        let id: UInt32
        let pid: Int32
        let app: String
        let title: String
        let space: Int
        let subrole: String
        let frame: Frame
        let isMinimized: Bool
        let isHidden: Bool
        let hasFocus: Bool

        enum CodingKeys: String, CodingKey {
            case id, pid, app, title, space, subrole, frame
            case isMinimized = "is-minimized", isHidden = "is-hidden", hasFocus = "has-focus"
        }
    }

    func windows() -> [Win]? {
        guard let path = Self.path,
              let data = run(path, ["-m", "query", "--windows"]),
              let ys = try? JSONDecoder().decode([YWin].self, from: data) else { return nil }
        return ys
            .filter { !$0.isMinimized && !$0.isHidden && $0.subrole == "AXStandardWindow" && $0.pid != getpid() }
            .map {
                Win(id: $0.id, pid: $0.pid, app: $0.app, title: $0.title, space: $0.space,
                    frame: CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.w, height: $0.frame.h),
                    hasFocus: $0.hasFocus)
            }
    }

    func focus(_ w: Win) {
        if let path = Self.path { _ = run(path, ["-m", "window", "--focus", String(w.id)]) }
    }
}

// MARK: - Native

/// No window manager needed. Lists windows with CGWindowList + SkyLight's
/// space lookup, and focuses them the way yabai does without its scripting
/// addition: SkyLight's front-process call (which also switches to the
/// window's Space) plus a synthetic make-key event, then an AX raise.
/// Private symbols are resolved at runtime so a missing one degrades instead
/// of crashing.
final class NativeBackend: Backend {
    static let shared = NativeBackend()

    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    private let mainConn: MainConnFn?
    private let copyDisplaySpaces: CopyDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let setFront: SetFrontFn?
    private let postEvent: PostEventFn?
    private let getPSN: GetPSNFn?
    private let axGetWindow: AXGetWindowFn?

    private init() {
        let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
            dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
        }
        mainConn = sym(sl, "SLSMainConnectionID")
        copyDisplaySpaces = sym(sl, "SLSCopyManagedDisplaySpaces")
        copySpacesForWindows = sym(sl, "SLSCopySpacesForWindows")
        setFront = sym(sl, "_SLPSSetFrontProcessWithOptions")
        postEvent = sym(sl, "SLPSPostEventRecordTo")
        getPSN = sym(nil, "GetProcessForPID")          // RTLD_DEFAULT
        axGetWindow = sym(nil, "_AXUIElementGetWindow")
    }

    func windows() -> [Win]? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let cid = mainConn?() ?? 0
        let spaceIndex = spaceIndexes(cid)
        let apps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isHidden }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { a, _ in a })
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let trusted = AXIsProcessTrusted()
        let canReadNames = CGPreflightScreenCaptureAccess()

        var axCache: [pid_t: [UInt32: AXUIElement]] = [:]
        var focusTaken = false
        var out: [Win] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let wid = (info[kCGWindowNumber as String] as? Int).map(UInt32.init),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = apps[pid],
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 60, frame.height >= 60 else { continue }

            // Windows that belong to no Space are minimized or otherwise not
            // really there (offscreen buffers, closed-but-cached windows).
            let spaces = spacesFor(cid, wid)
            guard copySpacesForWindows == nil || !spaces.isEmpty else { continue }

            // AX (current Space only) is authoritative: it can tell dialogs and
            // palettes apart, and has the full title (Chrome's includes the
            // profile). Elsewhere fall back to CG, whose names need Screen
            // Recording; with that granted, every real window has a name, so
            // nameless ones are helper surfaces (Chrome has a dozen of them).
            let cgName = info[kCGWindowName as String] as? String ?? ""
            var title = cgName
            if let el = trusted ? axWindows(pid, cache: &axCache)[wid] : nil {
                if let sub = attr(el, kAXSubroleAttribute) as? String, sub != kAXStandardWindowSubrole { continue }
                title = attr(el, kAXTitleAttribute) as? String ?? cgName
            } else if cgName.isEmpty && canReadNames {
                continue
            }

            let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            let focused = !focusTaken && onscreen && pid == front
            if focused { focusTaken = true }
            out.append(Win(id: wid, pid: pid, app: app.localizedName ?? "?", title: title,
                           space: spaces.compactMap { spaceIndex[$0] }.first ?? 0,
                           frame: frame, hasFocus: focused))
        }
        return out
    }

    func focus(_ w: Win) {
        var psn = [UInt32](repeating: 0, count: 2)
        let ok = psn.withUnsafeMutableBytes { p -> Bool in
            guard let getPSN, let setFront, let base = p.baseAddress,
                  getPSN(w.pid, base) == noErr else { return false }
            _ = setFront(base, w.id, 0x200) // kCPSUserGenerated
            for kind: UInt8 in [1, 2] {
                var bytes = [UInt8](repeating: 0, count: 0xf8)
                bytes[0x04] = 0xf8
                bytes[0x08] = kind
                bytes[0x3a] = 0x10
                withUnsafeBytes(of: w.id.littleEndian) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
                for i in 0x20..<0x30 { bytes[i] = 0xff }
                bytes.withUnsafeMutableBytes { _ = postEvent?(base, $0.baseAddress!) }
            }
            return true
        }
        if !ok { NSRunningApplication(processIdentifier: w.pid)?.activate() }
        var cache: [pid_t: [UInt32: AXUIElement]] = [:]
        if let el = axWindows(w.pid, cache: &cache)[w.id] {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        }
    }

    // MARK: helpers

    private func spaceIndexes(_ cid: Int32) -> [UInt64: Int] {
        guard let displays = copyDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var map: [UInt64: Int] = [:]
        var i = 0
        for d in displays {
            for s in d["Spaces"] as? [[String: Any]] ?? [] {
                i += 1
                if let id = s["ManagedSpaceID"] as? Int ?? s["id64"] as? Int { map[UInt64(id)] = i }
            }
        }
        return map
    }

    private func spacesFor(_ cid: Int32, _ wid: UInt32) -> [UInt64] {
        guard let fn = copySpacesForWindows,
              let arr = fn(cid, 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return arr.map(\.uint64Value)
    }

    /// AX only sees windows on the current Space, which is fine: it's used to
    /// fill in titles/subroles where possible and to raise after focusing.
    private func axWindows(_ pid: pid_t, cache: inout [pid_t: [UInt32: AXUIElement]]) -> [UInt32: AXUIElement] {
        if let c = cache[pid] { return c }
        var map: [UInt32: AXUIElement] = [:]
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let axGetWindow, let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
            for w in wins {
                var id: UInt32 = 0
                if axGetWindow(w, &id) == .success { map[id] = w }
            }
        }
        cache[pid] = map
        return map
    }

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }
}
