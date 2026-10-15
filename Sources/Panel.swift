import AppKit

/// Overall size multiplier, from the config's "scale" (re-read on every open).
var scale: CGFloat = 1.2

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class Panel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

// App icons load lazily and draw blank on first use, so rasterize them once
// into a cache (pre-warmed at startup) instead of handing NSImageView the
// running app's icon directly.
private var iconCache: [pid_t: NSImage] = [:]

@discardableResult
func appIcon(_ pid: pid_t) -> NSImage? {
    if let cached = iconCache[pid] { return cached }
    guard let src = NSRunningApplication(processIdentifier: pid)?.icon,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    src.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: NSSize(width: 64, height: 64))
    img.addRepresentation(rep)
    iconCache[pid] = img
    return img
}

/// Chromium-style titles end in " - <App>", or " - <App> - <Profile>" once
/// more than one browser profile exists. Split that off so the profile is
/// shown on its own and the redundant app name is dropped from the title.
func splitTitle(_ w: Win) -> (title: String, profile: String?) {
    let pattern = "^(.*) - \(NSRegularExpression.escapedPattern(for: w.app))(?: - (.+))?$"
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: w.title, range: NSRange(w.title.startIndex..., in: w.title)) else {
        return (w.title, nil)
    }
    func group(_ i: Int) -> String? { Range(m.range(at: i), in: w.title).map { String(w.title[$0]) } }
    return (group(1) ?? w.title, group(2))
}

/// The title worth showing next to the app name: without a browser profile
/// suffix, and empty when it would only repeat the app name.
func displayTitle(_ w: Win) -> (title: String, profile: String?) {
    let (title, profile) = splitTitle(w)
    return (title.caseInsensitiveCompare(w.app) == .orderedSame ? "" : title, profile)
}

func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

final class Switcher: NSObject, NSWindowDelegate {
    let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
    private var targets: [Character: Win] = [:]
    private var backend: Backend = NativeBackend.shared
    /// The previously focused window: Tab jumps there, like a quick Alt+Tab.
    private var recentWin: Win?

    override init() {
        super.init()
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onKey = { [weak self] in self?.handle($0) }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    func hide() { panel.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { hide(); return } // Escape
        if event.keyCode == 48 { // Tab
            if let w = recentWin {
                hide()
                backend.focus(w)
            }
            return
        }
        guard let c = event.charactersIgnoringModifiers?.lowercased().first,
              let w = targets[c] else { return }
        hide()
        backend.focus(w)
    }

    func show() {
        let config = loadConfig()
        scale = CGFloat(config.scale ?? 1.2)
        let (backend, list) = entries(config)
        self.backend = backend
        targets = Dictionary(list.map { ($0.key, $0.win) }, uniquingKeysWith: { a, _ in a })
        recentWin = backend.recent(list.map(\.win))

        let screen = targetScreen(list.first { $0.win.hasFocus }?.win) ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let content = config.layout == "list" ? listView(list) : keyboardView(list, maxWidth: vf.width * 0.9)

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12 * scale
        bg.layer?.masksToBounds = true
        // Dark tint so whatever's behind the panel doesn't bleed through the blur.
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            content.topAnchor.constraint(equalTo: bg.topAnchor),
            content.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        panel.contentView = bg
        bg.layoutSubtreeIfNeeded()
        let size = content.fittingSize

        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height / 8,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// CG frames have their origin at the top-left of the primary display;
    /// NSScreen frames are flipped (origin bottom-left).
    private func targetScreen(_ w: Win?) -> NSScreen? {
        guard let w, let primary = NSScreen.screens.first else { return nil }
        let p = NSPoint(x: w.frame.midX, y: primary.frame.height - w.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(p) }
    }

    // MARK: Keyboard layout

    private func keyboardView(_ list: [Entry], maxWidth: CGFloat) -> NSView {
        let byKey = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // Row stagger in key widths, roughly as on a real keyboard. The number
        // row only appears when a window actually landed on a digit.
        var rows: [(keys: String, offset: CGFloat)] = [("qwertyuiop", 0.5), ("asdfghjkl", 0.75), ("zxcvbnm", 1.25)]
        if list.contains(where: { $0.key.isNumber }) { rows.insert(("1234567890", 0), at: 0) }
        let minOffset = rows.map(\.offset).min()!
        let units = rows.map { $0.offset - minOffset + CGFloat($0.keys.count) }.max()!

        let pad = 14 * scale, gap = 6 * scale
        let s = min(78 * scale, (maxWidth - 2 * pad + gap) / units - gap)
        let unit = s + gap

        let v = FlippedView()
        for (r, row) in rows.enumerated() {
            for (i, c) in row.keys.enumerated() {
                let tile = keyTile(c, byKey[c], size: s)
                tile.setFrameOrigin(NSPoint(x: pad + (row.offset - minOffset + CGFloat(i)) * unit,
                                            y: pad + CGFloat(r) * unit))
                v.addSubview(tile)
            }
        }
        v.widthAnchor.constraint(equalToConstant: 2 * pad + units * unit - gap).isActive = true
        v.heightAnchor.constraint(equalToConstant: 2 * pad + CGFloat(rows.count) * unit - gap).isActive = true
        return v
    }

    private func keyTile(_ c: Character, _ e: Entry?, size s: CGFloat) -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        v.wantsLayer = true
        v.layer?.cornerRadius = s * 0.14
        v.layer?.borderWidth = 1
        let letter = String(c).uppercased()

        guard let e else {
            v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
            v.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
            let l = tileLabel(letter, size: s * 0.22, weight: .semibold, color: .white.withAlphaComponent(0.2))
            l.frame = NSRect(x: 0, y: (s - s * 0.3) / 2, width: s, height: s * 0.3)
            v.addSubview(l)
            return v
        }

        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
        v.layer?.borderColor = (e.win.hasFocus ? NSColor.controlAccentColor : .white.withAlphaComponent(0.2)).cgColor
        if e.win.hasFocus { v.layer?.borderWidth = 2 }

        let l = tileLabel(letter, size: s * 0.2, weight: .heavy, color: .systemYellow)
        l.alignment = .left
        l.frame = NSRect(x: s * 0.08, y: s * 0.04, width: s * 0.4, height: s * 0.27)
        v.addSubview(l)

        if e.win.id == recentWin?.id {
            let tab = tileLabel("⇥", size: s * 0.17, weight: .bold, color: .white.withAlphaComponent(0.6))
            tab.alignment = .right
            tab.frame = NSRect(x: s * 0.5, y: s * 0.05, width: s * 0.42, height: s * 0.24)
            v.addSubview(tab)
        }

        let iconSize = s * 0.38
        let icon = NSImageView(frame: NSRect(x: (s - iconSize) / 2, y: s * 0.17, width: iconSize, height: iconSize))
        icon.image = appIcon(e.win.pid)
        icon.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(icon)

        let (title, profile) = displayTitle(e.win)
        let name = tileLabel(e.win.app, size: s * 0.13, weight: .semibold, color: .white)
        name.frame = NSRect(x: 3, y: s * 0.57, width: s - 6, height: s * 0.19)
        v.addSubview(name)

        let sub = tileLabel(profile ?? title, size: s * 0.11, weight: .regular,
                            color: profile != nil ? .systemTeal : .white.withAlphaComponent(0.55))
        sub.frame = NSRect(x: 3, y: s * 0.76, width: s - 6, height: s * 0.17)
        v.addSubview(sub)
        return v
    }

    private func tileLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = label(text, font: .systemFont(ofSize: size, weight: weight), color: color)
        l.alignment = .center
        return l
    }

