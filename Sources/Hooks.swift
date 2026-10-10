import Foundation

/// Turns Claude Code / Codex hook events into begin / keepalive / end signals.
struct HookAdapter {
    let client: String
    let directory: URL

    static let defaultPattern = "(?i)^(mcp__[^_]*(?:computer|desktop|cua|node_repl|playwright|browser|chrome)[^_]*__.*|mcp__(?:cua_repl|node_repl|computer_use|computer-use|chrome_devtools)__.*|computer|computer_use|mcp__[^_]+__computer.*)$"

    func isControlTool(_ name: String, input: [String: Any]) -> Bool {
        // Benny Hill Climber's own MCP tools must never trigger the chase.
        if name.contains("chase-scene") || name.contains("chase_scene") || name.contains("desktop-control-music") || name.contains("desktop_control_music") { return false }
        var pattern = HookAdapter.defaultPattern
        if let data = try? Data(contentsOf: directory.appendingPathComponent("adapters.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let custom = config["control_tool_pattern"] as? String,
           (try? NSRegularExpression(pattern: custom)) != nil { pattern = custom }
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    func request(_ event: [String: Any]) -> [String: Any]? {
        guard let sid = event["session_id"] as? String, !sid.isEmpty else { return nil }
        let owner = "hook:\(client):\(sid)"
        let scope = client == "codex" ? (event["turn_id"] as? String ?? "main") : (event["agent_id"] as? String ?? "main")
        let id = "\(owner):\(scope)"
        let agent = client == "codex" ? "Codex" : "Claude Code"
        let kind = event["hook_event_name"] as? String ?? ""
        var result: [String: Any]
        switch kind {
        case "PreToolUse":
            let name = event["tool_name"] as? String ?? ""
            if isControlTool(name, input: event["tool_input"] as? [String: Any] ?? [:]) {
                result = ["action": "begin", "session_id": id, "owner": owner, "agent": agent, "ttl": 180,
                    "credit_topic": Credits.hookTopic(name: name, input: event["tool_input"] as? [String: Any] ?? [:])]
                if let deck = Credits.hookCredits(input: event["tool_input"] as? [String: Any] ?? [:]) {
                    result["task"] = deck.task
                    result["credits"] = deck.credits.map { ["role": $0.role, "name": $0.name] }
                }
            } else {
                result = ["action": "keepalive", "session_id": id, "ttl": 180]
            }
        case "PostToolUse", "PostToolUseFailure":
            result = ["action": "keepalive", "session_id": id, "ttl": 180]
        case "Stop":
            // A Stop hook may lead to another continuation; the next control call begins again.
            result = ["action": "end", "session_id": id]
        case "SubagentStop":
            guard client == "claude", let aid = event["agent_id"] as? String else { return nil }
            result = ["action": "end", "session_id": "\(owner):\(aid)"]
        case "SessionEnd":
            result = ["action": "end_owner", "owner": owner]
        case "Interrupt", "StopFailure":
            // Cancellation may leave an already-running GUI call alive; don't imply handback.
            result = ["action": "unknown_owner", "owner": owner]
        default: return nil
        }
        result["via"] = client
        return result
    }
}

/// Shows a gentle warning inside the AI client at most once every 30 minutes.
func shouldWarn(directory: URL) -> Bool {
    let marker = directory.appendingPathComponent("last-warning")
    let now = Date().timeIntervalSince1970
    if let text = try? String(contentsOf: marker, encoding: .utf8), let last = Double(text), now - last < 1800 { return false }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? String(now).write(to: marker, atomically: true, encoding: .utf8)
    return true
}

func runHook(client: String) {
    // No transcripts or screen content are read. Selected tool inputs yield only a broad credits topic; raw inputs are never saved.
    let directory = stateDirectory()
    var request: [String: Any]? = nil
    do {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 4_194_304,
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { print("{}"); return }
        request = HookAdapter(client: client, directory: directory).request(event)
        guard let request else { print("{}"); return }
        let isBegin = request["action"] as? String == "begin"
        let response = try requestWithLaunch(request, launch: isBegin)
        if response["ok"] as? Bool == false { throw ControlError.invalid(response["error"] as? String ?? "Signaling failed") }
        print("{}")
    } catch {
        // A missing app never blocks the AI's task or changes its permissions. Only a failed *start*
        // is worth mentioning (rate-limited), so silence is never mistaken for "it's working".
        let failedBegin = request?["action"] as? String == "begin"
        let quit = Preferences.load(from: directory).quitByUser
        if failedBegin && !quit && shouldWarn(directory: directory) {
            let message = "Benny Hill Climber couldn't start its chase music: \(error)"
            print(String(data: jsonLine(["systemMessage": message]), encoding: .utf8)!.trimmingCharacters(in: .newlines))
        } else {
            print("{}")
        }
    }
}
