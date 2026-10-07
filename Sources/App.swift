import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

final class ChaseSceneApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state: ControlState
    let testMode: Bool
    var server: IPCServer?
    var item: NSStatusItem?
    var detector: SyntheticInputDetector?
    var player: AVAudioPlayer?
    var loadedPath: String?
    var audioError: String?
    var expiryTimer: Timer?
    var timerInterval: TimeInterval = 0
    var pauseWork: DispatchWorkItem?
    var pausedAt: Date?
    var fadingOut = false
    var didStart = false

    static let builtInSongName = "Hot Potato Hustle"

    init(testMode: Bool = false) throws {
        self.testMode = testMode
        state = try ControlState(directory: stateDirectory())
        super.init()
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            server = IPCServer(directory: state.directory) { [weak self] request in
                guard let self else { return ["ok": false] }
                if request["action"] as? String == "demo" { return self.startPreview() }
                return self.state.handle(request)
            }
            try server!.start()
            didStart = true
        } catch {
            if !String(describing: error).contains("already running") && !testMode {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Chase Scene could not start"
                alert.informativeText = String(describing: error)
                alert.runModal()
            }
            NSApp.terminate(nil)
            return
        }
        if let linger = ProcessInfo.processInfo.environment["CHASE_SCENE_AUTO_LINGER"].flatMap({ Double($0) }), linger > 0 {
            state.automaticLinger = linger
        }
        if state.preferences.quitByUser {
            state.preferences.quitByUser = false
            state.persist()
        }
        state.changed = { [weak self] in self?.refresh() }
        state.audioStatus = { [weak self] in
            guard let self else { return [:] }
            var status: [String: Any] = ["playing": (self.player?.isPlaying ?? false) && !self.fadingOut,
                                        "audio_available": !self.testMode && self.player != nil,
                                        "detector_running": self.detector?.isRunning ?? false]
            if let audioError = self.audioError { status["audio_error"] = audioError }
            return status
        }
        detector = SyntheticInputDetector { [weak self] app in _ = self?.state.noteAutomation(app: app) }
        updateDetector()
        if !testMode {
            try? Integrations.refreshLauncher(state: state.directory)
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
            item = statusItem
        }
        refresh()
        if !testMode && !state.preferences.welcomed {
            DispatchQueue.main.async { [weak self] in self?.showWelcome() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reported sessions come back as "unknown" when the app is reopened.
        if didStart { state.persist() }
        player?.stop()
    }

    func updateDetector() {
        if state.preferences.autoDetect { detector?.start() } else { detector?.stop() }
    }

    func refresh() {
        updateAudio()
        let live = state.sessions.values.filter { !$0.uncertain }
        let wanted: TimeInterval = live.isEmpty ? 0 : (live.contains { $0.automatic } ? 1 : 5)
        if wanted != timerInterval {
            expiryTimer?.invalidate()
            expiryTimer = nil
            if wanted > 0 {
                let timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
                    _ = self?.state.expire()
                }
                timer.tolerance = wanted / 4
                expiryTimer = timer
            }
            timerInterval = wanted
        }
        updateIcon()
    }

    func updateIcon() {
        guard let button = item?.button else { return }
        let active = !state.sessions.isEmpty
        let unknown = state.sessions.values.contains { $0.uncertain }
        let image = NSImage(systemSymbolName: active ? "figure.run" : "music.note", accessibilityDescription: appName)
            ?? NSImage(systemSymbolName: active ? "cursorarrow.rays" : "music.note", accessibilityDescription: appName)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
        button.contentTintColor = active ? (unknown ? .systemOrange : .systemGreen) : nil
        button.title = active && unknown ? " ?" : ""
        let who = state.sessions.values.map { $0.agent }.sorted().joined(separator: ", ")
        button.toolTip = active ? (unknown ? "Chase Scene: control state unknown" : "Chase Scene: \(who) is driving")
                                : "Chase Scene: watching for AI mouse control"
    }

    // MARK: Audio

    var builtInSongURL: URL? { Bundle.main.url(forResource: "hot-potato-hustle", withExtension: "m4a") }

    func makePlayer(_ url: URL) throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = -1
        player.prepareToPlay()
        return player
    }

    func loadPlayer() {
        let custom = state.preferences.songPath
        guard let path = custom ?? builtInSongURL?.path else {
            audioError = "The built-in song is missing. Choose a song in Settings."
            return
        }
        if path == loadedPath { return }
        loadedPath = path
        pausedAt = nil
        player?.stop()
        player = nil
        do {
            player = try makePlayer(URL(fileURLWithPath: path))
            audioError = nil
        } catch {
            if custom != nil, let fallback = builtInSongURL, let backup = try? makePlayer(fallback) {
                player = backup
                audioError = "Couldn't play \((path as NSString).lastPathComponent); using \(Self.builtInSongName)."
            } else {
                audioError = "Couldn't play the song. Choose another one in Settings."
            }
        }
    }

    func updateAudio() {
        guard !testMode else { return }
        loadPlayer()
        guard let player else { return }
        let previewing = state.sessions["demo"] != nil
        let shouldPlay = !state.sessions.isEmpty && (state.preferences.enabled || previewing)
        if shouldPlay {
            pauseWork?.cancel()
            pauseWork = nil
            if !player.isPlaying {
                if let pausedAt, Date().timeIntervalSince(pausedAt) > 90 { player.currentTime = 0 }
                player.volume = 0
                if !player.play() {
                    audioError = "Audio playback failed. Check your sound output."
                    return
                }
                player.setVolume(state.preferences.volume, fadeDuration: 0.15)
            } else if fadingOut {
                player.setVolume(state.preferences.volume, fadeDuration: 0.15)
            }
            fadingOut = false
        } else if player.isPlaying {
            if !state.preferences.enabled {
                pauseNow()                       // muting is immediate
            } else if !fadingOut {
                fadingOut = true                 // the chase is over: fade out gracefully
                player.setVolume(0, fadeDuration: 1.5)
                let work = DispatchWorkItem { [weak self] in self?.pauseNow() }
                pauseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            }
        }
    }

    func pauseNow() {
        pauseWork?.cancel()
        pauseWork = nil
        player?.pause()
        fadingOut = false
        pausedAt = Date()
    }

    func startPreview() -> [String: Any] {
        let result = state.handle(["action": "begin", "session_id": "demo", "agent": "Song preview", "owner": "demo", "ttl": 10])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            _ = self?.state.handle(["action": "end", "session_id": "demo"])
        }
        return result
    }

    // MARK: Menu

    private func action(_ title: String, _ selector: Selector, _ object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    private func label(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach { menu.addItem($0) }
        parent.submenu = menu
        return parent
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = state.sessions.values.sorted { $0.agent < $1.agent }
        let header: String
        if sessions.isEmpty {
            header = state.preferences.autoDetect ? "Watching for AI mouse control" : "Waiting for connected AI tools"
        } else if sessions.contains(where: { $0.uncertain }) {
            header = "Control state unknown"
        } else {
            header = "Chase in progress!"
        }
        menu.addItem(label(header))
        for session in sessions {
            let detail = session.uncertain ? "signal lost"
                : session.id == "demo" ? "playing" : session.automatic ? "moving the mouse" : "in control"
            menu.addItem(label("    \(session.agent) — \(detail)"))
        }
        for session in sessions where session.automatic {
            menu.addItem(action("Not an AI? Ignore “\(session.agent)”", #selector(ignoreApp(_:)), session.agent))
        }
        if let audioError { menu.addItem(label(audioError)) }
        menu.addItem(.separator())

        let toggle = action("Chase music", #selector(toggleMusic))
        toggle.state = state.preferences.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(volumeItem())
        menu.addItem(action("Preview the music", #selector(preview)))
        menu.addItem(.separator())
        menu.addItem(submenu("Settings", settingsItems()))
        if !sessions.isEmpty { menu.addItem(action("Clear indicator…", #selector(clearIndicator))) }
        menu.addItem(action("Help", #selector(showHelp)))
        menu.addItem(action("Quit Chase Scene", #selector(quit)))
    }

    func volumeItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        let label = NSTextField(labelWithString: "Volume")
        label.frame = NSRect(x: 20, y: 6, width: 56, height: 18)
        view.addSubview(label)
        let slider = NSSlider(value: Double(state.preferences.volume), minValue: 0, maxValue: 1,
                              target: self, action: #selector(changeVolume(_:)))
        slider.frame = NSRect(x: 80, y: 5, width: 154, height: 20)
        slider.isContinuous = true
        view.addSubview(slider)
        item.view = view
        return item
    }

    func settingsItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let auto = action("Detect AI mouse control automatically", #selector(toggleAutoDetect))
        auto.state = state.preferences.autoDetect ? .on : .off
        items.append(auto)
        if !state.preferences.ignoredApps.isEmpty {
            items.append(submenu("Ignored apps", state.preferences.ignoredApps.map {
                action("Stop ignoring “\($0)”", #selector(unignoreApp(_:)), $0)
            }))
        }
        items.append(.separator())
        let songName = state.preferences.songPath.map { ($0 as NSString).lastPathComponent } ?? "\(Self.builtInSongName) (built in)"
        items.append(label("Song: \(songName)"))
        items.append(action("Choose your own song…", #selector(chooseSong)))
        if state.preferences.songPath != nil {
            items.append(action("Use \(Self.builtInSongName)", #selector(useBuiltInSong)))
        }
        items.append(.separator())
        items.append(label("Exact timing for AI coding tools (optional)"))
        let home = Integrations.home()
        for client in Client.allCases {
            guard client.isInstalled(home: home) else {
                items.append(label("    \(client.displayName): not found on this Mac"))
                continue
            }
            if Integrations.isConnected(client, home: home) {
                items.append(submenu("    \(client.displayName): \(connectionStatus(client))", [
                    label(client.activationHint),
                    action("Disconnect \(client.displayName)", #selector(disconnectClient(_:)), client.rawValue),
                ]))
            } else {
                items.append(action("    Connect \(client.displayName)…", #selector(connectClient(_:)), client.rawValue))
            }
        }
        items.append(action("    Copy MCP server config (other AI tools)", #selector(copyMCPConfig)))
        items.append(.separator())
        let login = action("Open at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        items.append(login)
        return items
    }

    func connectionStatus(_ client: Client) -> String {
        guard let last = state.preferences.lastSignal[client.rawValue] else { return "connected, waiting for first signal" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "working ✓ (last signal \(formatter.localizedString(for: Date(timeIntervalSince1970: last), relativeTo: Date())))"
    }

    // MARK: Actions

    @objc func toggleMusic() { _ = state.handle(["action": "set_enabled", "enabled": !state.preferences.enabled]) }

    @objc func changeVolume(_ sender: NSSlider) {
        state.preferences.volume = Float(sender.doubleValue)
        if let player, player.isPlaying, !fadingOut { player.volume = state.preferences.volume }
        state.persist()
    }

    @objc func preview() { _ = startPreview() }

    @objc func toggleAutoDetect() {
        _ = state.handle(["action": "set_auto_detect", "enabled": !state.preferences.autoDetect])
        updateDetector()
    }

    @objc func ignoreApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        _ = state.handle(["action": "ignore_app", "app": app])
    }

    @objc func unignoreApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        _ = state.handle(["action": "unignore_app", "app": app])
    }

    @objc func chooseSong() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose your chase music"
        panel.message = "Pick any audio file you own (MP3, M4A, WAV, AIFF…). It loops while an AI is driving."
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.preferences.songPath = url.path
            state.persist()
            refresh()
            _ = startPreview()
        }
    }

    @objc func useBuiltInSong() {
        state.preferences.songPath = nil
        state.persist()
        refresh()
    }

    func inform(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @objc func connectClient(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let client = Client(rawValue: raw) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect \(client.displayName)?"
        alert.informativeText = """
        Chase Scene will add a few hook entries to \(client.hooksFile(home: Integrations.home()).path) so \(client.displayName) \
        tells it exactly when computer use starts and ends. The music then plays straight through the AI's thinking pauses.

        Only Chase Scene's own entries are added, everything else stays as it is, and a backup is saved first. \
        You can disconnect any time from this menu.
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { inform("\(client.displayName) connected", try Integrations.connect(client)) }
        catch { inform("Couldn't connect \(client.displayName)", String(describing: error)) }
    }

    @objc func disconnectClient(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let client = Client(rawValue: raw) else { return }
        do { inform("\(client.displayName) disconnected", try Integrations.disconnect(client)) }
        catch { inform("Couldn't disconnect \(client.displayName)", String(describing: error)) }
    }

    @objc func copyMCPConfig() {
        let launcher = try? Integrations.refreshLauncher(state: state.directory)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Integrations.mcpConfig(state: state.directory), forType: .string)
        inform("MCP config copied", """
        Paste it into your AI tool's MCP settings. The AI can then call begin_control before it drives your Mac \
        and end_control when it's done.\(launcher == nil ? "\n\nTip: move Chase Scene into your Applications folder first." : "")
        """)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            inform("Couldn't change the login setting", error.localizedDescription)
        }
    }

    @objc func clearIndicator() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear the indicator?"
        alert.informativeText = "This stops the music and forgets the current sessions. It does not stop an AI, so use it after you've stopped the task."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { _ = state.handle(["action": "clear"]) }
    }

    @objc func showHelp() {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "html") { NSWorkspace.shared.open(url) }
    }

    @objc func quit() {
        // Remember that the person chose to quit, so an AI tool's hook doesn't reopen the app.
        state.preferences.quitByUser = true
        state.persist()
        NSApp.terminate(nil)
    }

    // MARK: First run

    func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Chase Scene is on duty"
        alert.informativeText = """
        Whenever an AI (or any other app) starts driving your mouse, you'll hear chase music, so you always know \
        who's at the wheel.

        Chase Scene lives in your menu bar: look for the ♪. That's where you mute it, change the volume or pick your own song.

        It only listens. It never controls anything, and nothing leaves your Mac.
        """
        let login = NSButton(checkboxWithTitle: "Open Chase Scene when I log in", target: nil, action: nil)
        login.state = .on
        var rows: [NSButton] = [login]
        var clientBoxes: [(Client, NSButton)] = []
        let home = Integrations.home()
        for client in Client.allCases where client.isInstalled(home: home) && !Integrations.isConnected(client, home: home) {
            let box = NSButton(checkboxWithTitle: "Also connect \(client.displayName) for exact timing", target: nil, action: nil)
            box.state = .off
            rows.append(box)
            clientBoxes.append((client, box))
        }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: CGFloat(rows.count) * 24))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(rows.count - 1 - index) * 24, width: 360, height: 22)
            view.addSubview(row)
        }
        alert.accessoryView = view
        alert.addButton(withTitle: "Play a preview")
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()

        state.preferences.welcomed = true
        state.persist()
        if login.state == .on, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        var messages: [String] = []
        for (client, box) in clientBoxes where box.state == .on {
            do { messages.append(try Integrations.connect(client)) } catch { messages.append(String(describing: error)) }
        }
        if response == .alertFirstButtonReturn { _ = startPreview() }
        if !messages.isEmpty { inform("Connections", messages.joined(separator: "\n\n")) }
    }
}
