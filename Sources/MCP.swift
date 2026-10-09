import Foundation

final class MusicMCP {
    let owner = "mcp:\(UUID().uuidString)"
    var owned: Set<String> = []
    let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    func tool(_ name: String, _ description: String, properties: [String: Any], required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
    }

    var tools: [[String: Any]] {
        let session: [String: Any] = ["type": "string", "description": "The session_id returned by begin_control."]
        let task: [String: Any] = ["type": "string", "maxLength": 160, "description": "A short, non-sensitive task description for the funny rolling credits."]
        let rows: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 12,
            "description": "Fictional task-related credits. Write funny role titles and names that are puns, like Page-turning supervision: Paige Turner.",
            "items": ["type": "object", "properties": ["role": ["type": "string", "maxLength": 64],
                "name": ["type": "string", "maxLength": 64]], "required": ["role", "name"], "additionalProperties": false]]
        return [
            tool("begin_control", "Start the user's desktop-control music before controlling their local screen. Keep it on between actions. Returns a unique session_id. This indicates control; it does not grant permissions or lock input.",
                 properties: ["agent": ["type": "string", "description": "Your agent or application name."],
                    "task": task, "credits": rows], required: ["agent"]),
            tool("set_credits", "Author fresh fictional credits as the workflow changes: a short current activity plus 1–3 new funny roles and pun names. Call this between desktop actions, rather than sending one fixed reel for the whole task. Unused rows are replaced; the live roll keeps moving. This never starts music or reports control. With automatic hooks, call this before the first desktop action; without hooks, include task/credits in begin_control. Omit credits for built-in task-related puns.",
                 properties: ["task": task, "credits": rows, "session_id": session], required: ["task"]),
            tool("keepalive", "Renew your live control session during long operations. After 180 seconds without a renewal, music stops and the menu shows signal lost. Begin a new session after a lost signal.",
                 properties: ["session_id": session], required: ["session_id"]),
            tool("end_control", "Stop your control indicator after finishing all local desktop actions or explicitly handing control back. Wait for pending actions to finish first. This does not cancel actions.",
                 properties: ["session_id": session], required: ["session_id"]),
            tool("control_status", "Read music and reported local desktop-control status. This cannot detect unintegrated AI tools.",
                 properties: [:], readOnly: true)
        ]
    }

    func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        var request: [String: Any]
        switch name {
        case "begin_control":
            guard let agent = arguments["agent"] as? String, !agent.isEmpty else { throw ControlError.invalid("agent is required.") }
            let id = "\(owner):\(UUID().uuidString)"
            request = ["action": "begin", "session_id": id, "owner": owner, "agent": agent, "via": "mcp"]
            for key in ["task", "credits"] { if let value = arguments[key] { request[key] = value } }
            let result = try requestWithLaunch(request)
            guard result["ok"] as? Bool == true else { throw ControlError.invalid(result["error"] as? String ?? "Could not start music.") }
            owned.insert(id)
            var response = result
            response["session_id"] = id
            return response
        case "keepalive", "end_control":
            guard let id = arguments["session_id"] as? String, owned.contains(id) else {
                throw ControlError.invalid("session_id must belong to this MCP connection.")
            }
            request = ["action": name == "keepalive" ? "keepalive" : "end", "session_id": id, "via": "mcp"]
        case "control_status": request = ["action": "status"]
        case "set_credits":
            request = ["action": "set_credits"]
            for key in ["task", "credits"] { if let value = arguments[key] { request[key] = value } }
            if let id = arguments["session_id"] as? String {
                guard owned.contains(id) else { throw ControlError.invalid("session_id must belong to this MCP connection.") }
                request["session_id"] = id
            }
        default: throw ControlError.invalid("Unknown tool: \(name)")
        }
        let result = try requestWithLaunch(request, launch: false)
        if result["ok"] as? Bool == false { throw ControlError.invalid(result["error"] as? String ?? "Signaling failed") }
        return result
    }

    func process(_ message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        func response(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return error(-32600, "Invalid JSON-RPC request")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return response(["protocolVersion": versions.contains(requested) ? requested : versions[0],
                             "capabilities": ["tools": ["listChanged": false]],
                             "serverInfo": ["name": "chase-scene", "version": appVersion],
                             "instructions": "Before desktop control, begin; renew during long pauses and end after pending actions finish. Throughout control, continually author fresh fictional role/name puns describing the specific step you are doing now and send them through set_credits (1–3 rows per workflow update). Keep task labels non-sensitive. These credits are a live workflow feed, not one repeating six-name reel. With JS tool hooks, you can instead prefix each action with // chase-credits: followed by one-line JSON containing task and credits. Music is an indicator, not an input lock."])
        case "ping": return response([:])
        case "tools/list": return response(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(-32602, "Tool name required") }
            do {
                let result = try call(name, arguments: params["arguments"] as? [String: Any] ?? [:])
                let text = String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!
                return response(["content": [["type": "text", "text": text]], "structuredContent": result, "isError": false])
            } catch {
                return response(["content": [["type": "text", "text": String(describing: error)]], "isError": true])
            }
        default: return error(-32601, "Method not found: \(method)")
        }
    }

    func run() {
        defer { _ = try? requestWithLaunch(["action": "unknown_owner", "owner": owner], launch: false) }
        while let line = readLine() {
            do {
                guard line.utf8.count <= 1_048_576,
                      let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw ControlError.invalid("Expected a JSON-RPC object under 1 MiB.")
                }
                if let response = process(message) { FileHandle.standardOutput.write(jsonLine(response)) }
            } catch {
                FileHandle.standardOutput.write(jsonLine(["jsonrpc": "2.0", "id": NSNull(),
                                                         "error": ["code": -32700, "message": "Invalid JSON"]]))
            }
        }
    }
}
