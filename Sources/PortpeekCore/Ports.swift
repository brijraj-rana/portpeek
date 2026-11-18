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

    public var id: String { "\(pid):\(port)" }

    public init(port: Int, pid: Int32, process: String, user: String = "", hosts: [String] = [],
                executable: String? = nil, directory: String? = nil,
                origin: Origin? = nil, tty: String? = nil, uptime: TimeInterval? = nil) {
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
    }

    /// The folder the process was started in, which for a dev server is the project.
    public var project: String? {
        guard let directory, directory != "/", directory != NSHomeDirectory() else { return nil }
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
        guard let executable else { return nil }
        for component in executable.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return nil
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

    /// What to call it in a list.
    public var displayName: String {
        appName ?? process
    }

    /// Not something you started on purpose: system services, anything on a random high port,
    /// and app helpers that only listen on loopback to talk to themselves.
    public var isBackground: Bool {
        isSystem || port >= 49152 || (appName != nil && isLocalOnly)
    }

    /// True when only this Mac can reach it.
    public var isLocalOnly: Bool {
        !hosts.isEmpty && hosts.allSatisfy { $0 == "127.0.0.1" || $0 == "::1" || $0 == "localhost" }
    }

    /// Databases and caches speak their own protocols; a browser has nothing to show for them.
    public var servesHTTP: Bool {
        !Self.nonHTTPPorts.contains(port)
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

        let pids = Set(entries.map(\.pid)).map(String.init).joined(separator: ",")
        let directories = parseDirectories(run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-F", "pn", "-p", pids]))
        // Every process, once: the parents are needed to find out where each server was started from.
        let table = ProcessTable.parse(run("/bin/ps", ["-axww", "-o", "pid=,ppid=,tty=,etime=,comm="]))
        return attach(table, directories: directories, to: entries)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        // Read before waiting, or a full pipe would block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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
