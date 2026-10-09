import Foundation

// Core checks: session state, automatic detection bookkeeping, hook adapter,
// the order-preserving JSON editor and the Claude Code / Codex connect logic.
// Build and run:  see README "Build and test".

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAILED: \(message)") }
}
func throwsError(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chase-core-\(UUID())")
defer { try? FileManager.default.removeItem(at: root) }

// MARK: Reported sessions

let state = try ControlState(directory: root.appendingPathComponent("state"))
var time: Double = 1000
state.now = { time }
check(state.snapshot()["state"] as? String == "idle", "starts idle")
_ = state.handle(["action": "begin", "session_id": "a", "agent": "Codex", "owner": "one", "ttl": 10])
_ = state.handle(["action": "begin", "session_id": "b", "agent": "Claude", "owner": "two", "ttl": 20])
check(state.sessions.count == 2, "independent concurrent owners")
_ = state.handle(["action": "end", "session_id": "a"])
check(state.sessions.count == 1 && state.snapshot()["state"] as? String == "controlling", "one end does not silence the other")
_ = state.handle(["action": "begin", "session_id": "b", "owner": "one"])
check(state.sessions["b"]?.owner == "two", "begin cannot steal a session")
time += 21
state.expire()
check(state.snapshot()["state"] as? String == "unknown" && state.sessions.count == 1, "stale leases are unknown, not released")
_ = state.handle(["action": "keepalive", "session_id": "b"])
check(!state.shouldPlay && state.sessions["b"]?.uncertain == true, "late renewal cannot resurrect a stale controller")
_ = state.handle(["action": "begin", "session_id": "b", "agent": "Claude", "owner": "two"])
check(state.shouldPlay, "an explicit begin restores control")
_ = state.handle(["action": "unknown_owner", "owner": "one"])
check(state.snapshot()["state"] as? String == "controlling", "other-owner interruption leaves this session alone")
_ = state.handle(["action": "set_enabled", "enabled": false])
check(!state.preferences.enabled && state.sessions.count == 1, "mute does not release control")
let recovered = try ControlState(directory: root.appendingPathComponent("state"))
check(!recovered.preferences.enabled && recovered.sessions["b"]?.uncertain == true, "restart preserves mute and recovers sessions as unknown")
_ = state.handle(["action": "end_owner", "owner": "two"])
check(state.sessions.isEmpty, "owner release clears only matching sessions")
check(state.handle(["action": "begin", "session_id": "", "agent": "AI"])["ok"] as? Bool == false, "empty IDs rejected")
check(state.handle(["action": "begin", "session_id": "bad", "ttl": -1])["ok"] as? Bool == false && state.sessions.isEmpty, "bad ttl rejected without mutation")
check(state.handle(["action": "set_volume", "volume": 2])["ok"] as? Bool == false, "out-of-range volume rejected")
check(state.handle(["action": "begin", "session_id": "x", "owner": "auto"])["ok"] as? Bool == false, "the automatic owner name is reserved")
_ = state.handle(["action": "set_enabled", "enabled": true])

// MARK: Automatic detection

check(!state.preferences.autoDetect && !state.noteAutomation(app: "Claude"), "software detection is opt-in")
_ = state.handle(["action": "set_auto_detect", "enabled": true])
check(state.noteAutomation(app: "Claude"), "synthetic input starts an automatic session")
check(state.sessions["auto:Claude"]?.automatic == true && state.snapshot()["state"] as? String == "controlling", "automatic session is live")
_ = state.handle(["action": "end", "session_id": "auto:Claude"])
_ = state.handle(["action": "end_owner", "owner": "auto"])
check(state.sessions["auto:Claude"] != nil, "reported-session commands can't end an automatic session")
let onDisk = try ControlState(directory: root.appendingPathComponent("state"))
check(onDisk.sessions["auto:Claude"] == nil, "automatic sessions are never persisted")
time += state.automaticLinger - 1
state.expire()
check(state.sessions["auto:Claude"] != nil, "automatic session lingers through thinking pauses")
state.noteAutomation(app: "Claude")
time += state.automaticLinger - 1
state.expire()
check(state.sessions["auto:Claude"] != nil, "more synthetic input renews the linger")
time += 2
state.expire()
check(state.sessions.isEmpty, "automatic session ends quietly (not 'unknown') when input stops")
_ = state.handle(["action": "ignore_app", "app": "Logi Options+"])
check(!state.noteAutomation(app: "logi options+") && state.sessions.isEmpty, "ignored apps never start the chase (case-insensitive)")
_ = state.handle(["action": "unignore_app", "app": "Logi Options+"])
check(state.noteAutomation(app: "Logi Options+"), "un-ignoring works")
_ = state.handle(["action": "ignore_app", "app": "Logi Options+"])
check(state.sessions.isEmpty, "ignoring an active app ends its session")
_ = state.handle(["action": "set_auto_detect", "enabled": false])
check(!state.noteAutomation(app: "Claude") && state.sessions.isEmpty, "detection can be switched off")
_ = state.handle(["action": "set_auto_detect", "enabled": true])
_ = state.handle(["action": "status", "via": "claude"])
check(state.preferences.lastSignal["claude"] == time, "hook signals are recorded for connection status")
_ = state.handle(["action": "status", "via": "somebody"])
check(state.preferences.lastSignal["somebody"] == nil, "unknown 'via' values are ignored")
_ = state.handle(["action": "clear"])

// MARK: Hook adapter

let adapter = HookAdapter(client: "codex", directory: root)
for name in ["mcp__cua_repl__js", "mcp__node_repl__js", "mcp__computer-use__left_click", "mcp__computer_use__click",
             "mcp__playwright__browser_click", "mcp__chrome_devtools__click", "computer"] {
    check(adapter.isControlTool(name, input: [:]), "recognizes \(name)")
}
for name in ["Bash", "apply_patch", "mcp__github__create_issue", "mcp__chase-scene__begin_control"] {
    check(!adapter.isControlTool(name, input: [:]), "does not start for \(name)")
}
let start = adapter.request(["session_id": "session", "turn_id": "turn", "hook_event_name": "PreToolUse", "tool_name": "mcp__cua_repl__js"])!
check(start["action"] as? String == "begin" && start["via"] as? String == "codex", "control hook starts music and says who sent it")
let finish = adapter.request(["session_id": "session", "turn_id": "turn", "hook_event_name": "Stop"])!
check(finish["session_id"] as? String == start["session_id"] as? String, "stop targets the matching turn")
let otherTurn = adapter.request(["session_id": "session", "turn_id": "different", "hook_event_name": "Stop"])!
check(otherTurn["session_id"] as? String != start["session_id"] as? String, "other turn cannot clear this turn")
check(adapter.request(["session_id": "session", "hook_event_name": "Interrupt"])?["action"] as? String == "unknown_owner", "interrupt does not pretend pending calls finished")
check(adapter.request(["hook_event_name": "Stop"]) == nil, "malformed hooks don't end everyone")
let claude = HookAdapter(client: "claude", directory: root)
check(claude.request(["session_id": "s", "hook_event_name": "StopFailure"])?["action"] as? String == "unknown_owner", "Claude API failure is 'unknown'")
check(claude.request(["session_id": "s", "agent_id": "sub", "hook_event_name": "SubagentStop"])?["session_id"] as? String == "hook:claude:s:sub", "subagent stop ends only the subagent")

// MARK: Music, expiry and interruption regression checks

_ = state.handle(["action": "begin", "session_id": "lease", "ttl": 1])
time += 2
check(!state.shouldPlay, "expired sessions are silent before the expiry callback")
_ = state.handle(["action": "keepalive", "session_id": "lease"])
check(!state.shouldPlay, "handle expires the lease before accepting a renewal")
_ = state.handle(["action": "begin", "session_id": "lease"])
_ = state.handle(["action": "unknown", "session_id": "lease"])
check(!state.shouldPlay, "interruption is immediately silent")
_ = state.handle(["action": "keepalive", "session_id": "lease"])
check(!state.shouldPlay, "pending hooks cannot resume interrupted playback")
_ = state.handle(["action": "begin", "session_id": "other"])
check(state.shouldPlay, "a live controller still plays alongside a stale one")
_ = state.handle(["action": "end", "session_id": "other"])
check(!state.shouldPlay, "ending the last live controller silences old indicators")
let restarted = try ControlState(directory: root.appendingPathComponent("state"))
check(!restarted.shouldPlay, "restored reported sessions never resume playback")

// MARK: Rolling credits

let legacy = root.appendingPathComponent("legacy")
try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
try Data("{\"enabled\":false,\"volume\":0.07,\"songPath\":\"/personal/song.mp3\"}".utf8)
    .write(to: legacy.appendingPathComponent("preferences.json"))
let upgraded = try ControlState(directory: legacy)
check(!upgraded.preferences.enabled && abs(upgraded.preferences.volume - 0.07) < 0.001
    && upgraded.preferences.songPath == "/personal/song.mp3", "upgrade retains old music settings")
check(!upgraded.preferences.creditsEnabled, "credits are opt-in on upgrade")
check(Credits.generate(task: "Minimize windows").credits.first?.name == "Minnie Mize", "window task has related puns")
check(Credits.generate(task: "Edit a spreadsheet").credits.first?.name == "Celia Formula", "spreadsheet task has related puns")
check(Credits.generate(task: "Design rolling credits").credits[1].name == "Will B. Blurry", "credits do not accidentally match the editing category")
check(Credits.hookTopic(name: "mcp__cua_repl__js", input: ["code": "await tab.goto('https://mail.google.com')", "url": "gmail"]) == "Email", "hook captures a topic label")
_ = state.handle(["action": "clear"])
_ = state.handle(["action": "set_credits_enabled", "enabled": true])
check(!state.shouldShowCredits, "stale sessions never display credits")
_ = state.handle(["action": "set_credits", "task": "Edit a spreadsheet"])
check(!state.hasLiveSession && !state.shouldShowCredits, "preparing credits does not claim desktop control")
_ = state.handle(["action": "begin", "session_id": "credits", "owner": "credits"])
check(state.shouldShowCredits && state.currentCredits.task == "Edit a spreadsheet", "pending credits attach to next control session")
_ = state.handle(["action": "set_enabled", "enabled": false])
check(state.shouldShowCredits && !state.shouldPlay, "credits work while music is muted")
let custom = [["role": "Legal advice", "name": "Dewey, Cheatham and Howe"]]
_ = state.handle(["action": "set_credits", "session_id": "credits", "task": "Contract review", "credits": custom])
_ = state.handle(["action": "begin", "session_id": "credits", "owner": "credits", "credit_topic": "Web browsing"])
check(state.currentCredits.credits.first?.role == "Legal advice", "ordinary hooks retain the AI's custom jokes")
check(state.handle(["action": "set_credits", "task": "Bad", "credits": [["role": "bad\nline", "name": "Test"]]])["ok"] as? Bool == false,
    "invalid credit lines rejected without mutation")
check(state.currentCredits.credits.first?.role == "Legal advice", "invalid update retains working credits")
_ = state.handle(["action": "unknown", "session_id": "credits"])
check(!state.shouldShowCredits, "interruption removes the rolling overlay")
_ = state.handle(["action": "keepalive", "session_id": "credits"])
check(!state.shouldShowCredits, "late hooks cannot resurrect interrupted credits")
check(state.handle(["action": "set_credits_layout", "layout": "invalid"])["ok"] as? Bool == false, "invalid layout rejected")

// MARK: Continuous credits and per-action authoring

let stream = CreditStream()
stream.update(Credits.generate(task: "Organize windows"))
var names: Set<String> = []
for _ in 0..<40 {
    let row = stream.next().credits[0]
    check(names.insert(row.name).inserted, "gap fillers do not repeat a six-name reel")
}
let oldCount = stream.emitted
stream.update(CreditDeck(task: "Place Safari on the left", credits: [Credit(role: "Left wing coordination", name: "Lefty Wright")]))
check(stream.next().task == "Place Safari on the left", "new work replaces unused stale credits immediately")
check(stream.emitted == oldCount + 1, "a workflow update retains stream progress")
let newStream = CreditStream()
newStream.update(CreditDeck(task: "Test shadows", credits: [Credit(role: "Contrast department", name: "Hugh Contrast")]))
check(newStream.next().credits[0].name == "Hugh Contrast", "AI-authored jokes take priority")
newStream.update(CreditDeck(task: "Test shadows", credits: [Credit(role: "Contrast department", name: "Hugh Contrast")]))
check(newStream.next().credits[0].name != "Hugh Contrast", "identical updates do not requeue jokes")
let authored = "// chase-credits: {\"task\":\"Place Safari on the left\",\"credits\":[{\"role\":\"Left wing coordination\",\"name\":\"Lefty Wright\"}]}\nawait app.click(5);"
let authoredHook = adapter.request(["session_id": "live", "turn_id": "now", "hook_event_name": "PreToolUse", "tool_name": "mcp__cua_repl__js", "tool_input": ["code": authored]])!
check(authoredHook["task"] as? String == "Place Safari on the left", "hook transports the AI's exact current activity")
check((authoredHook["credits"] as? [[String: String]])?.first?["name"] == "Lefty Wright", "hook transports original AI-authored puns")
check(Credits.hookCredits(input: ["code": "// chase-credits: {invalid}"]) == nil, "malformed metadata never blocks desktop actions")
check(Credits.hookCredits(input: ["code": "let s = \"// chase-credits: {}\";"]) == nil, "arbitrary script strings do not become credits")

// MARK: JSON editor

let sample = """
{
  "theme": "dark",
  "env": {
    "Z_LAST": "1",
    "A_FIRST": "caf\\u00e9 \\ud83e\\udd54 \\"quoted\\" \\\\ /"
  },
  "numbers": [1, 2.50, -3e2, 0],
  "flags": {"on": true, "off": false, "none": null},
  "empty": {},
  "list": []
}
"""
let parsed = try JSONValue.parse(sample)
check(parsed["env"]?["A_FIRST"]?.stringValue == "café 🥔 \"quoted\" \\ /", "string escapes decode (incl. surrogate pairs)")
check(parsed["numbers"] == .array([.number("1"), .number("2.50"), .number("-3e2"), .number("0")]), "numbers keep their original text")
let rewritten = parsed.serialized()
check(rewritten.range(of: "\"theme\"")!.lowerBound < rewritten.range(of: "\"env\"")!.lowerBound
      && rewritten.range(of: "Z_LAST")!.lowerBound < rewritten.range(of: "A_FIRST")!.lowerBound, "key order is preserved")
check((try? JSONValue.parse(rewritten)) == parsed, "serialize / parse round trip")
check(rewritten.contains("\"empty\": {}") && rewritten.contains("\"list\": []"), "empty containers stay compact")
check((try? JSONSerialization.jsonObject(with: Data(rewritten.utf8))) != nil, "output is valid JSON for Foundation too")
for bad in ["", "{", "{\"a\": }", "[1,]", "{\"a\" 1}", "tru", "{\"a\": 1} x", "\"\\q\"", "01x"] {
    check(throwsError { _ = try JSONValue.parse(bad) }, "rejects invalid JSON: \(bad)")
}

// MARK: Hook merge

let command = Integrations.hookCommand(.claude, launcher: URL(fileURLWithPath: "/Users/x/Library/Application Support/Chase Scene/bin/chase-scene"))
check(command == "'/Users/x/Library/Application Support/Chase Scene/bin/chase-scene' hook claude", "hook command is shell-quoted")
check(Integrations.isOurHook(command) && !Integrations.isOurHook("echo hook claude")
      && !Integrations.isOurHook("'/Applications/Desktop Control Music.app/Contents/MacOS/DesktopControlMusic' hook claude"), "recognizes only its own hooks")
let existing = try JSONValue.parse("""
{"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "existing-command"}]}],
 "Stop": [{"hooks": [{"type": "command", "command": "notify"}, {"type": "command", "command": "\(command)"}]}]}}
""")
let merged = try Integrations.addingOurHooks(existing, client: .claude, command: command)
let mergedTwice = try Integrations.addingOurHooks(merged, client: .claude, command: command)
check(merged == mergedTwice, "connecting twice changes nothing")
check(Integrations.countOurHooks(merged) == Client.claude.events.count, "one handler per event")
check(merged["model"]?.stringValue == "opus" && merged["hooks"]?["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue == "existing-command", "other settings and hooks are kept")
let (removed, count) = try Integrations.removingOurHooks(merged)
check(count == Client.claude.events.count && Integrations.countOurHooks(removed) == 0, "disconnect removes every Chase Scene handler")
check(removed["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.count == 1, "mixed groups keep the other handlers")
check(removed["hooks"]?["PostToolUse"] == nil, "event lists emptied by disconnect are dropped")
check(throwsError { _ = try Integrations.addingOurHooks(.array([]), client: .claude, command: command) }, "refuses a non-object settings file")
check(throwsError { _ = try Integrations.addingOurHooks(try JSONValue.parse("{\"hooks\": []}"), client: .claude, command: command) }, "refuses a malformed hooks section")

// MARK: Connect / disconnect on a fake home folder

let home = root.appendingPathComponent("home")
let stateDir = root.appendingPathComponent("home-state")
check(throwsError { _ = try Integrations.connect(.claude, home: home, state: stateDir) }, "won't invent config for a client that isn't installed")
try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
let settings = home.appendingPathComponent(".claude/settings.json")
let original = "{\n  \"zebra\": 1,\n  \"apple\": {\n    \"nested\": true\n  }\n}\n"
try original.write(to: settings, atomically: true, encoding: .utf8)
_ = try Integrations.connect(.claude, home: home, state: stateDir)
check(Integrations.isConnected(.claude, home: home), "connect writes hooks")
let afterConnect = try String(contentsOf: settings, encoding: .utf8)
check(afterConnect.hasPrefix("{\n  \"zebra\": 1,\n  \"apple\": {"), "connect keeps the user's key order")
let backups = try FileManager.default.contentsOfDirectory(atPath: stateDir.appendingPathComponent("backups").path)
check(backups.count == 1, "a backup is saved before changing the file")
_ = try Integrations.disconnect(.claude, home: home, state: stateDir)
check((try? String(contentsOf: settings, encoding: .utf8)) == original, "connect + disconnect restores the file exactly")
check(!Integrations.isConnected(.claude, home: home), "disconnect removes hooks")
try "{ not json".write(to: settings, atomically: true, encoding: .utf8)
check(throwsError { _ = try Integrations.connect(.claude, home: home, state: stateDir) }, "invalid JSON is reported")
check((try? String(contentsOf: settings, encoding: .utf8)) == "{ not json", "…and left untouched")
let launcher = Integrations.launcherURL(state: stateDir)
check((try? FileManager.default.destinationOfSymbolicLink(atPath: launcher.path)) != nil, "a stable launcher symlink is created")
check(Integrations.mcpConfig(state: stateDir).contains("\"args\": [\n        \"mcp\"\n      ]"), "MCP config snippet is valid and points at the launcher")

print("Passed \(checks) core checks")
