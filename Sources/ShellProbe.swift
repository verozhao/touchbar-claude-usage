import Foundation

/// Spots work a session is still doing after its turn ended.
///
/// Claude Code fires `Stop` as soon as it stops talking, but a shell it launched can outlive that
/// turn by minutes (a training run, a watcher, a `sleep` loop). There is no hook for such a shell
/// finishing, so instead of counting them we look: does the `claude` process on this session's tty
/// still have a child of its own? If it does, the session is not finished.
final class ShellProbe {
    /// tty path ("/dev/ttys002") → what that session's claude process is still running.
    private(set) var busyTTYs: Set<String> = []
    private var timer: Timer?
    private var running = false
    var onChange: (() -> Void)?

    /// Children younger than this are ignored: our own hooks and status line run for a moment on
    /// every turn and would otherwise read as work.
    private let minimumAge: TimeInterval = 3

    func start(interval: TimeInterval = 5) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1
    }

    func isBusy(_ tty: String?) -> Bool {
        guard let t = tty else { return false }
        return busyTTYs.contains(t)
    }

    func refresh() {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = ShellProbe.scan(minimumAge: self?.minimumAge ?? 3)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = false
                if found != self.busyTTYs {
                    self.busyTTYs = found
                    self.onChange?()
                }
            }
        }
    }

    private static func scan(minimumAge: TimeInterval) -> Set<String> {
        guard let out = run("/bin/ps", ["-eo", "pid=,ppid=,etime=,tty=,command="]) else { return [] }
        struct Row { let pid: Int; let ppid: Int; let age: TimeInterval; let tty: String; let cmd: String }
        var rows: [Row] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5, let pid = Int(f[0]), let ppid = Int(f[1]) else { continue }
            let cmd = f[4...].joined(separator: " ")
            rows.append(Row(pid: pid, ppid: ppid, age: seconds(String(f[2])), tty: String(f[3]), cmd: cmd))
        }
        // The CLI itself, one per terminal.
        var claudeByPid: [Int: String] = [:]
        for r in rows where r.tty != "??" {
            let name = r.cmd.split(separator: " ").first.map(String.init) ?? r.cmd
            if name == "claude" || name.hasSuffix("/claude") { claudeByPid[r.pid] = "/dev/" + r.tty }
        }
        var busy: Set<String> = []
        for r in rows {
            guard let tty = claudeByPid[r.ppid], r.age >= minimumAge else { continue }
            if ShellProbe.isHousekeeping(r.cmd) { continue }
            busy.insert(tty)
        }
        return busy
    }

    /// Children Claude Code keeps around that are not the session doing work: its own
    /// sleep-blocker, and this app's hooks and status line.
    private static func isHousekeeping(_ cmd: String) -> Bool {
        if cmd.contains("claude-touchbar") { return true }
        let name = (cmd.split(separator: " ").first.map(String.init) ?? cmd)
            .split(separator: "/").last.map(String.init) ?? cmd
        return name == "caffeinate"
    }

    /// ps etime: "01:55", "23:03:35", "24-16:31:05".
    private static func seconds(_ s: String) -> TimeInterval {
        var days = 0.0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[s.startIndex..<dash]) ?? 0
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        let hms: Double
        switch parts.count {
        case 3: hms = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: hms = parts[0] * 60 + parts[1]
        case 1: hms = parts[0]
        default: hms = 0
        }
        return days * 86400 + hms
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
