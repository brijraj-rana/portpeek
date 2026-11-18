import Darwin
import Foundation

/// One process listening on one TCP port.
public struct PortEntry: Identifiable, Equatable, Sendable {
    public var port: Int
    public var pid: Int32
    public var process: String
    public var user: String
    /// Addresses the socket is bound to: "*" for every interface, or loopback addresses.
    public var hosts: [String]
    public var executable: String?
    public var directory: String?
    /// The app it was started from, found by walking up the parent processes.
    public var origin: Origin?
    /// The controlling terminal, which is how a terminal tab is matched to the process.
    public var tty: String?
    /// Seconds the process has been running.
    public var uptime: TimeInterval?
    /// The whole command line of the process holding the port.
    public var command: String?
    /// Resident memory of that process, in bytes.
    public var memory: Int64?
    /// What to run, and where, to start it again. See `ProcessTable.launcher`.
    public var launchCommand: String?
    public var launchDirectory: String?
    /// Set when the listener is a container runtime forwarding the port, not the server itself.
    public var runtime: ContainerRuntime?
    /// The container that published the port, when the runtime's own tool could say.
    public var container: ContainerInfo?

    public var id: String { "\(pid):\(port)" }

    public init(port: Int, pid: Int32, process: String, user: String = "", hosts: [String] = [],
                executable: String? = nil, directory: String? = nil,
                origin: Origin? = nil, tty: String? = nil, uptime: TimeInterval? = nil,
                command: String? = nil, memory: Int64? = nil,
                launchCommand: String? = nil, launchDirectory: String? = nil,
                runtime: ContainerRuntime? = nil, container: ContainerInfo? = nil) {
        self.port = port
        self.pid = pid
        self.process = process
        self.user = user
        self.hosts = hosts
        self.executable = executable
        self.directory = directory
        self.origin = origin
        self.tty = tty
        self.uptime = uptime
        self.command = command
        self.memory = memory
        self.launchCommand = launchCommand
        self.launchDirectory = launchDirectory
        self.runtime = runtime
        self.container = container
    }

    /// The folder the process was started in, which for a dev server is the project.
    public var project: String? {
        // A runtime forwarding a container's port runs wherever it likes; that folder is nobody's project.
        guard runtime == nil, let directory, directory != "/", directory != NSHomeDirectory() else { return nil }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Part of macOS itself (AirPlay, Handoff and the like), not something you started.
    public var isSystem: Bool {
        guard let executable else { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { executable.hasPrefix($0) }
    }

    /// The app this process belongs to, when it runs from inside an app bundle ("Code Helper (Plugin)" is Visual Studio Code).
    public var appName: String? {
        executable.flatMap(Host.bundleName)
    }

    /// Where it was started from, when that says more than the name already does.
    public var startedFrom: Origin? {
        guard let origin, !origin.isOwnApp else { return nil }
        return origin
    }

    /// "localhost:3000", for pasting into a config file or an address bar.
    public var address: String {
        "localhost:\(port)"
    }

    /// What to call it in a list: the container when there is one, then the app, then the process.
    public var displayName: String {
        if let container { return container.name }
        if let runtime { return runtime.name }
        return appName ?? process
    }

    /// "http://localhost:3000", whether or not a browser would have anything to show.
    public var link: String {
        "http://localhost:\(port)"
    }

    /// What the stop button on this row may do.
    public enum StopAction: Equatable, Sendable {
        /// Signal the process: SIGTERM, then SIGKILL if asked again.
        case signal
        /// Stop one container. The runtime that forwards its port is left alone.
        case container(ContainerInfo)
        /// A container runtime's port with no known container behind it. Killing the runtime would take every container with it.
        case nothing
    }

    public var stopAction: StopAction {
        guard runtime != nil else { return .signal }
        if let container { return .container(container) }
        return .nothing
    }

    /// `cd <folder> && <command>`: what to paste into a terminal to start it again. Nil unless both halves are known,
    /// and nil for containers, system services and apps, which are not started that way.
    public var restartCommand: String? {
        guard runtime == nil, !isSystem, appName == nil else { return nil }
        guard let command = launchCommand ?? command, let directory = launchDirectory ?? directory else { return nil }
        return "cd \(ShellQuote.quote(directory)) && \(command)"
    }

    /// Not something you started on purpose: system services, anything on a random high port,
    /// and app helpers that only listen on loopback to talk to themselves.
    public var isBackground: Bool {
        // A port a container published is something you asked for, even on loopback.
        if container != nil { return false }
        return isSystem || port >= 49152 || (appName != nil && isLocalOnly)
    }

    /// True when only this Mac can reach it.
    public var isLocalOnly: Bool {
        !hosts.isEmpty && hosts.allSatisfy { $0 == "127.0.0.1" || $0 == "::1" || $0 == "localhost" }
    }

    /// Databases and caches speak their own protocols; a browser has nothing to show for them.
    public var servesHTTP: Bool {
        // For a container it is the port inside that says what is being served; the host port can be anything.
        !Self.nonHTTPPorts.contains(container?.containerPort ?? port)
    }

    public var url: URL? {
        servesHTTP ? URL(string: "http://localhost:\(port)") : nil
    }

    static let nonHTTPPorts: Set<Int> = [22, 25, 53, 1433, 1521, 3306, 5432, 5672, 6379, 9092, 11211, 27017]
}

public enum PortScanner {
    /// Everything listening on TCP that this user can see, sorted by port.
    public static func scan() -> [PortEntry] {
        let entries = parseListeners(run("/usr/sbin/lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F", "pcLn"]))
        guard !entries.isEmpty else { return [] }

        // Every process, once: the parents are needed to find out where each server was started from.
        var table = ProcessTable.parse(run("/bin/ps", ["-axww", "-o", "pid=,ppid=,tty=,etime=,comm="]))
        // And once more for the command lines, which cannot share a line with the path: both contain spaces.
        table = ProcessTable.addDetails(run("/bin/ps", ["-axww", "-o", "pid=,rss=,args="]), to: table)

        // The folder of each listener, and of whatever started it, in case that ran somewhere else.
        var pids = Set(entries.map(\.pid))
        for pid in pids {
            if let launcher = ProcessTable.launcher(of: pid, in: table) { pids.insert(launcher.pid) }
        }
        let directories = parseDirectories(run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-F", "pn", "-p", pids.map(String.init).joined(separator: ",")]))
        return Containers.resolve(attach(table, directories: directories, to: entries))
    }

    /// The processes listening on one port right now. Cheap enough to ask several times a second.
    public static func holders(of port: Int) -> Set<Int32> {
        let text = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "p"])
        return Set(text.split(whereSeparator: \.isNewline).compactMap { $0.first == "p" ? Int32($0.dropFirst()) : nil })
    }

