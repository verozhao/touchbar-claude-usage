import Foundation

/// Reads the Claude Code OAuth access token that the CLI stores in the login keychain
/// (service "Claude Code-credentials"). Uses /usr/bin/security so the keychain ACL
/// "Always Allow" sticks to the security tool rather than to each rebuilt binary.
enum ClaudeCredentials {
    static let service = "Claude Code-credentials"

    struct Token {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
    }

    static func load() -> Token? {
        guard let raw = runSecurity() else { return nil }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expires: Date? = nil
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        return Token(accessToken: token, expiresAt: expires, subscriptionType: oauth["subscriptionType"] as? String)
    }

    private static func runSecurity() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
