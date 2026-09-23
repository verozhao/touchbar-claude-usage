import AppKit

/// What a Claude Code session is doing right now, as reported by the activity hooks.
enum ActivityState: String {
    case working    // UserPromptSubmit fired, the turn is running
    case waiting    // Notification fired: Claude wants input (permission, question, idle nudge)
    case done       // Stop fired: the answer is on screen, waiting to be read

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        }
    }

    var color: NSColor {
        switch self {
        case .working: return NSColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 1)   // blue
        case .waiting: return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)  // amber
        case .done: return NSColor(srgbRed: 0.24, green: 0.72, blue: 0.36, alpha: 1)     // green
        }
    }

    /// Sort order when several sessions report at once: the ones needing the user win.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .done: return 1
        case .working: return 2
        }
    }
}

struct SessionActivity {
    let sessionId: String
    let state: ActivityState
    let cwd: String?
    let message: String?
    let at: Date

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
            out.append(SessionActivity(sessionId: (o["session_id"] as? String) ?? f.deletingPathExtension().lastPathComponent,
                                       state: state, cwd: o["cwd"] as? String, message: msg, at: at))
        }
        out.sort { a, b in a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.at > b.at }
        let changed = !ActivityStore.same(out, sessions)
        sessions = out
        if changed { onChange?() }
    }

    private static func same(_ a: [SessionActivity], _ b: [SessionActivity]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x.sessionId != y.sessionId || x.state != y.state || x.at != y.at { return false }
        return true
    }
}

/// Touch Bar tile: a coloured dot (plus a session count when more than one is live).
final class ActivityView: NSView {
    private let dotSize: CGFloat = 10
    private let inset: CGFloat = 9
    private var text: String = ""
    private var dot: NSColor? = nil
    private var hollow = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError() }

    private var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }

    override var intrinsicContentSize: NSSize {
        var w = inset * 2 + dotSize
        if !text.isEmpty { w += 4 + ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        return NSSize(width: w, height: 30)
    }

    func set(state: ActivityState?, text: String, tip: String, hollow: Bool = false) {
        self.text = text
        self.dot = state?.color
        self.hollow = hollow
        toolTip = tip
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        var x = inset
        let d = dot ?? NSColor(white: 1, alpha: 0.35)
        let circle = NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize))
        if hollow || dot == nil {
            d.setStroke(); circle.lineWidth = 2; circle.stroke()
        } else {
            d.setFill(); circle.fill()
        }
        x += dotSize + 4
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.85)]
        let s = text as NSString
        s.draw(at: NSPoint(x: x, y: (bounds.height - s.size(withAttributes: attrs).height) / 2), withAttributes: attrs)
    }
}
