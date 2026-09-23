import Foundation

/// The latest statusLine payload Claude Code handed to our wrapper script, one per session.
struct SessionStatus {
    let sessionId: String
    let sessionName: String?
    let modelName: String
    let modelId: String?
    let cwd: String?
    let contextUsedPercent: Double?
    let contextWindowSize: Int?
    let totalInputTokens: Int?
    let costUSD: Double?
    let fiveHourPercent: Double?
    let fiveHourResetsAt: Date?
    let sevenDayPercent: Double?
    let sevenDayResetsAt: Date?
    let updatedAt: Date
    /// True for status files that never did any work: the short-lived agent bootstraps Claude Code
    /// writes alongside a real session. (`agent_type` alone is no good: a real interactive session
    /// running as an agent carries it too.)
    var isNoise: Bool { contextUsedPercent == nil && (costUSD ?? 0) == 0 }

    var shortCwd: String {
        guard let c = cwd else { return "" }
        let home = NSHomeDirectory()
        return c.hasPrefix(home) ? "~" + c.dropFirst(home.count) : c
    }
}

/// Reads ~/.claude/touchbar/status/*.json and watches the directory for changes.
final class StatusStore {
    let dir: URL
    private(set) var sessions: [SessionStatus] = []
    var onChange: (() -> Void)?
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    /// Sessions that have not reported for this long are ignored.
    var maxAge: TimeInterval = 6 * 3600

    init(dir: URL) { self.dir = dir }

    var current: SessionStatus? { sessions.first }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
        watcher = DirectoryWatcher(url: dir) { [weak self] in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
        timer?.tolerance = 1
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var out: [SessionStatus] = []
        let now = Date()
        for f in files where f.pathExtension == "json" {
            guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if now.timeIntervalSince(mtime) > maxAge { continue }
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let parsed = StatusStore.parse(obj, updatedAt: mtime, fallbackId: f.deletingPathExtension().lastPathComponent)
            if parsed.isNoise { continue }   // never-used agent bootstrap, not a terminal
            out.append(parsed)
        }
        out.sort { $0.updatedAt > $1.updatedAt }
        let changed = !StatusStore.same(out, sessions)
        sessions = out
        if changed { onChange?() }
    }

    private static func same(_ a: [SessionStatus], _ b: [SessionStatus]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x.sessionId != y.sessionId || x.updatedAt != y.updatedAt { return false }
        return true
    }

    static func parse(_ o: [String: Any], updatedAt: Date, fallbackId: String) -> SessionStatus {
        let model = o["model"] as? [String: Any]
        let cw = o["context_window"] as? [String: Any]
        let cost = o["cost"] as? [String: Any]
        let rl = o["rate_limits"] as? [String: Any]
        func num(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        var used = num(cw?["used_percentage"])
        if used == nil, let size = num(cw?["context_window_size"]), size > 0, let total = num(cw?["total_input_tokens"]) {
            used = min(100, max(0, total / size * 100))
        }
        return SessionStatus(
            sessionId: (o["session_id"] as? String) ?? fallbackId,
            sessionName: o["session_name"] as? String,
            modelName: (model?["display_name"] as? String) ?? "Claude",
            modelId: model?["id"] as? String,
            cwd: (o["cwd"] as? String) ?? ((o["workspace"] as? [String: Any])?["current_dir"] as? String),
            contextUsedPercent: used,
            contextWindowSize: num(cw?["context_window_size"]).map { Int($0) },
            totalInputTokens: num(cw?["total_input_tokens"]).map { Int($0) },
            costUSD: num(cost?["total_cost_usd"]),
            fiveHourPercent: num((rl?["five_hour"] as? [String: Any])?["used_percentage"]),
            fiveHourResetsAt: num((rl?["five_hour"] as? [String: Any])?["resets_at"]).map { Date(timeIntervalSince1970: $0) },
            sevenDayPercent: num((rl?["seven_day"] as? [String: Any])?["used_percentage"]),
            sevenDayResetsAt: num((rl?["seven_day"] as? [String: Any])?["resets_at"]).map { Date(timeIntervalSince1970: $0) },
            updatedAt: updatedAt)
    }
}

/// Fires a callback (on the main queue, coalesced) whenever a directory's contents change.
final class DirectoryWatcher {
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pending = false

    init?(url: URL, onChange: @escaping () -> Void) {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib, .link], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self, !self.pending else { return }
            self.pending = true
            // Coalesce bursts (tmp file + rename) into one reload, after the rename settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.pending = false
                onChange()
            }
        }
        src.setCancelHandler { [fd = self.fd] in close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}
