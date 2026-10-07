import Foundation
import Darwin

let bundleIdentifier = "io.github.mhrtly.ChaseScene"

func stateDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["CHASE_SCENE_STATE_DIR"] { return URL(fileURLWithPath: path) }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Chase Scene")
}

func address(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        throw ControlError.invalid("Local socket path is too long.")
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { target in target.copyBytes(from: bytes) }
    return addr
}

func withAddress<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func configureSocket(_ fd: Int32) {
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw ControlError.invalid("Local connection closed while sending.") }
            offset += written
        }
    }
}

func readMessage(_ fd: Int32) throws -> [String: Any] {
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while data.count < 65536 {
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ControlError.invalid("Local connection timed out or closed.") }
        data.append(contentsOf: bytes.prefix(count))
        if let end = data.firstIndex(of: 10) {
            guard let object = try JSONSerialization.jsonObject(with: data.prefix(upTo: end)) as? [String: Any] else {
                throw ControlError.invalid("Expected a JSON object.")
            }
            return object
        }
    }
    throw ControlError.invalid("Message exceeds 64 KiB.")
}

func jsonLine(_ object: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    data.append(10)
    return data
}

let notRunningMessage = "Chase Scene is not running. Open it from your Applications folder."

func sendRequest(_ request: [String: Any], directory: URL = stateDirectory()) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlError.invalid("Could not create local socket.") }
    defer { close(fd) }
    configureSocket(fd)
    var addr = try address(directory.appendingPathComponent("control.sock").path)
    guard withAddress(&addr, { connect(fd, $0, $1) }) == 0 else {
        throw ControlError.invalid(notRunningMessage)
    }
    try writeAll(fd, jsonLine(request))
    return try readMessage(fd)
}

/// The .app bundle this executable lives in, even when it was started through the stable
/// launcher symlink that hooks point at.
func enclosingAppBundle() -> URL? {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle : nil
}

@discardableResult func openApp(arguments: [String]) -> Bool {
    func run(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    if let bundle = enclosingAppBundle(), run(arguments + [bundle.path]) { return true }
    return run(arguments + ["-b", bundleIdentifier])
}

/// Sends a request, opening the menu-bar app in the background first if needed.
/// Respects the user's choice: after "Quit Chase Scene", AI tools don't reopen it.
func requestWithLaunch(_ request: [String: Any], launch: Bool = true) throws -> [String: Any] {
    if let result = try? sendRequest(request) { return result }
    let environment = ProcessInfo.processInfo.environment
    if launch && environment["CHASE_SCENE_NO_AUTO_LAUNCH"] != "1" && !Preferences.load(from: stateDirectory()).quitByUser {
        if openApp(arguments: ["-g"]) {
            for _ in 0..<40 {
                if let result = try? sendRequest(request) { return result }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    return try sendRequest(request)
}

/// Runs work on the main thread through the run loop's common modes, so requests are still
/// answered while a menu is open or a dialog is up (DispatchQueue.main can stall in those cases).
func onMainRunLoop(_ work: @escaping () -> [String: Any]) -> [String: Any] {
    final class Box { var value: [String: Any] = ["ok": false, "error": "Chase Scene is busy; try again."] }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        box.value = work()
        done.signal()
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    _ = done.wait(timeout: .now() + 1.5)
    return box.value
}

final class IPCServer {
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private let path: String
    private let directory: URL
    var handler: ([String: Any]) -> [String: Any]

    init(directory: URL, handler: @escaping ([String: Any]) -> [String: Any]) {
        self.directory = directory
        path = directory.appendingPathComponent("control.sock").path
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        lockFD = Darwin.open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw ControlError.invalid("Chase Scene is already running.")
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.invalid("Could not create socket.") }
        configureSocket(fd)
        unlink(path)
        var addr = try address(path)
        guard withAddress(&addr, { bind(fd, $0, $1) }) == 0, listen(fd, 16) == 0 else {
            throw ControlError.invalid("Could not listen for local control events: \(String(cString: strerror(errno))).")
        }
        chmod(path, 0o600)
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                configureSocket(client)
                // Per-client readers keep one stalled client from blocking every other agent.
                DispatchQueue.global(qos: .utility).async { [self] in
                    defer { close(client) }
                    let response: [String: Any]
                    do {
                        let request = try readMessage(client)
                        response = onMainRunLoop { self.handler(request) }
                    } catch { response = ["ok": false, "error": String(describing: error)] }
                    try? writeAll(client, jsonLine(response))
                }
            }
        }
    }
}