    /// Fills in what the process table and the working directories know about each listener.
    public static func attach(_ table: [Int32: ProcessRecord], directories: [Int32: String], to entries: [PortEntry]) -> [PortEntry] {
        var origins: [Int32: Origin] = [:]
        var walked: Set<Int32> = []
        return entries.map { entry in
            var entry = entry
            let record = table[entry.pid]
            entry.directory = directories[entry.pid]
            entry.executable = record?.executable
            entry.tty = record?.tty
            entry.uptime = record?.elapsed
            entry.command = record?.command
            entry.memory = record?.memory
            entry.runtime = ContainerRuntime.detect(executable: entry.executable, process: entry.process, command: entry.command)
            if let launcher = ProcessTable.launcher(of: entry.pid, in: table) {
                entry.launchCommand = launcher.command
                entry.launchDirectory = directories[launcher.pid]
            }
            // A process with several ports is only walked once.
            if walked.insert(entry.pid).inserted { origins[entry.pid] = ProcessTable.origin(of: entry.pid, in: table) }
            entry.origin = origins[entry.pid]
            return entry
        }
    }

    /// Reads `lsof -F pcLn` output: one `p` block per process, with an `n` line per listening socket.
    public static func parseListeners(_ text: String) -> [PortEntry] {
        var found: [String: PortEntry] = [:]
        var pid: Int32?
        var name = ""
        var user = ""

        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                name = ""
                user = ""
            case "c":
                name = value
            case "L":
                user = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let key = "\(pid):\(port)"
                var entry = found[key] ?? PortEntry(port: port, pid: pid, process: name, user: user)
                // The same port usually shows up twice, once for IPv4 and once for IPv6.
                if !entry.hosts.contains(host) { entry.hosts.append(host) }
                found[key] = entry
            default:
                break
            }
        }
        return found.values
            .map { entry in
                var sorted = entry
                sorted.hosts.sort()
                return sorted
            }
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Reads `lsof -d cwd -F pn` output into a working directory per process.
    public static func parseDirectories(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            if field == "p" {
                pid = Int32(value)
            } else if field == "n", let pid {
                result[pid] = value
            }
        }
        return result
    }

    /// Reads `ps -o pid=,comm=` output into an executable path per process. Paths may contain spaces.
    public static func parseProcesses(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            let path = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { result[pid] = path }
        }
        return result
    }

    static func run(_ path: String, _ arguments: [String]) -> String {
        Subprocess.run(path, arguments).output
    }
}

enum Subprocess {
    /// Runs a tool and collects what it prints. With a timeout, a tool that hangs is ended rather than waited for.
    /// The status is nil when it could not be started or had to be ended.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval? = nil) -> (status: Int32?, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (nil, "")
        }
        var timedOut = false
        var watchdog: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                timedOut = true
                process.terminate()
            }
            watchdog = work
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        }
        // Read before waiting, or a full pipe would block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()
        return (timedOut ? nil : process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public enum ProcessControl {
    /// Asks a process to quit (SIGTERM), or stops it outright (SIGKILL) when forced. False if the signal could not be sent.
    @discardableResult
    public static func stop(_ pid: Int32, force: Bool = false) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    public static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
