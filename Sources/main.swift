import AppKit

let usage = """
Benny Hill Climber \(appVersion) — chase music whenever an AI drives your Mac.
Open the app normally to put it in your menu bar. Command-line modes:

  status                        Print music / control status as JSON
  signal '<JSON>'               Send a begin / keepalive / end event
  connect claude|codex|all      Add Benny Hill Climber's hooks to Claude Code and/or Codex
  disconnect claude|codex|all   Remove only Benny Hill Climber's hooks
  mcp                           Run the stdio MCP server (begin_control, end_control…)
  mcp-config                    Print an MCP client config snippet
  hook claude|codex             (used by hooks) read one hook event on stdin
  credits-snapshot PATH [task]  Render a credits preview PNG
  version                       Print the version

CHASE_SCENE_STATE_DIR overrides the private state folder (for testing).
"""

func clients(_ name: String?) throws -> [Client] {
    if name == "all" {
        let home = Integrations.home()
        return Client.allCases.filter { $0.isInstalled(home: home) }
    }
    guard let name, let client = Client(rawValue: name) else { throw ControlError.invalid("Expected claude, codex or all.") }
    return [client]
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "mcp": MusicMCP().run()
    case "hook":
        guard args.count == 2, ["codex", "claude"].contains(args[1]) else { throw ControlError.invalid("Usage: ChaseScene hook codex|claude") }
        runHook(client: args[1])
    case "signal":
        guard args.count == 2,
              let request = try JSONSerialization.jsonObject(with: Data(args[1].utf8)) as? [String: Any] else {
            throw ControlError.invalid("Usage: ChaseScene signal '{\"action\":\"begin\",\"session_id\":\"unique-id\",\"agent\":\"Your AI\"}'")
        }
        let response = try requestWithLaunch(request)
        FileHandle.standardOutput.write(jsonLine(response))
        if response["ok"] as? Bool != true { exit(1) }
    case "status":
        FileHandle.standardOutput.write(jsonLine(try sendRequest(["action": "status"])))
    case "credits-snapshot":
        guard args.count >= 2 else { throw ControlError.invalid("Usage: ChaseScene credits-snapshot /path/preview.png [task]") }
        _ = NSApplication.shared
        try CreditsPainter.writePreview(to: URL(fileURLWithPath: args[1]),
            deck: Credits.generate(task: args.count > 2 ? args[2] : "App development"), preferences: Preferences())
    case "connect", "disconnect":
        let targets = try clients(args.count > 1 ? args[1] : nil)
        if targets.isEmpty { print("Neither Claude Code nor Codex was found on this Mac.") }
        for client in targets {
            let message = try (args[0] == "connect" ? Integrations.connect(client) : Integrations.disconnect(client))
            print(message)
        }
    case "mcp-config":
        try Integrations.refreshLauncher()
        print(Integrations.mcpConfig())
    case "version", "--version":
        print(appVersion)
    case "help", "--help", "-h":
        print(usage)
    case nil, "--test-mode":
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = try ChaseSceneApp(testMode: args.contains("--test-mode"))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    default:
        // macOS may pass its own arguments (e.g. -psn_…) when launching an app; just start normally.
        if args.first?.hasPrefix("-") == true {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = try ChaseSceneApp()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else {
            throw ControlError.invalid("Unknown command \(args[0]).\n\n\(usage)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("Benny Hill Climber: \(error)\n".utf8))
    exit(1)
}
