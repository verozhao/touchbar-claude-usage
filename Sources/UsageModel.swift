import Foundation

/// One usage limit as shown on claude.ai/settings/usage.
struct UsageLimit {
    enum Kind: String { case session, weeklyAll, weeklyScoped }
    let kind: Kind
    let label: String          // "5h", "Week", "Fable"
    let percent: Double        // 0...100
    let resetsAt: Date?
    let severity: String?      // normal | warning | critical (server-provided, optional)
}

struct UsageSnapshot {
    var limits: [UsageLimit]
    var fetchedAt: Date
    var error: String?
    var lastSuccessAt: Date? = nil
    var retryAfter: TimeInterval? = nil   // set when the server asked us to slow down

    /// Data older than 15 minutes (or none at all) counts as stale.
    var isStale: Bool {
        guard let ok = lastSuccessAt, !limits.isEmpty else { return true }
        return Date().timeIntervalSince(ok) > 900
    }

    func limit(_ kind: UsageLimit.Kind) -> UsageLimit? { limits.first { $0.kind == kind } }
}

/// Fetches https://api.anthropic.com/api/oauth/usage with the CLI's OAuth token.
final class UsageFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The endpoint throttles unknown clients hard; identify as the Claude Code version installed here.
    static let userAgent: String = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/claude/versions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let versions = names.filter { !$0.isEmpty && $0.first!.isNumber }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return "claude-code/\(versions.last ?? "2.1.259")"
    }()
    private let session: URLSession
    private(set) var lastSnapshot: UsageSnapshot?
    private var inFlight = false
    private var lastSuccessAt: Date?
    private var backoff: TimeInterval = 0
    /// Last good response, kept on disk so a restart during a rate-limit still shows real numbers
    /// (the model-scoped weekly limit has no status-line fallback).
    private let cacheURL: URL

    init() {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_TOUCHBAR_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/touchbar")
        cacheURL = dir.appendingPathComponent("usage-cache.json")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        session = URLSession(configuration: cfg)
        loadCache()
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = o["payload"] as? [String: Any],
              let ts = UsageFetcher.number(o["at"]) else { return }
        let at = Date(timeIntervalSince1970: ts)
        // A week-old cache is worse than nothing: the weekly windows have rolled over by then.
        guard Date().timeIntervalSince(at) < 6 * 86400 else { return }
        let limits = UsageFetcher.parse(payload)
        guard !limits.isEmpty else { return }
        lastSuccessAt = at
        lastSnapshot = UsageSnapshot(limits: limits, fetchedAt: at, error: nil, lastSuccessAt: at, retryAfter: nil)
    }

    private func saveCache(_ payload: [String: Any]) {
        let wrapper: [String: Any] = ["at": Date().timeIntervalSince1970, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    func fetch(completion: @escaping (UsageSnapshot) -> Void) {
        if inFlight { return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.fetchSync()
            DispatchQueue.main.async {
                self.inFlight = false
                self.lastSnapshot = snapshot
                completion(snapshot)
            }
        }
    }

    private func failure(_ msg: String, retryAfter: TimeInterval? = nil) -> UsageSnapshot {
        UsageSnapshot(limits: lastSnapshot?.limits ?? [], fetchedAt: Date(), error: msg, lastSuccessAt: lastSuccessAt, retryAfter: retryAfter)
    }

    private func fetchSync() -> UsageSnapshot {
        guard let token = ClaudeCredentials.load() else {
            return failure("no token (log in to Claude Code)")
        }
        var req = URLRequest(url: UsageFetcher.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(UsageFetcher.userAgent, forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: req) { d, r, e in result = (d, r, e); sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 25)

        if let e = result.2 { return failure("network: \(e.localizedDescription)") }
        guard let http = result.1 as? HTTPURLResponse, let data = result.0 else { return failure("no response") }
        switch http.statusCode {
        case 200:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return failure("bad JSON") }
            backoff = 0
            lastSuccessAt = Date()
            saveCache(obj)
            return UsageSnapshot(limits: UsageFetcher.parse(obj), fetchedAt: Date(), error: nil, lastSuccessAt: lastSuccessAt, retryAfter: nil)
        case 401:
            return failure("token expired (run claude to refresh)")
        case 429, 503:
            // Respect Retry-After, otherwise back off 2 → 4 → 8 → 16 → 30 min.
            let header = (http.value(forHTTPHeaderField: "Retry-After") ?? "").trimmingCharacters(in: .whitespaces)
            let wait: TimeInterval
            if let secs = Double(header), secs > 0 { wait = min(3600, secs) }
            else { backoff = backoff == 0 ? 120 : min(1800, backoff * 2); wait = backoff }
            return failure("usage API rate-limited · retry in \(max(1, Int(wait / 60)))m", retryAfter: wait)
        default:
            return failure("HTTP \(http.statusCode)")
        }
    }

    // MARK: parsing

    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Prefers the structured `limits` array (session / weekly_all / weekly_scoped),
    /// falls back to the legacy five_hour / seven_day objects.
    static func parse(_ obj: [String: Any]) -> [UsageLimit] {
        var out: [UsageLimit] = []
        if let arr = obj["limits"] as? [[String: Any]] {
            for l in arr {
                guard let kind = l["kind"] as? String, let pct = number(l["percent"]) else { continue }
                let severity = l["severity"] as? String
                let resets = date(l["resets_at"])
                switch kind {
                case "session":
                    out.append(UsageLimit(kind: .session, label: "5h", percent: pct, resetsAt: resets, severity: severity))
                case "weekly_all":
                    out.append(UsageLimit(kind: .weeklyAll, label: "Week", percent: pct, resetsAt: resets, severity: severity))
                case "weekly_scoped":
                    var name = "Model"
                    if let scope = l["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                       let dn = model["display_name"] as? String, !dn.isEmpty { name = dn }
                    out.append(UsageLimit(kind: .weeklyScoped, label: name, percent: pct, resetsAt: resets, severity: severity))
                default: continue
                }
            }
        }
        if !out.contains(where: { $0.kind == .session }), let fh = obj["five_hour"] as? [String: Any], let u = number(fh["utilization"]) {
            out.append(UsageLimit(kind: .session, label: "5h", percent: u, resetsAt: date(fh["resets_at"]), severity: nil))
        }
        if !out.contains(where: { $0.kind == .weeklyAll }), let sd = obj["seven_day"] as? [String: Any], let u = number(sd["utilization"]) {
            out.append(UsageLimit(kind: .weeklyAll, label: "Week", percent: u, resetsAt: date(sd["resets_at"]), severity: nil))
        }
        if !out.contains(where: { $0.kind == .weeklyScoped }) {
            for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                if let sd = obj[key] as? [String: Any], let u = number(sd["utilization"]) {
                    out.append(UsageLimit(kind: .weeklyScoped, label: label, percent: u, resetsAt: date(sd["resets_at"]), severity: nil))
                    break
                }
            }
        }
        // Stable display order: 5h, Week, model-scoped.
        let order: [UsageLimit.Kind] = [.session, .weeklyAll, .weeklyScoped]
        return out.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }
}

/// "4h 35m", "Mon 12:00", etc. for reset countdowns.
enum ResetFormat {
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let d = date else { return "" }
        let secs = d.timeIntervalSince(now)
        if secs <= 0 { return "now" }
        let total = Int(secs)
        if total < 3600 { return "\(max(1, total / 60))m" }
        if total < 24 * 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86400)d \((total % 86400) / 3600)h"
    }

    /// "12m", "3h 5m" since a past moment.
    static func elapsed(since: Date, now: Date = Date()) -> String {
        short(now.addingTimeInterval(max(0, now.timeIntervalSince(since))), now: now)
    }

    /// "Mon 12:00 PM" style, for menus.
    static func long(_ date: Date?) -> String {
        guard let d = date else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f.string(from: d)
    }
}
