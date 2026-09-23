import AppKit

/// Builds and presents the Claude Touch Bar (system-modal, full width) and its Control Strip tray button.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    enum ID {
        static let prefix = "com.verozhao.claude-touchbar."
        static let brand = NSTouchBarItem.Identifier(prefix + "brand")
        static let fiveHour = NSTouchBarItem.Identifier(prefix + "5h")
        static let week = NSTouchBarItem.Identifier(prefix + "week")
        static let model = NSTouchBarItem.Identifier(prefix + "model")
        static let context = NSTouchBarItem.Identifier(prefix + "context")
        static let activity = NSTouchBarItem.Identifier(prefix + "activity")
        static let info = NSTouchBarItem.Identifier(prefix + "info")
        static let approve = NSTouchBarItem.Identifier(prefix + "approve")
        static let deny = NSTouchBarItem.Identifier(prefix + "deny")
        static let terminal = NSTouchBarItem.Identifier(prefix + "terminal")
        static let tray = NSTouchBarItem.Identifier(prefix + "tray")
    }

    let touchBar = NSTouchBar()
    var onDecision: ((String, PermissionDecision) -> Void)?
    var onTrayTap: (() -> Void)?
    var onSelectSession: ((String?) -> Void)?
    private var displayedRequestId: String?

    /// One entry per live session in the picker popover.
    struct SessionChoice { let id: String; let title: String; let color: NSColor; let selected: Bool }
    private var choices: [SessionChoice] = []
    private var picking = false
    private static let choicePrefix = ID.prefix + "choice."
    private static let autoId = NSTouchBarItem.Identifier(ID.prefix + "choice.auto")

    /// Rebuilds the popover's buttons: one per session, plus "Auto" to go back to following
    /// whichever session needs the user most.
    func setSessions(_ list: [SessionChoice]) {
        let key = { (c: [SessionChoice]) in c.map { "\($0.id)|\($0.selected)|\($0.title)" }.joined() }
        guard key(list) != key(choices) else { return }
        choices = list
        if picking { showPicker() }   // keep an open picker in step with the sessions
    }

    /// The picker replaces the gauges for as long as it is open: a system-modal Touch Bar
    /// cannot show an NSPopoverTouchBarItem, so we swap this bar's own layout instead.
    private func showPicker() {
        var ids: [NSTouchBarItem.Identifier] = [ID.activity]
        for (i, _) in choices.enumerated().prefix(5) {
            ids.append(NSTouchBarItem.Identifier(TouchBarController.choicePrefix + "\(i)"))
        }
        ids.append(TouchBarController.autoId)
        picking = true
        // Rebuild every button: titles and colours change between openings.
        touchBar.templateItems = []
        touchBar.defaultItemIdentifiers = ids
    }

    private func closePicker() {
        picking = false
        touchBar.defaultItemIdentifiers = pendingLayout ? promptLayout : idleLayout
        applyPriorities(prompt: pendingLayout)
    }

    private let gaugeWidth: CGFloat = 130
    private lazy var g5h = GaugeView(title: "5h", width: gaugeWidth)
    private lazy var gWeek = GaugeView(title: "Week", width: gaugeWidth)
    private lazy var gModel = GaugeView(title: "Model", width: gaugeWidth)
    private lazy var gCtx = GaugeView(title: "Context", width: gaugeWidth)
    private lazy var activity = ActivityView(target: self, action: #selector(activityTapped))
    private lazy var info = InfoView(width: 340)
    private lazy var brand: NSTextField = {
        let l = NSTextField(labelWithString: "Claude")
        l.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        l.textColor = NSColor(srgbRed: 0.85, green: 0.55, blue: 0.35, alpha: 1)
        return l
    }()
    private lazy var approveButton = makeButton("Approve", color: NSColor(srgbRed: 0.20, green: 0.62, blue: 0.30, alpha: 1), action: #selector(approveTapped), width: 96)
    private lazy var denyButton = makeButton("Deny", color: NSColor(srgbRed: 0.75, green: 0.22, blue: 0.20, alpha: 1), action: #selector(denyTapped), width: 76)
    private lazy var terminalButton = makeButton("Terminal", color: nil, action: #selector(passTapped), width: 84)
    private lazy var trayButton: NSButton = {
        let b = NSButton(title: "C", target: self, action: #selector(trayTapped))
        b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        return b
    }()
    private var trayItem: NSCustomTouchBarItem?
    private var trayInstalled = false
    private(set) var isPresented = false
    private var pendingLayout = false

    /// true: present next to the macOS Control Strip (MTMR "show control strip" mode);
    /// false: `placement: 1`, which takes the whole bar.
    var keepControlStrip: Bool = true

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = idleLayout
    }

    private var idleLayout: [NSTouchBarItem.Identifier] {
        [ID.brand, ID.activity, ID.fiveHour, ID.week, ID.model, ID.context]
    }
    private var promptLayout: [NSTouchBarItem.Identifier] {
        [ID.activity, ID.fiveHour, ID.week, ID.model, ID.context, .flexibleSpace, ID.info, ID.approve, ID.deny, ID.terminal]
    }
    /// Which items NSTouchBar would keep at `width` points, honouring visibilityPriority (used by the snapshot only).
    private func fitted(_ ids: [NSTouchBarItem.Identifier], width: CGFloat, spacing: CGFloat) -> [NSTouchBarItem.Identifier] {
        var keep = ids
        func total() -> CGFloat {
            let vs = keep.compactMap { view(for: $0) }
            return vs.reduce(CGFloat(0)) { $0 + itemWidth($1) } + spacing * CGFloat(max(0, vs.count - 1))
        }
        while total() > width {
            let candidates = keep.filter { $0 != .flexibleSpace }
                .map { ($0, touchBar.item(forIdentifier: $0)?.visibilityPriority.rawValue ?? 0) }
                .filter { $0.1 < NSTouchBarItem.Priority.high.rawValue }
            guard let drop = candidates.min(by: { $0.1 < $1.1 })?.0 else { break }
            keep.removeAll { $0 == drop }
        }
        return keep
    }
    private func itemWidth(_ v: NSView) -> CGFloat {
        if v is NSButton { return v.fittingSize.width }   // honours the width constraint
        let i = v.intrinsicContentSize.width; return i > 0 ? i : v.fittingSize.width
    }

    private func makeButton(_ title: String, color: NSColor?, action: Selector, width: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelColor = color
        b.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        if color != nil {
            b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        return b
    }

    /// When a prompt is pending the buttons must fit even with the Control Strip visible,
    /// so the usage gauges become the first things NSTouchBar may hide.
    private func applyPriorities(prompt: Bool) {
        for (id, p) in priorities(prompt: prompt) { touchBar.item(forIdentifier: id)?.visibilityPriority = p }
    }

    /// Lower values get hidden first when the bar is too narrow (NSTouchBar semantics).
    private func priorities(prompt: Bool) -> [NSTouchBarItem.Identifier: NSTouchBarItem.Priority] {
        func P(_ v: Float) -> NSTouchBarItem.Priority { NSTouchBarItem.Priority(rawValue: v) }
        if prompt {
            return [ID.brand: P(-1000), ID.model: P(-950), ID.week: P(-900), ID.fiveHour: P(-850), ID.context: P(-500), ID.activity: P(-300),
                    ID.terminal: P(0), ID.info: P(1000), ID.approve: P(1000), ID.deny: P(1000)]
        }
        return [ID.brand: P(-1000), ID.model: P(-800), ID.week: P(0), ID.fiveHour: P(0), ID.context: P(0), ID.activity: P(900), ID.info: P(500)]
    }

    // MARK: NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == TouchBarController.autoId || identifier.rawValue.hasPrefix(TouchBarController.choicePrefix) {
            return sessionChoiceItem(identifier)
        }
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case ID.brand: item.view = brand; item.visibilityPriority = .low
        case ID.fiveHour: item.view = g5h; item.visibilityPriority = .high
        case ID.week: item.view = gWeek; item.visibilityPriority = .low
        case ID.model: item.view = gModel; item.visibilityPriority = .normal
        case ID.context: item.view = gCtx; item.visibilityPriority = .high
        case ID.activity: item.view = activity; item.visibilityPriority = .high
        case ID.info: item.view = info; item.visibilityPriority = .high
        case ID.approve: item.view = approveButton; item.visibilityPriority = .high
        case ID.deny: item.view = denyButton; item.visibilityPriority = .high
        case ID.terminal: item.view = terminalButton; item.visibilityPriority = .normal
        default: return nil
        }
        if let p = priorities(prompt: pendingLayout)[identifier] { item.visibilityPriority = p }
        return item
    }

    private func sessionChoiceItem(_ identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let b: NSButton
        if identifier == TouchBarController.autoId {
            b = NSButton(title: "Auto", target: self, action: #selector(sessionPicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier("auto")
        } else {
            let i = Int(identifier.rawValue.dropFirst(TouchBarController.choicePrefix.count)) ?? 0
            guard i < choices.count else { return nil }
            let c = choices[i]
            b = NSButton(title: (c.selected ? "▸ " : "") + c.title, target: self, action: #selector(sessionPicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(c.id)
            b.bezelColor = c.color.withAlphaComponent(c.selected ? 0.75 : 0.35)
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: c.selected ? .semibold : .regular)])
        }
        item.view = b
        return item
    }

    // MARK: content

    func update(usage: UsageSnapshot?, session: SessionStatus?, request: PermissionRequest?, queued: Int = 0, act: SessionActivity? = nil, actExtra: Int = 0, actBadge: String? = nil, alert: String? = nil, now: Date = Date()) {
        displayedRequestId = request?.id
        applyActivity(act, extra: actExtra, badge: actBadge, alert: alert, request: request, now: now)
        let stale = usage?.isStale ?? true
        func apply(_ g: GaugeView, _ l: UsageLimit?) {
            g.dimmed = stale || l == nil
            if let l = l {
                g.title = l.label
                g.percent = l.percent
                let reset = ResetFormat.short(l.resetsAt, now: now)
                let pct = "\(Int(l.percent.rounded()))%"
                g.shortValueText = pct
                g.valueText = reset.isEmpty ? pct : "\(pct) · \(reset)"
            } else {
                g.percent = nil
                g.valueText = usage == nil ? "…" : "–"
            }
        }
        // Claude Code's own status line carries live 5h / 7d numbers after every turn. Prefer them when
        // they are fresher than the API snapshot (and use them outright while the API is unavailable).
        var five = usage?.limit(.session), week = usage?.limit(.weeklyAll)
        var fromStatusLine = false
        if let s = session, now.timeIntervalSince(s.updatedAt) < 3600 {
            let apiAge = usage?.lastSuccessAt.map { now.timeIntervalSince($0) } ?? .infinity
            let statusAge = now.timeIntervalSince(s.updatedAt)
            if stale || statusAge < apiAge {
                if let p = s.fiveHourPercent { five = UsageLimit(kind: .session, label: "5h", percent: p, resetsAt: s.fiveHourResetsAt, severity: nil); fromStatusLine = true }
                if let p = s.sevenDayPercent { week = UsageLimit(kind: .weeklyAll, label: "Week", percent: p, resetsAt: s.sevenDayResetsAt, severity: nil); fromStatusLine = true }
            }
        }
        apply(g5h, five)
        apply(gWeek, week)
        apply(gModel, usage?.limit(.weeklyScoped))
        // The model-scoped weekly limit has no status-line fallback, so a rate-limited API would
        // leave it grey for hours. Keep the last known number lit and say how old it is instead.
        if let m = usage?.limit(.weeklyScoped) {
            gModel.dimmed = false
            if stale, let ok = usage?.lastSuccessAt {
                gModel.valueText = "\(Int(m.percent.rounded()))% · \(ResetFormat.elapsed(since: ok, now: now)) ago"
            }
        }
        if fromStatusLine { if five != nil { g5h.dimmed = false }; if week != nil { gWeek.dimmed = false } }

        if let s = session, let pct = s.contextUsedPercent {
            gCtx.dimmed = now.timeIntervalSince(s.updatedAt) > 3600
            gCtx.percent = pct
            gCtx.accent = pct >= 80 ? nil : NSColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 1)
            var size = ""
            if let cs = s.contextWindowSize { size = cs >= 1_000_000 ? " · \(cs / 1_000_000)M" : " · \(cs / 1000)k" }
            gCtx.shortValueText = "\(Int(pct.rounded()))%"
            gCtx.valueText = "\(Int(pct.rounded()))%\(size)"
        } else {
            gCtx.dimmed = true; gCtx.percent = nil; gCtx.valueText = "no session"
        }

        if let r = request {
            info.highlighted = true
            info.set(queued > 1 ? "\(r.headline)  (+\(queued - 1))" : r.headline)
        } else {
            info.highlighted = false
            if let e = usage?.error, usage?.isStale ?? true {
                info.set(e, color: NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1))
            } else if let s = session {
                var parts = [s.modelName]
                let name = TouchBarController.shortName(s)
                if !name.isEmpty { parts.append(name) }
                if let c = s.costUSD, c > 0 { parts.append(String(format: "$%.2f", c)) }
                info.set(parts.joined(separator: " · "), color: NSColor(white: 1, alpha: 0.85))
            } else {
                info.set("No active Claude Code session", color: NSColor(white: 1, alpha: 0.6))
            }
        }

        if let five = five ?? usage?.limit(.session) {
            trayButton.title = (usage?.isStale ?? true) && !fromStatusLine ? "C !" : "C \(Int(five.percent.rounded()))%"
        } else {
            trayButton.title = "C"
        }

        let wantPrompt = request != nil
        if wantPrompt && picking { closePicker() }   // a permission prompt outranks the picker
        if wantPrompt != pendingLayout && !picking {
            pendingLayout = wantPrompt
            touchBar.defaultItemIdentifiers = wantPrompt ? promptLayout : idleLayout
            applyPriorities(prompt: wantPrompt)
            NSLog("layout → %@", wantPrompt ? "prompt" : "idle")
        }
    }

    /// The left-hand pill: a coloured dot for what the session is doing. Kept dot-sized so the
    /// usage gauges keep their room; extra sessions add a small count.
    private func applyActivity(_ act: SessionActivity?, extra: Int, badge override: String?, alert: String?, request: PermissionRequest?, now: Date) {
        _ = (override, extra)   // the dot is colour only: counts live in the picker and the menu
        let badge = ""
        if request != nil {
            activity.set(state: .waiting, text: badge, tip: "Claude Code is waiting for your approval")
            return
        }
        // Nothing can run: say so in red, whatever the sessions think they are doing.
        if let alert = alert {
            activity.set(state: .error, text: badge, tip: alert)
            return
        }
        guard let a = act else {
            activity.set(state: nil, text: "", tip: "No Claude Code session running")
            return
        }
        // A "working" turn that has not checked in for a while is probably an abandoned terminal.
        let stalled = (a.state == .working && now.timeIntervalSince(a.at) > 20 * 60) || a.state == .unknown
        var tip = stalled ? "Working?" : a.state.label
        if a.agents > 0 { tip += " · \(a.agents) background agent\(a.agents == 1 ? "" : "s")" }
        if !a.shortCwd.isEmpty { tip += " · " + a.shortCwd }
        if extra > 0 { tip += " (+\(extra) more · tap to switch)" }
        activity.set(state: a.state, text: badge, tip: tip, hollow: stalled)
    }

    /// The session's name cut down to something that fits next to the model and the cost:
    /// its own name if it has one, otherwise the last path component of its directory.
    static func shortName(_ s: SessionStatus, limit: Int = 22) -> String {
        var name = s.sessionName ?? ""
        if name.isEmpty { name = String(s.shortCwd.split(separator: "/").last ?? "") }
        if name.count > limit { name = String(name.prefix(limit - 1)) + "…" }
        return name
    }

    // MARK: presentation (private API)

    func present() {
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
        let cls: AnyClass = NSTouchBar.self
        let hasPlacement = class_getClassMethod(cls, #selector(NSTouchBar.presentSystemModalTouchBar(_:placement:systemTrayItemIdentifier:))) != nil
        // Verified on this machine: the no-placement variant leaves the Control Strip visible;
        // placement 1 covers it. (Opposite of what Pock's naming suggests.)
        if keepControlStrip || !hasPlacement {
            NSTouchBar.presentSystemModalTouchBar(touchBar, systemTrayItemIdentifier: ID.tray)
        } else {
            NSTouchBar.presentSystemModalTouchBar(touchBar, placement: 1, systemTrayItemIdentifier: ID.tray)
        }
        isPresented = true
        NSLog("touch bar presented (control strip %@, visible=%d)", keepControlStrip ? "kept" : "hidden", touchBar.isVisible ? 1 : 0)
    }

    func dismiss() {
        NSTouchBar.dismissSystemModalTouchBar(touchBar)
        isPresented = false
    }

    /// Called when the bar went away without us dismissing it (close box, system).
    func markDismissed() { isPresented = false }

    func minimize() {
        NSTouchBar.minimizeSystemModalTouchBar(touchBar)
        isPresented = false
    }

    func installTray() {
        guard !trayInstalled else { return }
        let item = NSCustomTouchBarItem(identifier: ID.tray)
        item.view = trayButton
        trayItem = item
        NSTouchBarItem.addSystemTrayItem(item)
        DFRElementSetControlStripPresenceForIdentifier(ID.tray.rawValue, true)
        trayInstalled = true
    }

    func removeTray() {
        guard trayInstalled, let item = trayItem else { return }
        DFRElementSetControlStripPresenceForIdentifier(ID.tray.rawValue, false)
        NSTouchBarItem.removeSystemTrayItem(item)
        trayInstalled = false
    }

    func tearDown() {
        if isPresented { dismiss() }
        removeTray()
    }

    // MARK: offscreen snapshot (dev aid: CLAUDE_TOUCHBAR_SNAPSHOT=/path.png)

    private func view(for id: NSTouchBarItem.Identifier) -> NSView? {
        switch id {
        case ID.brand: return brand
        case ID.fiveHour: return g5h
        case ID.week: return gWeek
        case ID.model: return gModel
        case ID.context: return gCtx
        case ID.activity: return activity
        case ID.info: return info
        case ID.approve: return approveButton
        case ID.deny: return denyButton
        case ID.terminal: return terminalButton
        default: return nil
        }
    }

    /// Renders the current layout into a 2x PNG the way it would sit on a `width`-pt bar.
    func writeSnapshot(to path: String, width: CGFloat = 1004) {
        let spacing: CGFloat = 8
        // Make sure every item exists so priorities are set, then drop what would not fit.
        (pendingLayout ? promptLayout : idleLayout).forEach { _ = touchBar.item(forIdentifier: $0) }
        applyPriorities(prompt: pendingLayout)
        let ids = fitted(pendingLayout ? promptLayout : idleLayout, width: width, spacing: spacing)
        let widths = (pendingLayout ? promptLayout : idleLayout).compactMap { id in view(for: id).map { "\(id.rawValue.split(separator: ".").last ?? "")=\(Int(itemWidth($0)))" } }
        NSLog("snapshot widths: %@ | kept: %@", widths.joined(separator: " "), ids.map { String($0.rawValue.split(separator: ".").last ?? "") }.joined(separator: ","))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        let views: [(NSTouchBarItem.Identifier, NSView?)] = ids.map { ($0, view(for: $0)) }
        func w(_ v: NSView) -> CGFloat { itemWidth(v) }
        let real = views.compactMap { $0.1 }
        let fixed = real.reduce(CGFloat(0)) { $0 + w($1) } + spacing * CGFloat(max(0, real.count - 1))
        var x: CGFloat = 0
        for (id, v) in views {
            if id == .flexibleSpace { x += max(0, width - fixed); continue }
            guard let v = v else { continue }
            v.removeFromSuperview()
            v.frame = NSRect(x: x, y: 0, width: w(v), height: 30)
            container.addSubview(v)
            x += w(v) + spacing
        }
        container.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: 60, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: 30)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: width, height: 30).fill()
            for v in container.subviews {
                ctx.saveGraphicsState()
                let t = NSAffineTransform(); t.translateX(by: v.frame.minX, yBy: 0); t.concat()
                v.displayIgnoringOpacity(v.bounds, in: ctx)
                ctx.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            NSLog("snapshot written to %@", path)
        }
    }

    // MARK: actions

    @objc private func approveTapped() { if let id = displayedRequestId { onDecision?(id, .allow) } }
    @objc private func denyTapped() { if let id = displayedRequestId { onDecision?(id, .deny) } }
    @objc private func passTapped() { if let id = displayedRequestId { onDecision?(id, .pass) } }
    @objc private func trayTapped() { onTrayTap?() }
    @objc private func activityTapped() {
        NSLog("activity dot tapped (%d sessions)", choices.count)
        if picking { closePicker() } else if !choices.isEmpty { showPicker() }
    }

    @objc private func sessionPicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue
        NSLog("session picked: %@", id ?? "auto")
        closePicker()
        onSelectSession?(id == "auto" ? nil : id)
    }
}
