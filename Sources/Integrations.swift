import Foundation

/// One-click hook integrations for AI coding agents that can drive the desktop.
/// Benny Hill Climber only ever adds or removes its own entries; everything else in the file is preserved
/// (including key order), and a backup is saved before each change.
enum Client: String, CaseIterable {
    case claude, codex

    var displayName: String { self == .claude ? "Claude Code" : "Codex" }

    func configDirectory(home: URL) -> URL {
        home.appendingPathComponent(self == .claude ? ".claude" : ".codex")
    }

    func hooksFile(home: URL) -> URL {
        configDirectory(home: home).appendingPathComponent(self == .claude ? "settings.json" : "hooks.json")
    }

    func isInstalled(home: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: configDirectory(home: home).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var events: [String] {
        ["PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
            + (self == .codex ? ["Interrupt"] : ["PostToolUseFailure", "SubagentStop", "StopFailure"])
    }

    /// What the user has to do after connecting before hooks fire.
    var activationHint: String {
        self == .claude
            ? "Restart Claude Code (or start a new session) to activate."
            : "In Codex, run /hooks and approve the Benny Hill Climber entries, then start a new session."
    }
}

enum Integrations {
    static func home() -> URL {
        if let path = ProcessInfo.processInfo.environment["CHASE_SCENE_HOME"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// A stable path for hook commands. It is a symlink that the app re-points at itself on every
    /// launch, so moving or updating the app never breaks (or re-triggers review of) the hooks.
    static func launcherURL(state: URL = stateDirectory()) -> URL {
        state.appendingPathComponent("bin/chase-scene")
    }

    @discardableResult static func refreshLauncher(state: URL = stateDirectory()) throws -> URL {
        let launcher = launcherURL(state: state)
        let target = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        guard !target.path.contains("/AppTranslocation/") else {
            throw ControlError.invalid("Move Benny Hill Climber into your Applications folder, open it from there, then try again.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if let current = try? fm.destinationOfSymbolicLink(atPath: launcher.path), current == target.path { return launcher }
        let temporary = launcher.deletingLastPathComponent().appendingPathComponent(".chase-scene-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: target.path)
        if rename(temporary.path, launcher.path) != 0 {
            try? fm.removeItem(at: temporary)
            throw ControlError.invalid("Could not update \(launcher.path).")
        }
        return launcher
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func hookCommand(_ client: Client, launcher: URL) -> String {
        shellQuote(launcher.path) + " hook " + client.rawValue
    }

    static func isOurHook(_ command: String) -> Bool {
        command.range(of: #"(chase-scene|ChaseScene)'? hook (claude|codex)\b"#, options: .regularExpression) != nil
    }

    // MARK: Pure document transforms (unit tested)

    static func removingOurHooks(_ document: JSONValue) throws -> (JSONValue, removed: Int) {
        guard document.isObject else { throw ControlError.invalid("The settings file is not a JSON object.") }
        guard let hooks = document["hooks"] else { return (document, 0) }
        guard case .object(let events) = hooks else { throw ControlError.invalid("\"hooks\" is not a JSON object.") }
        var removed = 0
        var keptEvents: [JSONMember] = []
        for event in events {
            guard case .array(let groups) = event.value else { keptEvents.append(event); continue }
            var keptGroups: [JSONValue] = []
            var touched = false
            for group in groups {
                guard case .array(let handlers)? = group["hooks"] else { keptGroups.append(group); continue }
                let kept = handlers.filter { !isOurHook($0["command"]?.stringValue ?? "") }
                if kept.count == handlers.count { keptGroups.append(group); continue }
                removed += handlers.count - kept.count
                touched = true
                if !kept.isEmpty {
                    var updated = group
                    updated["hooks"] = .array(kept)
                    keptGroups.append(updated)
                }
            }
            if touched && keptGroups.isEmpty { continue }   // drop event lists we emptied
            keptEvents.append(JSONMember(key: event.key, value: .array(keptGroups)))
        }
        var result = document
        // If only Benny Hill Climber's hooks were there, leave no empty "hooks": {} behind.
        result["hooks"] = keptEvents.isEmpty && removed > 0 ? nil : JSONValue.object(keptEvents)
        return (result, removed)
    }

    static func addingOurHooks(_ document: JSONValue, client: Client, command: String) throws -> JSONValue {
        var result = try removingOurHooks(document).0
        var hooks = result["hooks"] ?? .object([])
        for event in client.events {
            var handler = JSONValue.object([])
            handler["type"] = .string("command")
            handler["command"] = .string(command)
            handler["timeout"] = .number("3")
            var group = JSONValue.object([])
            if ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(event) { group["matcher"] = .string(".*") }
            group["hooks"] = .array([handler])
            var list = hooks[event]?.arrayValue ?? []
            list.append(group)
            hooks[event] = .array(list)
        }
        result["hooks"] = hooks
        return result
    }

    static func countOurHooks(_ document: JSONValue) -> Int {
        guard case .object(let events)? = document["hooks"] else { return 0 }
        var count = 0
        for event in events {
            for group in event.value.arrayValue ?? [] {
                count += (group["hooks"]?.arrayValue ?? []).filter { isOurHook($0["command"]?.stringValue ?? "") }.count
            }
        }
        return count
    }

    // MARK: File operations

    static func readDocument(_ url: URL) throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: url.path) else { return .object([]) }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return .object([]) }
        do { return try JSONValue.parse(data) } catch {
            throw ControlError.invalid("\(url.path) isn't valid JSON (\(error)). Nothing was changed.")
        }
    }

    static func isConnected(_ client: Client, home: URL = home()) -> Bool {
        guard let document = try? readDocument(client.hooksFile(home: home)) else { return false }
        return countOurHooks(document) > 0
    }

    static func backup(_ url: URL, client: Client, state: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = state.appendingPathComponent("backups/\(formatter.string(from: Date()))-\(client.rawValue)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
    }

    static func write(_ document: JSONValue, to url: URL) throws {
        let text = document.serialized() + "\n"
        let fm = FileManager.default
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
        let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write through a symlinked settings file (dotfile managers) instead of replacing the link.
        let destination = url.resolvingSymlinksInPath()
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).chase-scene-\(UUID().uuidString)")
        try Data(text.utf8).write(to: temporary)
        try fm.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: temporary.path)
        if rename(temporary.path, destination.path) != 0 {
            try? fm.removeItem(at: temporary)
            throw ControlError.invalid("Could not write \(destination.path).")
        }
    }

    /// Adds (or refreshes) Benny Hill Climber's hook entries for one client.
    static func connect(_ client: Client, home: URL = home(), state: URL = stateDirectory()) throws -> String {
        guard client.isInstalled(home: home) else {
            throw ControlError.invalid("\(client.displayName) doesn't seem to be installed (no \(client.configDirectory(home: home).path)).")
        }
        let file = client.hooksFile(home: home)
        let document = try readDocument(file)
        let launcher = try refreshLauncher(state: state)
        let updated = try addingOurHooks(document, client: client, command: hookCommand(client, launcher: launcher))
        if updated != document {
            try backup(file, client: client, state: state)
            try write(updated, to: file)
        }
        return "Connected \(client.displayName). \(client.activationHint)"
    }

    /// Removes only Benny Hill Climber's entries, leaving everything else as it is.
    static func disconnect(_ client: Client, home: URL = home(), state: URL = stateDirectory()) throws -> String {
        let file = client.hooksFile(home: home)
        guard FileManager.default.fileExists(atPath: file.path) else { return "\(client.displayName) was not connected." }
        let document = try readDocument(file)
        let (updated, removed) = try removingOurHooks(document)
        guard removed > 0 else { return "\(client.displayName) was not connected." }
        try backup(file, client: client, state: state)
        try write(updated, to: file)
        return "Disconnected \(client.displayName)."
    }

    static func mcpConfig(state: URL = stateDirectory()) -> String {
        var server = JSONValue.object([])
        server["command"] = .string(launcherURL(state: state).path)
        server["args"] = .array([.string("mcp")])
        var servers = JSONValue.object([])
        servers["chase-scene"] = server
        var root = JSONValue.object([])
        root["mcpServers"] = servers
        return root.serialized()
    }
}
