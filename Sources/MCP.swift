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
        return [
            tool("begin_control", "Start Chase Scene's chase music before you control the user's local mouse, keyboard or screen, so they can hear that an AI is driving. Keep it on between actions. Returns a unique session_id. This only signals control; it does not grant permissions or lock input.",
                 properties: ["agent": ["type": "string", "description": "Your agent or application name."]], required: ["agent"]),
            tool("keepalive", "Renew your control session during long operations. After 180 seconds without a renewal the menu shows 'unknown' and the music keeps playing until you end it.",
                 properties: ["session_id": session], required: ["session_id"]),
            tool("end_control", "Stop the chase music after finishing all local desktop actions or explicitly handing control back. Wait for pending actions to finish first. This does not cancel actions.",
                 properties: ["session_id": session], required: ["session_id"]),
            tool("control_status", "Read Chase Scene's music and desktop-control status.",
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
                             "instructions": "Chase Scene plays chase music while an AI controls this Mac. Before local desktop control, call begin_control; keep the session through thinking pauses, call keepalive during long operations, and call end_control only after pending actions finish or control is explicitly returned. It is an indicator, not an input lock."])
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
