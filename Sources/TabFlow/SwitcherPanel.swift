import Cocoa

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

struct CellMetrics {
    var cellW: CGFloat, cellH: CGFloat
    var thumbW: CGFloat, thumbH: CGFloat
    var icon: CGFloat, font: CGFloat

    static func make(style: SwitcherStyle, size: SizePreset, scale: CGFloat, screenWidth: CGFloat) -> CellMetrics {
        let k = size.factor * scale
        switch style {
        case .thumbnails:
            let tw = (230 * k).rounded(), th = (tw * 0.62).rounded()
            return CellMetrics(cellW: tw + 16, cellH: th + 16 + 26, thumbW: tw, thumbH: th, icon: 18, font: 12)
        case .icons:
            let ic = (84 * k).rounded()
            return CellMetrics(cellW: ic + 40, cellH: ic + 16 + 26, thumbW: 0, thumbH: 0, icon: ic, font: 11)
        case .list:
            let rh = (36 * size.factor * max(scale, 0.7)).rounded()
            return CellMetrics(cellW: min(760, screenWidth * 0.6), cellH: rh, thumbW: 0, thumbH: 0, icon: rh - 10, font: 13)
        }
    }
}

final class SwitcherPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private let container = FlippedView()
    private var cells: [WindowCell] = []
    private let header = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No matching windows")
    private(set) var columns = 1
    private(set) var thumbPixelWidth = 480

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = SwitcherPanel.roundedMask(radius: 18)
        contentView = effect
        container.frame = effect.bounds
        container.autoresizingMask = [.width, .height]
        effect.addSubview(container)

        for f in [header, footer, emptyLabel] {
            f.isHidden = true
            f.alignment = .center
            f.lineBreakMode = .byTruncatingTail
            container.addSubview(f)
        }
        header.font = .systemFont(ofSize: 16, weight: .semibold)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    func render(items: [WindowItem], selected: Int, screen: NSScreen, settings s: Settings, query: String, searching: Bool) {
        switch s.theme {
        case .system: appearance = nil
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        }
        cells.forEach { $0.removeFromSuperview() }
        cells = []

        let vf = screen.visibleFrame
        let pad: CGFloat = 16
        let headerH: CGFloat = searching ? 36 : 0
        let footerH: CGFloat = s.showHintBar ? 24 : 0
        let spacing: CGFloat = s.style == .list ? 2 : 8
        let maxW = vf.width * 0.92, maxH = vf.height * 0.88
        let n = max(items.count, 1)

        var scale: CGFloat = 1
        var m = CellMetrics.make(style: s.style, size: s.size, scale: 1, screenWidth: vf.width)
        var cols = 1, rows = 1
        for _ in 0..<12 {
            m = CellMetrics.make(style: s.style, size: s.size, scale: scale, screenWidth: vf.width)
            cols = s.style == .list ? 1 : max(1, min(n, Int((maxW - 2 * pad + spacing) / (m.cellW + spacing))))
            rows = Int((Double(n) / Double(cols)).rounded(.up))
            let h = CGFloat(rows) * (m.cellH + spacing) - spacing + 2 * pad + headerH + footerH
            if h <= maxH || scale < 0.3 { break }
            scale *= 0.87
        }
        columns = cols
        thumbPixelWidth = max(120, Int(m.thumbW * screen.backingScaleFactor))

        let gridW = CGFloat(cols) * (m.cellW + spacing) - spacing
        let minW: CGFloat = (searching || items.isEmpty || s.showHintBar) ? 560 : 0
        let W = min(max(gridW + 2 * pad, minW), maxW)
        let gridH: CGFloat = items.isEmpty ? 40 : CGFloat(rows) * (m.cellH + spacing) - spacing
        let H = min(gridH + 2 * pad + headerH + footerH, maxH)
        let top = pad + headerH

        header.isHidden = !searching
        if searching {
            header.stringValue = query.isEmpty ? "🔍  Type to search windows and apps…" : "🔍  \(query)"
            header.textColor = query.isEmpty ? .secondaryLabelColor : .labelColor
            header.frame = NSRect(x: pad, y: pad - 2, width: W - 2 * pad, height: 24)
        }
        footer.isHidden = !s.showHintBar
        if s.showHintBar {
            footer.stringValue = searching
                ? "Type to filter  ·  ←↑↓→ move  ·  ↩ open  ·  esc clear / cancel"
                : "⇥ next  ·  1–9 jump  ·  Q quit  W close  M min  H hide  F full  ·  Space search  ·  esc"
            footer.frame = NSRect(x: pad, y: H - footerH - 4, width: W - 2 * pad, height: 16)
        }
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.frame = NSRect(x: pad, y: top + 10, width: W - 2 * pad, height: 20)

        for (i, item) in items.enumerated() {
            let r = i / cols, c = i % cols
            let inRow = (r == rows - 1) ? n - r * cols : cols
            let rowW = CGFloat(inRow) * (m.cellW + spacing) - spacing
            let x0 = s.style == .list ? pad : (W - rowW) / 2
            let frame = NSRect(x: x0 + CGFloat(c) * (m.cellW + spacing),
                               y: top + CGFloat(r) * (m.cellH + spacing),
                               width: s.style == .list ? W - 2 * pad : m.cellW, height: m.cellH)
            if frame.maxY > H - footerH { break }
            let cell = WindowCell(frame: frame, item: item, index: i, style: s.style, metrics: m, settings: s)
            cell.onHover = { [weak self] i in self?.onHover?(i) }
            cell.onClick = { [weak self] i in self?.onClick?(i) }
            cell.onClose = { [weak self] i in self?.onClose?(i) }
            container.addSubview(cell)
            cells.append(cell)
        }
        setSelected(selected)

        let yShift: CGFloat = s.style == .list ? vf.height * 0.08 : 0
        let origin = NSPoint(x: (vf.midX - W / 2).rounded(), y: (vf.midY - H / 2 + yShift).rounded())
        setFrame(NSRect(origin: origin, size: NSSize(width: W, height: H)), display: true)
        if !isVisible { orderFrontRegardless() }
    }

    func setSelected(_ i: Int) {
        for c in cells { c.selected = (c.index == i) }
    }

    func setThumbnail(_ img: CGImage, for wid: CGWindowID) {
        for c in cells where c.item.wid == wid { c.setThumbnail(img) }
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class WindowCell: FlippedView {
    let item: WindowItem
    let index: Int
    private let style: SwitcherStyle
    private let m: CellMetrics
    private let thumbView = NSView()
    private let bigIcon = NSImageView()
    private let smallIcon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = FirstMouseButton()
    private var hovering = false

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var selected = false { didSet { if selected != oldValue { refreshBackground() } } }

    init(frame: NSRect, item: WindowItem, index: Int, style: SwitcherStyle, metrics: CellMetrics, settings s: Settings) {
        self.item = item; self.index = index; self.style = style; self.m = metrics
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = style == .list ? 7 : 11
        toolTip = item.isWindowless ? item.appName : "\(item.appName) — \(item.title)"
        switch style {
        case .thumbnails: buildThumbnail(s)
        case .icons: buildIcon(s)
        case .list: buildList(s)
        }
        if s.showCloseButtons && !item.isWindowless && item.ax != nil {
            closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")
            closeButton.isBordered = false
            closeButton.imageScaling = .scaleProportionallyUpOrDown
            closeButton.contentTintColor = .secondaryLabelColor
            closeButton.target = self
            closeButton.action = #selector(closeClicked)
            closeButton.isHidden = true
            closeButton.toolTip = "Close window (W)"
            addSubview(closeButton)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refreshBackground()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var dimmed: Bool { item.isMinimized || item.isAppHidden || item.isWindowless }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.cell?.truncatesLastVisibleLine = true
        return f
    }

    private func pill(_ text: String, size: CGFloat = 10) -> NSTextField {
        let f = makeLabel(" \(text) ", size: size, weight: .semibold, color: .white)
        f.drawsBackground = false
        f.wantsLayer = true
        f.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        f.layer?.cornerRadius = 4
        f.sizeToFit()
        return f
    }

    private func buildThumbnail(_ s: Settings) {
        let tr = NSRect(x: 8, y: 8, width: m.thumbW, height: m.thumbH)
        thumbView.frame = tr
        thumbView.wantsLayer = true
        thumbView.layer?.contentsGravity = .resizeAspect
        thumbView.layer?.cornerRadius = 6
        thumbView.layer?.masksToBounds = true
        thumbView.alphaValue = dimmed ? 0.55 : 1
        addSubview(thumbView)

        let iconSize = min(m.thumbH * 0.6, 112)
        bigIcon.frame = NSRect(x: tr.midX - iconSize / 2, y: tr.midY - iconSize / 2, width: iconSize, height: iconSize)
        bigIcon.image = item.icon
        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        bigIcon.alphaValue = dimmed ? 0.6 : 1
        addSubview(bigIcon)
        if let t = item.thumbnail { setThumbnail(t) }

        smallIcon.frame = NSRect(x: 8, y: tr.maxY + 5, width: 18, height: 18)
        smallIcon.image = item.icon
        smallIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(smallIcon)

        let title = makeLabel(item.isWindowless ? item.appName : item.title, size: m.font, weight: .medium)
        title.frame = NSRect(x: 30, y: tr.maxY + 5, width: bounds.width - 38, height: 18)
        addSubview(title)

        if s.showBadges, !item.badges.isEmpty {
            let b = pill(item.badges.joined(separator: " · "))
            b.frame.origin = NSPoint(x: tr.minX + 5, y: tr.maxY - b.frame.height - 5)
            b.frame.size.width = min(b.frame.width, tr.width - 10)
            addSubview(b)
        }
        if s.showNumberHints, index < 9 {
            let n = pill("\(index + 1)", size: 11)
            n.frame.origin = NSPoint(x: tr.minX + 5, y: tr.minY + 5)
            addSubview(n)
        }
        closeButton.frame = NSRect(x: tr.maxX - 24, y: tr.minY + 4, width: 20, height: 20)
    }

    private func buildIcon(_ s: Settings) {
        bigIcon.frame = NSRect(x: (bounds.width - m.icon) / 2, y: 8, width: m.icon, height: m.icon)
        bigIcon.image = item.icon
        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        bigIcon.alphaValue = dimmed ? 0.5 : 1
        addSubview(bigIcon)
        let title = makeLabel(item.isWindowless ? item.appName : item.title, size: m.font, weight: .medium)
        title.alignment = .center
        title.frame = NSRect(x: 4, y: 8 + m.icon + 6, width: bounds.width - 8, height: 16)
        addSubview(title)
        if s.showNumberHints, index < 9 {
            let n = pill("\(index + 1)", size: 10)
            n.frame.origin = NSPoint(x: 4, y: 4)
            addSubview(n)
        }
        if s.showBadges, item.isMinimized || item.isAppHidden || !item.isOnCurrentSpace {
            let dot = pill(item.isMinimized ? "–" : item.isAppHidden ? "H" : (item.spaceLabel.map { $0.replacingOccurrences(of: "Desktop ", with: "D") } ?? "•"), size: 10)
            dot.frame.origin = NSPoint(x: bounds.width - dot.frame.width - 4, y: 8 + m.icon - dot.frame.height)
            addSubview(dot)
        }
        closeButton.frame = NSRect(x: bounds.width - 22, y: 3, width: 18, height: 18)
    }

    private func buildList(_ s: Settings) {
        let h = bounds.height
        smallIcon.frame = NSRect(x: 8, y: (h - m.icon) / 2, width: m.icon, height: m.icon)
        smallIcon.image = item.icon
        smallIcon.imageScaling = .scaleProportionallyUpOrDown
        smallIcon.alphaValue = dimmed ? 0.5 : 1
        addSubview(smallIcon)

        var right = bounds.width - 10
        if s.showNumberHints, index < 9 {
            let n = makeLabel("\(index + 1)", size: 12, weight: .semibold, color: .tertiaryLabelColor)
            n.sizeToFit()
            n.frame.origin = NSPoint(x: right - n.frame.width, y: (h - n.frame.height) / 2)
            addSubview(n)
            right -= n.frame.width + 10
        }
        closeButton.frame = NSRect(x: right - 18, y: (h - 18) / 2, width: 18, height: 18)
        right -= 26

        var sub = item.appName
        if s.showBadges, !item.badges.isEmpty { sub += "  ·  " + item.badges.joined(separator: " · ") }
        let subField = makeLabel(sub, size: m.font - 2, color: .secondaryLabelColor)
        subField.alignment = .right
        let subW: CGFloat = min(260, bounds.width * 0.35)
        subField.frame = NSRect(x: right - subW, y: (h - 15) / 2, width: subW, height: 15)
        addSubview(subField)

        let x = 16 + m.icon
        let title = makeLabel(item.isWindowless ? item.appName : item.title, size: m.font, weight: .medium)
        title.frame = NSRect(x: x, y: (h - 18) / 2, width: max(40, right - subW - x - 8), height: 18)
        addSubview(title)
    }

    func setThumbnail(_ img: CGImage) {
        guard style == .thumbnails else { return }
        thumbView.layer?.contents = img
        bigIcon.isHidden = true
        // keep a small app icon overlay so apps stay recognizable
        if smallBadgeIcon == nil {
            let iv = NSImageView(frame: NSRect(x: thumbView.frame.maxX - 34, y: thumbView.frame.maxY - 34, width: 30, height: 30))
            iv.image = item.icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            addSubview(iv)
            if closeButton.superview != nil { addSubview(closeButton) } // keep close button on top
            smallBadgeIcon = iv
        }
    }
    private var smallBadgeIcon: NSImageView?

    private func refreshBackground() {
        guard let layer else { return }
        if selected {
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
            layer.borderColor = NSColor.controlAccentColor.cgColor
            layer.borderWidth = 2
        } else if hovering {
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            layer.borderWidth = 0
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        closeButton.isHidden = false
        refreshBackground()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        closeButton.isHidden = true
        refreshBackground()
    }
    override func mouseMoved(with event: NSEvent) { onHover?(index) }
    override func mouseDown(with event: NSEvent) { onClick?(index) }

    @objc private func closeClicked() { onClose?(index) }
}
