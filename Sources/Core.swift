import Foundation

let appName = "Chase Scene"
let appVersion = "1.0.0"

struct ControlSession: Codable {
    let id: String
    let agent: String
    let owner: String
    var expiresAt: Double
    var uncertain: Bool

    /// Sessions the app noticed by itself (synthetic mouse input) rather than ones an AI reported.
    var automatic: Bool { owner == ControlState.automaticOwner }
}

struct Preferences: Codable {
    var enabled = true
    var volume: Float = 0.5
    var songPath: String? = nil
    var autoDetect = true
    var ignoredApps: [String] = []
    var welcomed = false
    var quitByUser = false
    var lastSignal: [String: Double] = [:]

    init() {}

    // Every key is optional so older or hand-edited preference files never reset everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        volume = min(1, max(0, (try? c.decodeIfPresent(Float.self, forKey: .volume)) ?? 0.5))
        songPath = try? c.decodeIfPresent(String.self, forKey: .songPath)
        autoDetect = (try? c.decodeIfPresent(Bool.self, forKey: .autoDetect)) ?? true
        ignoredApps = (try? c.decodeIfPresent([String].self, forKey: .ignoredApps)) ?? []
        welcomed = (try? c.decodeIfPresent(Bool.self, forKey: .welcomed)) ?? false
        quitByUser = (try? c.decodeIfPresent(Bool.self, forKey: .quitByUser)) ?? false
        lastSignal = (try? c.decodeIfPresent([String: Double].self, forKey: .lastSignal)) ?? [:]
    }

    static func load(from directory: URL) -> Preferences {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("preferences.json")),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }
}

enum ControlError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}

final class ControlState {
    static let automaticOwner = "auto"
    /// How long automatic detection keeps the music going after the last synthetic mouse event.
    /// Long enough to cover an agent "thinking" between clicks.
    var automaticLinger: Double = 20

