import AppKit

/// What a Claude Code session is doing right now, as reported by the activity hooks.
enum ActivityState: String {
    case working    // UserPromptSubmit fired, the turn is running
    case waiting    // Notification fired: Claude wants input (permission, question, idle nudge)
    case done       // Stop fired: the answer is on screen, waiting to be read
    case unknown    // a session that reports a status line but no activity: started before the hooks existed
    case error      // nothing can run: a limit is used up, the token expired, or the network is down

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .unknown: return "No activity hook"
        case .error: return "Blocked"
        }
    }

    var color: NSColor {
        switch self {
        case .working: return NSColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 1)   // blue
        case .waiting: return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)  // amber
        case .done: return NSColor(srgbRed: 0.24, green: 0.72, blue: 0.36, alpha: 1)     // green
        case .unknown: return NSColor(white: 1, alpha: 0.55)                             // grey
        case .error: return NSColor(srgbRed: 0.90, green: 0.22, blue: 0.20, alpha: 1)    // red
        }
    }

    /// Sort order when several sessions report at once: the ones needing the user win.
    var rank: Int {
        switch self {
        case .error: return -1
        case .waiting: return 0
        case .done: return 1
        case .working: return 2
        case .unknown: return 3
        }
    }
}

struct SessionActivity {
    let sessionId: String
    let state: ActivityState
    let cwd: String?
    let message: String?
    let at: Date
    var agents: Int = 0

    var shortCwd: String {
        guard let c = cwd, !c.isEmpty else { return "" }
        let home = NSHomeDirectory()
        let p = c.hasPrefix(home) ? "~" + c.dropFirst(home.count) : Substring(c)
        return String(p.split(separator: "/").last ?? p)
    }
}

/// Reads ~/.claude/touchbar/activity/*.json and watches the directory for changes.
final class ActivityStore {
    let dir: URL
    private(set) var sessions: [SessionActivity] = []
    var onChange: (() -> Void)?
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    /// A "working" session that goes quiet for this long has most likely died with its terminal.
    var maxAge: TimeInterval = 4 * 3600

    init(dir: URL) { self.dir = dir }

    /// The session the user should look at first (needs input > finished > working), newest wins ties.
    var current: SessionActivity? { sessions.first }
    func count(_ state: ActivityState) -> Int { sessions.filter { $0.state == state }.count }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        reload()
        watcher = DirectoryWatcher(url: dir) { [weak self] in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
        timer?.tolerance = 1
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        sweepOrphans(files)
        var out: [SessionActivity] = []
        let now = Date()
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = ActivityState(rawValue: (o["state"] as? String) ?? "") else { continue }
            let ts = (o["ts"] as? Double) ?? Double((o["ts"] as? Int) ?? 0)
            let at = Date(timeIntervalSince1970: ts)
            if now.timeIntervalSince(at) > maxAge { continue }
            let msg = (o["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let agents = (o["agents"] as? Int) ?? Int((o["agents"] as? Double) ?? 0)
            out.append(SessionActivity(sessionId: (o["session_id"] as? String) ?? f.deletingPathExtension().lastPathComponent,
                                       state: state, cwd: o["cwd"] as? String, message: msg, at: at, agents: agents))
        }
        out.sort { a, b in a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.at > b.at }
        let changed = !ActivityStore.same(out, sessions)
        sessions = out
        if changed { onChange?() }
    }

    /// A session killed with its terminal never runs SessionEnd, so its .agents / .stopped
    /// sidecars would pile up for ever. Drop anything a day old.
    private func sweepOrphans(_ files: [URL]) {
        let fm = FileManager.default
        for f in files where f.pathExtension == "agents" || f.pathExtension == "stopped" {
            guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(m) > 86400 else { continue }
            try? fm.removeItem(at: f)
        }
    }

    private static func same(_ a: [SessionActivity], _ b: [SessionActivity]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x.sessionId != y.sessionId || x.state != y.state || x.at != y.at { return false }
        return true
    }
}

/// One session: a coloured dot you can touch to follow that session.
final class DotButton: NSButton {
    static let size = NSSize(width: 18, height: 30)
    private let dotSize: CGFloat = 10
    var color: NSColor = NSColor(white: 1, alpha: 0.35)
    var hollow = false
    var selected = false

    init(target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(origin: .zero, size: DotButton.size))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { DotButton.size }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSRect(x: (bounds.width - dotSize) / 2, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        if isHighlighted {
            NSColor(white: 1, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 4), xRadius: 5, yRadius: 5).fill()
        }
        // The session the gauges are following wears a ring.
        if selected {
            NSColor(white: 1, alpha: 0.9).setStroke()
            let ring = NSBezierPath(ovalIn: c.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let path = NSBezierPath(ovalIn: c)
        if hollow {
            color.setStroke(); path.lineWidth = 2; path.stroke()
        } else {
            color.setFill(); path.fill()
        }
    }
}

/// Touch Bar tile: one dot per live session, left to right, newest activity first.
final class ActivityView: NSView {
    /// What each dot needs to draw itself.
    struct Dot { let id: String; let color: NSColor; let hollow: Bool; let selected: Bool; let tip: String }

    static let maxDots = 5
    private let gap: CGFloat = 2
    private let inset: CGFloat = 6
    private var buttons: [DotButton] = []
    private var ids: [String] = []
    var onPick: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let n = max(1, buttons.count)
        return NSSize(width: inset * 2 + CGFloat(n) * DotButton.size.width + CGFloat(n - 1) * gap, height: 30)
    }

    func set(_ dots: [Dot]) {
        let shown = Array(dots.prefix(ActivityView.maxDots))
        if shown.count != buttons.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = shown.map { _ in DotButton(target: self, action: #selector(dotTapped(_:))) }
            buttons.forEach { addSubview($0) }
        }
        ids = shown.map { $0.id }
        for (b, d) in zip(buttons, shown) {
            b.color = d.color; b.hollow = d.hollow; b.selected = d.selected; b.toolTip = d.tip
            b.needsDisplay = true
        }
        // An empty bar still shows one hollow dot, so the tile never collapses to nothing.
        if shown.isEmpty && buttons.isEmpty {
            let b = DotButton(target: self, action: #selector(dotTapped(_:)))
            b.toolTip = "No Claude Code session running"
            buttons = [b]; addSubview(b); ids = []
        }
        invalidateIntrinsicContentSize()
        layout()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x = inset
        for b in buttons {
            b.frame = NSRect(x: x, y: 0, width: DotButton.size.width, height: DotButton.size.height)
            x += DotButton.size.width + gap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    @objc private func dotTapped(_ sender: DotButton) {
        guard let i = buttons.firstIndex(of: sender), i < ids.count else { return }
        onPick?(ids[i])
    }
}
