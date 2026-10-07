import AppKit
import Darwin

/// Notices when some *program* — not your hand on the mouse — moves or clicks the pointer.
///
/// Computer-use agents drive the Mac by posting synthetic mouse events. macOS stamps every posted
/// event with the process ID of the poster; events from real hardware carry 0. Watching mouse
/// events through an NSEvent monitor needs no special permission, records nothing, and never
/// blocks or changes the events themselves.
final class SyntheticInputDetector {
    /// System helpers that legitimately move the pointer for a person (accessibility features,
    /// Universal Control). Users can ignore anything else from the menu.
    static let builtInIgnored: Set<String> = [
        "WindowServer", "UniversalControl", "universalaccessd", "AssistiveControl",
        "CommandAndControl", "VoiceOver", "loginwindow",
    ]

    private var monitors: [Any] = []
    private var lastReport: [pid_t: TimeInterval] = [:]
    private var names: [pid_t: String] = [:]
    private let ownPID = getpid()
    var onAutomation: (String) -> Void

    init(onAutomation: @escaping (String) -> Void) {
        self.onAutomation = onAutomation
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .rightMouseDragged, .mouseMoved]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.inspect(event)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.inspect(event)
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func inspect(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }
        let pid = pid_t(truncatingIfNeeded: cgEvent.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid > 0, pid != ownPID else { return }      // 0 = real hardware / the system itself
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastReport[pid], now - last < 1 { return }  // at most one report per second per process
        lastReport[pid] = now
        if lastReport.count > 256 { lastReport = lastReport.filter { now - $0.value < 60 } }
        let name = names[pid] ?? SyntheticInputDetector.processName(pid)
        names[pid] = name
        if names.count > 256 { names.removeAll() }
        guard !SyntheticInputDetector.builtInIgnored.contains(name) else { return }
        onAutomation(name)
    }

    /// A friendly name for the process that posted an event: the outermost app bundle it lives in
    /// ("Claude", "Codex", "Terminal"…), or the executable name for command-line tools ("python3").
    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if let range = path.range(of: ".app/") {
                return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            }
            return (path as NSString).lastPathComponent
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        return "process \(pid)"
    }
}
