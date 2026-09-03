import Foundation

/// A permission prompt that a Claude Code session is waiting on (written by the hook script).
struct PermissionRequest: Equatable {
    let id: String
    let createdAt: Date
    let hookPid: Int32
    let sessionId: String?
    let cwd: String?
    let toolName: String
    let summary: String
    let description: String?

    static func == (a: PermissionRequest, b: PermissionRequest) -> Bool { a.id == b.id }

    /// "Bash · git push origin main"
    var headline: String {
        let s = summary.isEmpty ? (description ?? "") : summary
        return s.isEmpty ? toolName : "\(toolName) · \(s)"
    }
}

enum PermissionDecision: String { case allow, deny, pass }

/// Watches ~/.claude/touchbar/requests and answers into ~/.claude/touchbar/responses.
final class PermissionQueue {
    let requestsDir: URL
    let responsesDir: URL
    private(set) var pending: [PermissionRequest] = []
    private var answered: Set<String> = []
    var onChange: (() -> Void)?
    private var watcher: DirectoryWatcher?
    private var timer: Timer?

    init(baseDir: URL) {
        requestsDir = baseDir.appendingPathComponent("requests")
        responsesDir = baseDir.appendingPathComponent("responses")
    }

    var first: PermissionRequest? { pending.first }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: requestsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: responsesDir, withIntermediateDirectories: true)
        // Orphaned responses are useless; requests are kept if their hook is still alive (reload checks).
        sweep(olderThan: 0, responsesOnly: true)
        reload()
        watcher = DirectoryWatcher(url: requestsDir) { [weak self] in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
        timer?.tolerance = 0.2
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: requestsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        var out: [PermissionRequest] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["id"] as? String, let tool = o["tool_name"] as? String,
                  !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  id == f.deletingPathExtension().lastPathComponent else { continue }
            let pid = Int32((o["hook_pid"] as? Int) ?? 0)
            // The hook process is gone (timed out, session ended, Ctrl-C): drop its request.
            if pid > 0 && kill(pid, 0) != 0 { try? fm.removeItem(at: f); continue }
            if answered.contains(id) { continue }
            let created = (o["created_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            out.append(PermissionRequest(id: id, createdAt: created, hookPid: pid,
                                         sessionId: o["session_id"] as? String, cwd: o["cwd"] as? String,
                                         toolName: tool, summary: (o["summary"] as? String) ?? "",
                                         description: o["description"] as? String))
        }
        out.sort { $0.createdAt < $1.createdAt }
        // Forget answered ids whose request files are gone.
        let live = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        answered = answered.intersection(live)
        if out != pending { pending = out; onChange?() }
    }

    func respond(_ req: PermissionRequest, _ decision: PermissionDecision) {
        let tmp = responsesDir.appendingPathComponent(".\(req.id).tmp")
        let dst = responsesDir.appendingPathComponent("\(req.id).json")
        let body: [String: Any] = ["id": req.id, "decision": decision.rawValue, "answered_at": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            try? data.write(to: tmp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try? FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        }
        answered.insert(req.id)
        pending.removeAll { $0.id == req.id }
        onChange?()
    }

    /// Removes request/response files older than `age` seconds (0 = everything).
    func sweep(olderThan age: TimeInterval, responsesOnly: Bool = false) {
        let fm = FileManager.default
        for dir in (responsesOnly ? [responsesDir] : [requestsDir, responsesDir]) {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { continue }
            for f in files {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(m) >= age { try? fm.removeItem(at: f) }
            }
        }
    }
}
