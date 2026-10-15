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
    /// The window that was focused before the current one (Tab's target).
    func recent(_ wins: [Win]) -> Win?
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

    func recent(_ wins: [Win]) -> Win? {
        guard let path = Self.path,
              let data = run(path, ["-m", "query", "--windows", "--window", "recent"]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int else { return nil }
        return wins.first { $0.id == UInt32(id) && !$0.hasFocus }
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
    private typealias CreateWithTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private let mainConn: MainConnFn?
    private let copyDisplaySpaces: CopyDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let setFront: SetFrontFn?
    private let postEvent: PostEventFn?
    private let getPSN: GetPSNFn?
    private let axGetWindow: AXGetWindowFn?
    private let createWithToken: CreateWithTokenFn?

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
        createWithToken = sym(nil, "_AXUIElementCreateWithRemoteToken")
        observeActivations()
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

        struct Candidate { let wid: UInt32; let pid: pid_t; let app: NSRunningApplication
                           let frame: CGRect; let spaces: [UInt64]; let cgName: String; let onscreen: Bool }
        var candidates: [Candidate] = []
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
            candidates.append(Candidate(wid: wid, pid: pid, app: app, frame: frame, spaces: spaces,
                                        cgName: info[kCGWindowName as String] as? String ?? "",
                                        onscreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }

        if trusted { resolveAX(Dictionary(grouping: candidates.map { ($0.pid, $0.wid) }, by: \.0)) }

        var focusTaken = false
        var out: [Win] = []
        for c in candidates {
            // With Accessibility, a CG window with no AX window behind it is a
            // helper surface (Chrome keeps a dozen); AX also has the window
            // type and the full title (Chrome's includes the profile). Without
            // it, fall back to CG names, which need Screen Recording; when
            // those are readable every real window has one.
            var title = c.cgName
            if trusted {
                guard let el = axKnown[c.wid] else { continue }
                if let sub = attr(el, kAXSubroleAttribute) as? String, sub != kAXStandardWindowSubrole { continue }
                title = attr(el, kAXTitleAttribute) as? String ?? c.cgName
            } else if c.cgName.isEmpty && canReadNames {
                continue
            }

            let focused = !focusTaken && c.onscreen && c.pid == front
            if focused {
                focusTaken = true
                noteFocused(c.wid)
            }
            out.append(Win(id: c.wid, pid: c.pid, app: c.app.localizedName ?? "?", title: title,
                           space: c.spaces.compactMap { spaceIndex[$0] }.first ?? 0,
                           frame: c.frame, hasFocus: focused))
        }
        return out
    }

    // MARK: AX window resolution

    /// window id → AX element, across all Spaces. Elements stay valid for the
    /// window's lifetime, so each window is resolved once.
    private var axKnown: [UInt32: AXUIElement] = [:]
    /// Window ids with no AX window behind them, and when that was decided
    /// (rechecked after a while, in case AX just hadn't caught up yet).
    private var axMissing: [UInt32: Date] = [:]

    private func resolveAX(_ byPid: [pid_t: [(pid_t, UInt32)]]) {
        let now = Date()
        for (pid, pairs) in byPid {
            let unknown = pairs.map(\.1).filter { wid in
                axKnown[wid] == nil && (axMissing[wid].map { now.timeIntervalSince($0) > 10 } ?? true)
            }
            guard !unknown.isEmpty else { continue }
            // kAXWindows is cheap but only covers the current Space; only
            // brute-force the app's AX element ids when something's still
            // missing (windows on other Spaces).
            var cache: [pid_t: [UInt32: AXUIElement]] = [:]
            axKnown.merge(axWindows(pid, cache: &cache)) { $1 }
            if unknown.contains(where: { axKnown[$0] == nil }) {
                axKnown.merge(bruteForceAXWindows(pid)) { $1 }
            }
            for wid in unknown where axKnown[wid] == nil { axMissing[wid] = now }
        }
        if axKnown.count > 2000 { axKnown.removeAll() }
        if axMissing.count > 2000 { axMissing.removeAll() }
    }

    /// AX hides windows on other Spaces from kAXWindows, but they can still
    /// be reached by forging the remote token AX uses to address elements:
    /// pid, 0, 0x636f636f ("coco"), element id. Window elements have small ids, so a scan
    /// of the first thousand finds them (the trick AltTab uses).
    private func bruteForceAXWindows(_ pid: pid_t) -> [UInt32: AXUIElement] {
        guard let createWithToken, let axGetWindow else { return [:] }
        var token = Data(count: 20)
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        token.replaceSubrange(8..<12, with: [0x6f, 0x63, 0x6f, 0x63])
        var map: [UInt32: AXUIElement] = [:]
        for id: UInt64 in 0..<1000 {
            withUnsafeBytes(of: id) { token.replaceSubrange(12..<20, with: $0) }
            guard let el = createWithToken(token as CFData)?.takeRetainedValue() else { continue }
            var wid: UInt32 = 0
            if axGetWindow(el, &wid) == .success, wid != 0,
               (attr(el, kAXRoleAttribute) as? String) == kAXWindowRole {
                map[wid] = el
            }
        }
        return map
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
        noteFocused(w.id)
    }

    // MARK: focus history

    /// Most recently focused window ids, newest first. Fed by app activations
    /// (whatever caused them), the focused window seen on each listing, and
    /// our own focus calls.
    private var mru: [UInt32] = []

    private func noteFocused(_ wid: UInt32) {
        mru.removeAll { $0 == wid }
        mru.insert(wid, at: 0)
        if mru.count > 64 { mru.removeLast() }
    }

    func recent(_ wins: [Win]) -> Win? {
        let byId = Dictionary(wins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return mru.lazy.compactMap { byId[$0] }.first { !$0.hasFocus }
    }

    private func observeActivations() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, AXIsProcessTrusted(), let axGetWindow = self.axGetWindow,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.2)
            var wid: UInt32 = 0
            if let focused = self.attr(el, kAXFocusedWindowAttribute),
               axGetWindow(focused as! AXUIElement, &wid) == .success, wid != 0 {
                self.noteFocused(wid)
            }
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