    var sessions: [String: ControlSession] = [:]
    var preferences = Preferences()
    let directory: URL
    var changed: (() -> Void)?
    var audioStatus: () -> [String: Any] = { [:] }
    var now: () -> Double = { Date().timeIntervalSince1970 }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        preferences = Preferences.load(from: directory)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("sessions.json")),
           let saved = try? JSONDecoder().decode([String: ControlSession].self, from: data) {
            // After a restart we can't know whether a reported controller finished, so say so.
            sessions = saved.filter { !$0.value.automatic }.mapValues { s in var s = s; s.uncertain = true; return s }
        }
    }

    private func string(_ request: [String: Any], _ key: String, default fallback: String? = nil) throws -> String {
        guard let value = request[key] as? String ?? fallback, !value.isEmpty, value.utf8.count <= 300,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ControlError.invalid("A nonempty '\(key)' (up to 300 bytes) is required.")
        }
        return value
    }

    private func ttl(_ request: [String: Any]) throws -> Double {
        guard request["ttl"] == nil || request["ttl"] is NSNumber else {
            throw ControlError.invalid("ttl must be a number of seconds.")
        }
        let value = (request["ttl"] as? NSNumber)?.doubleValue ?? 180
        guard value.isFinite, value >= 1, value <= 3600 else {
            throw ControlError.invalid("ttl must be between 1 and 3600 seconds.")
        }
        return value
    }

    /// Reported sessions whose lease ran out become "unknown" (never silently released).
    /// Automatically detected sessions simply end when the synthetic input stops.
    @discardableResult func expire() -> Bool {
        var updated = false
        for (id, var session) in sessions where !session.uncertain && session.expiresAt <= now() {
            if session.automatic {
                sessions.removeValue(forKey: id)
            } else {
                session.uncertain = true
                sessions[id] = session
            }
            updated = true
        }
        if updated { persist(); changed?() }
        return updated
    }

    func isIgnored(_ app: String) -> Bool {
        preferences.ignoredApps.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }

    /// Called by the synthetic-input detector. Returns true when this started or renewed a session.
    @discardableResult func noteAutomation(app: String) -> Bool {
        guard preferences.autoDetect, !isIgnored(app) else { return false }
        let id = "auto:\(app)"
        let isNew = sessions[id] == nil
        sessions[id] = ControlSession(id: id, agent: app, owner: Self.automaticOwner,
                                      expiresAt: now() + automaticLinger, uncertain: false)
        if isNew { changed?() }
        return true
    }

    private func recordSignal(_ request: [String: Any]) {
        guard let via = request["via"] as? String, ["claude", "codex", "mcp"].contains(via) else { return }
        let last = preferences.lastSignal[via] ?? 0
        preferences.lastSignal[via] = now()
        if now() - last > 30 { persist() }
    }

    func handle(_ request: [String: Any]) -> [String: Any] {
        do {
            let action = try string(request, "action")
            var didChange = false
            recordSignal(request)
            switch action {
            case "begin":
                let id = try string(request, "session_id")
                let agent = try string(request, "agent", default: "AI")
                let owner = try string(request, "owner", default: id)
                guard owner != Self.automaticOwner else { throw ControlError.invalid("That owner name is reserved.") }
                guard sessions[id] != nil || sessions.count < 128 else {
                    throw ControlError.invalid("Too many active sessions. Clear stale indicators in the menu.")
                }
                if let existing = sessions[id], existing.owner != owner {
                    throw ControlError.invalid("Session belongs to another owner.")
                }
                sessions[id] = ControlSession(id: id, agent: agent, owner: owner,
                    expiresAt: now() + (try ttl(request)), uncertain: false)
                didChange = true
            case "keepalive":
                let id = try string(request, "session_id")
                if var session = sessions[id], !session.automatic {
                    session.expiresAt = now() + (try ttl(request))
                    session.uncertain = false
                    sessions[id] = session
                    didChange = true
                }
            case "end":
                let id = try string(request, "session_id")
                if sessions[id]?.automatic != true { sessions.removeValue(forKey: id) }
                didChange = true
            case "end_owner", "unknown_owner":
                let owner = try string(request, "owner")
                for (id, var session) in sessions where session.owner == owner && !session.automatic {
                    if action == "end_owner" { sessions.removeValue(forKey: id) }
                    else { session.uncertain = true; sessions[id] = session }
                    didChange = true
                }
            case "unknown":
                let id = try string(request, "session_id")
                if var session = sessions[id], !session.automatic {
                    session.uncertain = true; sessions[id] = session; didChange = true
                }
            case "set_enabled":
                guard let value = request["enabled"] as? Bool else { throw ControlError.invalid("enabled must be true or false.") }
                preferences.enabled = value
                didChange = true
            case "set_volume":
                guard let volume = request["volume"] as? NSNumber, volume.doubleValue.isFinite,
                      (0...1).contains(volume.doubleValue) else { throw ControlError.invalid("volume must be between 0 and 1.") }
                preferences.volume = volume.floatValue
                didChange = true
            case "set_auto_detect":
                guard let value = request["enabled"] as? Bool else { throw ControlError.invalid("enabled must be true or false.") }
                preferences.autoDetect = value
                if !value { sessions = sessions.filter { !$0.value.automatic } }
                didChange = true
            case "ignore_app", "unignore_app":
                let app = try string(request, "app")
                preferences.ignoredApps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
                if action == "ignore_app" {
                    preferences.ignoredApps.append(app)
                    sessions.removeValue(forKey: "auto:\(app)")
                }
                didChange = true
            case "clear":
                sessions.removeAll()
                didChange = true
            case "status": break
            default: throw ControlError.invalid("Unknown action: \(action)")
            }
            if didChange { persist(); changed?() }
            expire()
            return snapshot()
        } catch { return ["ok": false, "error": String(describing: error)] }
    }

    var stateName: String {
        sessions.isEmpty ? "idle" : (sessions.values.contains { $0.uncertain } ? "unknown" : "controlling")
    }

    func snapshot() -> [String: Any] {
        var result: [String: Any] = [
            "ok": true, "app": appName, "version": appVersion,
            "enabled": preferences.enabled, "volume": preferences.volume,
            "auto_detect": preferences.autoDetect, "ignored_apps": preferences.ignoredApps,
            "state": stateName,
            "sessions": sessions.values.sorted { $0.id < $1.id }.map {
                ["session_id": $0.id, "agent": $0.agent, "owner": $0.owner, "uncertain": $0.uncertain,
                 "automatic": $0.automatic] as [String: Any]
            }
        ]
        result.merge(audioStatus()) { _, new in new }
        return result
    }

    func persist() {
        // Atomic writes prevent truncated preferences/session records after a crash.
        let reported = sessions.filter { !$0.value.automatic && $0.key != "demo" }
        for (name, data) in [("preferences.json", try? JSONEncoder().encode(preferences)),
                             ("sessions.json", try? JSONEncoder().encode(reported))] {
            guard let data else { continue }
            let url = directory.appendingPathComponent(name)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