    // MARK: List layout

    private func listView(_ list: [Entry]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6 * scale
        stack.edgeInsets = NSEdgeInsets(top: 12 * scale, left: 14 * scale, bottom: 12 * scale, right: 14 * scale)
        if list.isEmpty {
            stack.addArrangedSubview(label("No windows", font: .systemFont(ofSize: 14 * scale),
                                           color: .secondaryLabelColor))
        }
        for e in list { stack.addArrangedSubview(row(e)) }
        stack.widthAnchor.constraint(equalToConstant: 640 * scale).isActive = true
        return stack
    }

    private func keycap(_ c: Character) -> NSView {
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        cap.layer?.borderWidth = 1
        cap.layer?.cornerRadius = 6 * scale
        let l = label(String(c).uppercased(), font: .systemFont(ofSize: 15 * scale, weight: .heavy), color: .systemYellow)
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(l)
        NSLayoutConstraint.activate([
            cap.widthAnchor.constraint(equalToConstant: 28 * scale),
            cap.heightAnchor.constraint(equalToConstant: 26 * scale),
            l.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        ])
        return cap
    }

    /// App name with the assigned letter underlined and colored where it
    /// occurs in the name, like a menu mnemonic.
    private func mnemonic(_ name: String, _ c: Character) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14 * scale, weight: .semibold)
        let s = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let i = name.firstIndex(where: { $0.lowercased().first == c }) {
            s.addAttributes([.foregroundColor: NSColor.systemYellow,
                             .underlineStyle: NSUnderlineStyle.thick.rawValue,
                             .font: NSFont.systemFont(ofSize: 14 * scale, weight: .heavy)],
                            range: NSRange(i...i, in: name))
        }
        return s
    }

    private func row(_ e: Entry) -> NSView {
        let key = keycap(e.key)

        let icon = NSImageView()
        icon.image = appIcon(e.win.pid)
        icon.widthAnchor.constraint(equalToConstant: 20 * scale).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20 * scale).isActive = true

        let app = NSTextField(labelWithAttributedString: mnemonic(e.win.app, e.key))
        app.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let (text, profile) = displayTitle(e.win)
        let title = label(text, font: .systemFont(ofSize: 13 * scale), color: .secondaryLabelColor)
        let space = label(e.win.space > 0 ? "\(e.win.space)" : "",
                          font: .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .regular),
                          color: .tertiaryLabelColor)
        space.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        var views: [NSView] = [key, icon, app]
        if let profile {
            let p = label(profile, font: .systemFont(ofSize: 13 * scale, weight: .medium), color: .systemTeal)
            p.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            views.append(p)
        }
        views += [title, spacer]
        if e.win.id == recentWin?.id {
            views.append(label("⇥ tab", font: .systemFont(ofSize: 12 * scale, weight: .semibold),
                               color: .secondaryLabelColor))
        }
        let r = NSStackView(views: views + [space])
        r.orientation = .horizontal
        r.spacing = 8 * scale
        r.widthAnchor.constraint(equalToConstant: (640 - 28) * scale).isActive = true
        return r
    }
}
