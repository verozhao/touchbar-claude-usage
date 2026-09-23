import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    let baseDir: URL = {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_TOUCHBAR_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/touchbar")
    }()
    private var config = Config()
    private var configURL: URL { baseDir.appendingPathComponent("config.json") }
    private var pidURL: URL { baseDir.appendingPathComponent("app.pid") }
    private var logURL: URL { baseDir.appendingPathComponent("app.log") }

    private let usage = UsageFetcher()
    private lazy var status = StatusStore(dir: baseDir.appendingPathComponent("status"))
    private lazy var perms = PermissionQueue(baseDir: baseDir)
    private lazy var activity = ActivityStore(dir: baseDir.appendingPathComponent("activity"))
    private let bar = TouchBarController()
    private var statusItem: NSStatusItem?
    private var usageTimer: Timer?
    private var tickTimer: Timer?
    private var heartbeatTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var snapshotMode = false
    private var userHid = false          // hidden from the tray button / menu: stay hidden until a prompt arrives
    private var forcedForPrompt = false  // we surfaced a hidden bar for a prompt; tuck it away afterwards
    private var lastRequestId: String?
    private var displayedSessionId: String?
    private var displayedSessionSince = Date.distantPast
    private var lastActivityKey: String?
    private var pinnedSessionId: String?   // set by tapping the activity dot

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        let fm = FileManager.default
        let priv: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        for sub in ["", "requests", "responses", "status", "activity"] {
            try? fm.createDirectory(at: baseDir.appendingPathComponent(sub), withIntermediateDirectories: true, attributes: priv)
        }
        for sub in ["", "requests", "responses", "status", "activity"] { try? fm.setAttributes(priv, ofItemAtPath: baseDir.appendingPathComponent(sub).path) }
        if !fm.fileExists(atPath: configURL.path) { config.save(to: configURL) }
        config = Config.load(from: configURL)
        let env = ProcessInfo.processInfo.environment
        snapshotMode = env["CLAUDE_TOUCHBAR_SNAPSHOT"] != nil
        if !snapshotMode {
            rotateLogIfNeeded()
            writeHeartbeat()
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.writeHeartbeat() }
            heartbeatTimer?.tolerance = 3
            installSignalHandlers()
        }

        if config.showMenuBar { setupStatusItem() }
        bar.keepControlStrip = config.keepControlStrip
        bar.onDecision = { [weak self] id, decision in self?.answer(id, decision) }
        bar.onActivityTap = { [weak self] in self?.cycleSession() }
        bar.onTrayTap = { [weak self] in
            guard let self = self else { return }
            if self.bar.isPresented { self.hideBar(byUser: true) } else { self.showBar() }
        }

        status.onChange = { [weak self] in self?.render() }
        activity.onChange = { [weak self] in self?.activityChanged() }
        perms.onChange = { [weak self] in self?.requestsChanged() }
        status.start()
        perms.start()
        activity.start()

        if let snap = env["CLAUDE_TOUCHBAR_SNAPSHOT"] {
            // Dev aid: render the bar offscreen (idle or prompt layout) and exit. Never touches the real Touch Bar.
            let fakeReq = env["CLAUDE_TOUCHBAR_SNAPSHOT_STATE"] == "prompt"
                ? PermissionRequest(id: "snap", createdAt: Date(), hookPid: 0, sessionId: nil, cwd: nil, toolName: "Bash",
                                    summary: "git push origin main --force-with-lease", description: nil) : nil
            usage.fetch { [weak self] snap0 in
                guard let self = self else { return }
                let fakeAct = ActivityState(rawValue: env["CLAUDE_TOUCHBAR_SNAPSHOT_ACTIVITY"] ?? "")
                    .map { SessionActivity(sessionId: "snap", state: $0, cwd: FileManager.default.currentDirectoryPath, message: nil, at: Date()) }
                self.bar.update(usage: snap0, session: self.status.current, request: fakeReq, act: fakeAct ?? self.activity.current)
                self.bar.writeSnapshot(to: snap, width: CGFloat(Double(env["CLAUDE_TOUCHBAR_SNAPSHOT_WIDTH"] ?? "") ?? 1004))
                NSApp.terminate(nil)
            }
            return
        }

        if config.showTray { bar.installTray() }
        render()
        bar.present()
        refreshUsage()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.render() }
        tickTimer?.tolerance = 5

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(wokeUp(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(wokeUp(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensSlept(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSLog("ClaudeTouchBar started (data: %@)", baseDir.path)
    }

    func applicationWillTerminate(_ notification: Notification) {
        bar.tearDown()
        // Only remove the pid file if it is ours (a second instance must not clobber the live one).
        if !snapshotMode, let mine = try? String(contentsOf: pidURL),
           Int32(mine.trimmingCharacters(in: .whitespacesAndNewlines)) == ProcessInfo.processInfo.processIdentifier {
            try? FileManager.default.removeItem(at: pidURL)
        }
    }

    /// launchctl bootout / pkill send SIGTERM: exit through AppKit so the pid file and tray item are cleaned up.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    private func rotateLogIfNeeded() {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
            let old = baseDir.appendingPathComponent("app.log.1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logURL, to: old)
        }
    }

    // MARK: heartbeat (app.pid)

    /// The hook trusts app.pid only while its mtime is fresh. We stop refreshing it when the
    /// built-in display is off (lid closed, display asleep) so prompts go straight to the terminal.
    private func writeHeartbeat() {
        guard touchBarUsable() else { return }
        keepAwakeIfWanted()
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: pidURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidURL.path)
    }

    /// macOS dims the Touch Bar after 60 s idle and blanks it at 75 s. Pinning the panel status
    /// (as Touch Bar Simulator did) keeps it at full brightness; status bit 4 means "system-managed".
    private var loggedKeepAwake = false
    private func keepAwakeIfWanted() {
        guard config.keepAwake else { return }
        let st = DFRGetStatus()
        if st & 4 != 0 || st & 1 == 0 {
            DFRSetStatus(2)
            if !loggedKeepAwake { NSLog("keep awake: panel status %d → %d", st, DFRGetStatus()); loggedKeepAwake = true }
        }
    }

    private func touchBarUsable() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return true }
        for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) != 0 {
            return CGDisplayIsAsleep(ids[i]) == 0
        }
        return false   // no active built-in display: clamshell mode
    }

    // MARK: data → UI

    private func refreshUsage() {
        usageTimer?.invalidate()
        usage.fetch { [weak self] snap in
            guard let self = self else { return }
            if let e = snap.error { NSLog("usage: %@", e) }
            else { NSLog("usage ok: %@", snap.limits.map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: ", ")) }
            self.render()
            let next = snap.retryAfter ?? self.config.refreshSeconds
            self.usageTimer = Timer.scheduledTimer(withTimeInterval: next, repeats: false) { [weak self] _ in self?.refreshUsage() }
            self.usageTimer?.tolerance = 5
        }
    }

    /// Which session's context to show: the one asking for permission, otherwise the most recently
    /// active one, with 5 s of hysteresis so two busy sessions do not make the gauge flicker.
    private func sessionToShow() -> SessionStatus? {
        let sessions = status.sessions
        if let pin = pinnedSessionId, let s = sessions.first(where: { $0.sessionId == pin }) { return s }
        if let sid = perms.first?.sessionId, let s = sessions.first(where: { $0.sessionId == sid }) {
            displayedSessionId = sid; displayedSessionSince = Date(); return s
        }
        guard let newest = tracked().first?.session ?? sessions.first else { displayedSessionId = nil; return nil }
        if let cur = displayedSessionId, cur != newest.sessionId, let shown = sessions.first(where: { $0.sessionId == cur }),
           newest.updatedAt.timeIntervalSince(shown.updatedAt) < 5 || Date().timeIntervalSince(displayedSessionSince) < 5 {
            return shown
        }
        if displayedSessionId != newest.sessionId { displayedSessionId = newest.sessionId; displayedSessionSince = Date() }
        return newest
    }

    /// Every live terminal, with what it is doing. Sessions that started before the activity hooks
    /// were installed have a status file but no activity file: they show as unknown rather than vanish.
    private func tracked() -> [(session: SessionStatus, act: SessionActivity)] {
        status.sessions.map { s in
            let a = activity.sessions.first(where: { $0.sessionId == s.sessionId })
                ?? SessionActivity(sessionId: s.sessionId, state: .unknown, cwd: s.cwd, message: nil, at: s.updatedAt)
            return (s, a)
        }.sorted { l, r in
            l.act.state.rank != r.act.state.rank ? l.act.state.rank < r.act.state.rank : l.session.updatedAt > r.session.updatedAt
        }
    }

    /// Tapping the dot walks through the live sessions (most recent first), then back to "follow
    /// whichever session is most interesting", so two terminals can share one bar.
    private func cycleSession() {
        let ids = tracked().map { $0.session.sessionId }
        guard ids.count > 1 else { pinnedSessionId = nil; render(); return }
        if let cur = pinnedSessionId, let i = ids.firstIndex(of: cur) {
            pinnedSessionId = i + 1 < ids.count ? ids[i + 1] : nil
        } else {
            pinnedSessionId = ids.first
        }
        NSLog("following session %@", pinnedSessionId ?? "auto")
        render()
    }

    private func render() {
        let live = tracked()
        if let pin = pinnedSessionId, !live.contains(where: { $0.session.sessionId == pin }) { pinnedSessionId = nil }
        let shown = sessionToShow()
        let act = live.first(where: { $0.session.sessionId == shown?.sessionId })?.act ?? live.first?.act
        let extra = max(0, live.count - 1)
        // While a session is pinned the dot shows its place in the list (2/3) instead of a count.
        var badge: String? = nil
        if let pin = pinnedSessionId, let i = live.firstIndex(where: { $0.session.sessionId == pin }) {
            badge = "\(i + 1)/\(live.count)"
        }
        bar.update(usage: usage.lastSnapshot, session: shown, request: perms.first,
                   queued: perms.pending.count, act: act, actExtra: extra, actBadge: badge)
        updateStatusItem()
    }

    /// A session changed state. Surface the bar (and chime) when it starts needing the user,
    /// so an answer waiting in a background terminal does not go unnoticed.
    private func activityChanged() {
        render()
        guard let a = activity.current else { lastActivityKey = nil; return }
        let key = "\(a.sessionId):\(a.state.rawValue)"
        defer { lastActivityKey = key }
        guard key != lastActivityKey, a.state != .working else { return }
        if config.sound { NSSound(named: a.state == .waiting ? "Pop" : "Tink")?.play() }
        if !userHid || a.state == .waiting { bar.present() }
    }

    private func requestsChanged() {
        render()
        guard let req = perms.first else {
            // Queue drained: if we only surfaced the bar for the prompt, tuck it away again.
            if forcedForPrompt {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self, self.perms.first == nil, self.forcedForPrompt else { return }
                    self.forcedForPrompt = false
                    self.hideBar(byUser: true)
                }
            }
            return
        }
        if req.id != lastRequestId {
            lastRequestId = req.id
            if config.sound { NSSound(named: "Pop")?.play() }
            // The system close box does not update NSTouchBar.isVisible, so always re-present:
            // the buttons must actually be on the panel.
            if userHid { forcedForPrompt = true }
            bar.present()
        }
    }

    /// Answers only the request that was on screen when the control was rendered.
    private func answer(_ requestId: String, _ decision: PermissionDecision) {
        guard let req = perms.pending.first(where: { $0.id == requestId }) else {
            NSLog("ignored %@ for %@: no longer pending", decision.rawValue, requestId)
            render(); return
        }
        NSLog("permission %@ %@ → %@", req.toolName, req.id, decision.rawValue)
        perms.respond(req, decision)
    }

    // MARK: presentation policy

    private func showBar() {
        userHid = false
        forcedForPrompt = false
        bar.present()
    }

    private func hideBar(byUser: Bool) {
        if byUser { userHid = true }
        bar.dismiss()
    }

    @objc private func appActivated(_ n: Notification) {
        guard config.autoPresent, !userHid else { return }
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        // Some apps replace the Touch Bar when they come to the front; bring ours back on top.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.userHid else { return }
            self.bar.present()
        }
    }

    @objc private func wokeUp(_ n: Notification) {
        writeHeartbeat()
        refreshUsage()
        if !userHid { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.bar.present() } }
    }

    @objc private func screensSlept(_ n: Notification) {
        // Let the heartbeat go stale right away so hooks fall through to the terminal.
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: pidURL.path)
    }

    // MARK: menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem?.button?.title = "C"
        statusItem?.menu = NSMenu()
        statusItem?.menu?.delegate = self
    }

    private func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        guard config.menuBarDetails else { b.title = "C"; return }
        var parts: [String] = []
        if let s = usage.lastSnapshot {
            if let l = s.limit(.session) { parts.append("5h \(Int(l.percent.rounded()))%") }
            if let l = s.limit(.weeklyScoped) { parts.append("\(l.label) \(Int(l.percent.rounded()))%") }
            if s.isStale { parts.insert("!", at: 0) }
        }
        if let c = sessionToShow()?.contextUsedPercent { parts.append("ctx \(Int(c.rounded()))%") }
        if let a = activity.current { parts.insert(a.state == .waiting ? "◆" : a.state == .done ? "✓" : "●", at: 0) }
        if perms.first != nil { parts.insert("⚠︎", at: 0) }
        b.title = parts.isEmpty ? "C" : parts.joined(separator: "  ")
    }

    @objc private func menuShow() { showBar() }
    @objc private func menuHide() { hideBar(byUser: true) }
    @objc private func menuRefresh() { refreshUsage(); status.reload(); perms.reload(); activity.reload() }
    @objc private func menuOpenFolder() { NSWorkspace.shared.open(baseDir) }
    @objc private func menuOpenUsage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc private func menuToggleControlStrip() {
        config.keepControlStrip.toggle(); config.save(to: configURL)
        bar.keepControlStrip = config.keepControlStrip
        if bar.isPresented { bar.dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showBar() } }
    }
    @objc private func menuToggleAutoPresent() { config.autoPresent.toggle(); config.save(to: configURL) }
    @objc private func menuToggleSound() { config.sound.toggle(); config.save(to: configURL) }
    @objc private func menuToggleAwake() { config.keepAwake.toggle(); config.save(to: configURL); keepAwakeIfWanted() }
    @objc private func menuToggleDetails() { config.menuBarDetails.toggle(); config.save(to: configURL); updateStatusItem() }
    @objc private func menuHideIcon() {
        config.showMenuBar = false; config.save(to: configURL)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }
    @objc private func menuDecision(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, let d = PermissionDecision(rawValue: pair[1]) else { return }
        answer(pair[0], d)
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func line(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func action(_ s: String, _ sel: Selector, state: Bool? = nil, represented: Any? = nil) {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: ""); i.target = self; i.representedObject = represented
            if let st = state { i.state = st ? .on : .off }
            menu.addItem(i)
        }
        if let req = perms.first {
            line("Claude Code is asking:")
            line("  " + String(req.headline.prefix(90)))
            if let s = status.sessions.first(where: { $0.sessionId == req.sessionId }) { line("  in \(s.sessionName ?? s.shortCwd)") }
            action("Approve", #selector(menuDecision(_:)), represented: [req.id, "allow"])
            action("Deny", #selector(menuDecision(_:)), represented: [req.id, "deny"])
            action("Answer in Terminal", #selector(menuDecision(_:)), represented: [req.id, "pass"])
            if perms.pending.count > 1 { line("  (+\(perms.pending.count - 1) more waiting)") }
            menu.addItem(.separator())
        }
        if let s = usage.lastSnapshot {
            for l in s.limits {
                let name: String
                switch l.kind { case .session: name = "Current session (5h)"; case .weeklyAll: name = "Weekly · all models"; case .weeklyScoped: name = "Weekly · \(l.label)" }
                let reset = ResetFormat.long(l.resetsAt)
                line("\(name): \(Int(l.percent.rounded()))%" + (reset.isEmpty ? "" : "  resets \(reset)"))
            }
            let f = DateFormatter(); f.timeStyle = .short
            if let ok = s.lastSuccessAt { line("Updated \(f.string(from: ok))" + (s.error != nil ? "  (stale: \(s.error!))" : "")) }
            else if let e = s.error { line("⚠︎ \(e)") }
        } else {
            line("Usage: loading…")
        }
        menu.addItem(.separator())
        if tracked().isEmpty {
            line("No active Claude Code session")
        } else {
            for (s, a) in tracked().prefix(6) {
                let ctx = s.contextUsedPercent.map { "\(Int($0.rounded()))%" } ?? "–"
                let mark = pinnedSessionId == s.sessionId ? "▸ " : "  "
                let hint = a.state == .unknown ? " (restart it to report activity)" : ""
                line("\(mark)[\(a.state.label)] \(s.modelName) · \(TouchBarController.shortName(s)): context \(ctx)\(hint)")
            }
        }
        menu.addItem(.separator())
        action(bar.isPresented ? "Hide Touch Bar" : "Show Touch Bar", bar.isPresented ? #selector(menuHide) : #selector(menuShow))
        action("Refresh Now", #selector(menuRefresh))
        action("Keep Control Strip Visible", #selector(menuToggleControlStrip), state: config.keepControlStrip)
        action("Re-show When Switching Apps", #selector(menuToggleAutoPresent), state: config.autoPresent)
        action("Sound on Permission Prompt", #selector(menuToggleSound), state: config.sound)
        action("Keep Touch Bar Awake (no idle dimming)", #selector(menuToggleAwake), state: config.keepAwake)
        action("Show Usage in Menu Bar", #selector(menuToggleDetails), state: config.menuBarDetails)
        action("Hide Menu Bar Icon (set show_menu_bar in config.json to bring it back)", #selector(menuHideIcon))
        menu.addItem(.separator())
        action("Open claude.ai Usage Page", #selector(menuOpenUsage))
        action("Open Data Folder", #selector(menuOpenFolder))
        action("Quit Claude Touch Bar", #selector(menuQuit))
    }
}
