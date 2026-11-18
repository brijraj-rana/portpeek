import Darwin
import Foundation

public enum PortpeekVersion {
    /// Kept in step with CFBundleShortVersionString in Resources/Info.plist; build-app.sh refuses to build if they differ.
    public static let current = "0.3.0"
}

/// Everything the `portpeek` command says, kept here so it can be tested without running it.
public enum CLI {
    public enum Command: Equatable, Sendable {
        case list(all: Bool, json: Bool)
        case show(port: Int, json: Bool)
        case kill(port: Int, force: Bool)
        case help
        case version
    }

    public struct UsageError: Error, Equatable {
        public var message: String
    }

    /// What the command exits with, so a script can tell the outcomes apart.
    public enum ExitCode: Int32, Sendable {
        case ok = 0
        /// Nothing is listening on the port that was asked about.
        case notListening = 1
        case usage = 2
        /// Asked to quit, and the port is still taken.
        case stillListening = 3
        /// Nothing was attempted, or nothing was allowed.
        case refused = 4
    }

    public static let help = """
    portpeek                   list listening ports
    portpeek <port>            say what holds a port
    portpeek kill <port>       ask it to quit, and say whether the port was freed

      --all, -a        include system services and app helpers in the list
      --json           print JSON, for scripts (list and <port>)
      --force, -f      with kill: if it is still there after two seconds, stop it outright
      --version, -v
      --help, -h

    Exit codes: 0 done, 1 nothing is listening on that port, 2 bad usage,
    3 the port is still taken, 4 refused (not permitted, or a container runtime).
    """

    public static func parse(_ arguments: [String]) throws -> Command {
        var all = false, json = false, force = false
        var words: [String] = []
        for argument in arguments {
            switch argument {
            case "--help", "-h", "help": return .help
            case "--version", "-v": return .version
            case "--all", "-a": all = true
            case "--json": json = true
            case "--force", "-f": force = true
            default:
                if argument.hasPrefix("-") { throw UsageError(message: "Unknown option \(argument).") }
                words.append(argument)
            }
        }

        func port(_ text: String) throws -> Int {
            // ":3000" and "localhost:3000" are what people have on the clipboard.
            let digits = text.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? text
            guard let value = Int(digits), (1...65535).contains(value) else {
                throw UsageError(message: "\(text) is not a port. Ports run from 1 to 65535.")
            }
            return value
        }

        if words.first == "kill" {
            guard words.count == 2 else { throw UsageError(message: "kill takes one port: portpeek kill 3000") }
            if json { throw UsageError(message: "--json does not go with kill.") }
            return .kill(port: try port(words[1]), force: force)
        }
        if force { throw UsageError(message: "--force only goes with kill.") }
        switch words.count {
        case 0: return .list(all: all, json: json)
        case 1: return .show(port: try port(words[0]), json: json)
        default: throw UsageError(message: "Too many arguments.")
        }
    }

    // MARK: Table

    /// The process column: the container and its image when there is one, and an honest "container" when there is not.
    static func name(_ entry: PortEntry) -> String {
        if let container = entry.container { return "\(container.name) (\(container.image))" }
        if entry.runtime != nil { return "container" }
        return entry.displayName
    }

    static func origin(_ entry: PortEntry) -> String? {
        if let runtime = entry.runtime { return runtime.name }
        guard let origin = entry.startedFrom else { return nil }
        return origin.kind == .detached ? "detached" : origin.name
    }

    /// Port, process, project, origin and pid in columns padded to the widest value. The numbers sit to the right.
    public static func table(_ entries: [PortEntry]) -> String {
        guard !entries.isEmpty else { return "Nothing is listening." }
        var rows = [["PORT", "PROCESS", "PROJECT", "ORIGIN", "PID"]]
        for entry in entries {
            rows.append([String(entry.port), name(entry), entry.project ?? "-", origin(entry) ?? "-", String(entry.pid)])
        }
        let widths = (0..<5).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            var line = ""
            for column in 0..<5 {
                let gap = String(repeating: " ", count: widths[column] - row[column].count)
                let cell = column == 0 || column == 4 ? gap + row[column] : row[column] + gap
                line += column == 0 ? cell : "  " + cell
            }
            return line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    /// Who holds one port, with what the panel's expanded row knows.
    public static func describe(_ entries: [PortEntry], port: Int) -> String {
        let holders = entries.filter { $0.port == port }
        guard !holders.isEmpty else { return "Nothing is listening on port \(port)." }
        return holders.map { entry in
            var lines: [String]
            var facts: [(String, String?)] = []
            if let container = entry.container {
                lines = ["Port \(port) is held by container \(container.name), forwarded by \(container.runtime.name) (pid \(entry.pid))"]
                facts.append(("image", container.image))
                facts.append(("container", container.id.count > 12 ? String(container.id.prefix(12)) : container.id))
                facts.append(("status", container.status))
                facts.append(("inside", container.containerPort.map { "port \($0)" }))
            } else if let runtime = entry.runtime {
                lines = ["Port \(port) is held by a container, forwarded by \(runtime.name) (pid \(entry.pid)). The container is not known."]
            } else {
                lines = ["Port \(port) is held by \(entry.displayName) (pid \(entry.pid))"]
                if entry.appName != nil, entry.process != entry.displayName { facts.append(("process", entry.process)) }
                facts.append(("project", entry.project))
                facts.append(("folder", entry.directory))
                facts.append(("origin", origin(entry)))
                facts.append(("command", entry.command))
                facts.append(("running", Uptime.duration(entry.uptime)))
                facts.append(("memory", Memory.format(entry.memory)))
                facts.append(("restart", entry.restartCommand))
            }
            facts.append(("address", entry.link))
            for (label, value) in facts {
                guard let value else { continue }
                lines.append("  " + label + String(repeating: " ", count: 11 - label.count) + value)
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: JSON

    struct Record: Encodable {
        struct Container: Encodable {
            var id: String
            var name: String
            var image: String
            var status: String?
            var containerPort: Int?
        }

        var port: Int
        var pid: Int32
        var name: String
        var process: String
        var project: String?
        var directory: String?
        var origin: String?
        var command: String?
        var restartCommand: String?
        var uptimeSeconds: Int?
        var memoryBytes: Int64?
        var hosts: [String]
        var address: String
        var background: Bool
        var runtime: String?
        var container: Container?
    }

    /// An array with one object per port and process. Keys are sorted; a fact that is not known is left out.
    public static func json(_ entries: [PortEntry]) -> String {
        let records = entries.map { entry -> Record in
            // For a container, the folder, command, memory and uptime on hand are the runtime's, and would mislead.
            let own = entry.runtime == nil
            return Record(port: entry.port, pid: entry.pid, name: entry.displayName, process: entry.process, project: entry.project,
                   directory: own ? entry.directory : nil, origin: origin(entry), command: own ? entry.command : nil,
                   restartCommand: entry.restartCommand, uptimeSeconds: own ? entry.uptime.map { Int($0) } : nil,
                   memoryBytes: own ? entry.memory : nil, hosts: entry.hosts, address: entry.link,
                   background: entry.isBackground, runtime: entry.runtime?.rawValue,
                   container: entry.container.map {
                       Record.Container(id: $0.id, name: $0.name, image: $0.image, status: $0.status, containerPort: $0.containerPort)
                   })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(records) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `portpeek kill`: ask whatever holds a port to quit, then look again to see whether it worked.
public enum PortKiller {
    public enum Outcome: Equatable, Sendable {
        case nothingListening
        /// The port is free. `forced` is true when asking was not enough.
        case freed([PortEntry], forced: Bool)
        case stillHeld([PortEntry], forced: Bool)
        /// The process went, and something else took the port straight away: a service manager starting it again.
        case retaken([PortEntry], by: [Int32])
        /// A container runtime with no known container behind the port. Nothing was signalled.
        case runtimeOnly(PortEntry)
        case notPermitted([PortEntry])
        case containerStopped(ContainerInfo)
        case containerFailed(ContainerInfo)
    }

    /// - Parameters:
    ///   - entries: a fresh scan.
    ///   - patience: how long to wait for the port to come free after each signal.
    ///   - holders: who is listening on a port now; replaced in tests.
    public static func free(port: Int, force: Bool, entries: [PortEntry] = PortScanner.scan(), patience: TimeInterval = 2,
                            own: Int32 = getpid(), holders: (Int) -> Set<Int32> = PortScanner.holders) -> Outcome {
        let found = entries.filter { $0.port == port && $0.pid != own }
        guard !found.isEmpty else { return .nothingListening }

        // Containers first: the process holding the port is the runtime, and it is never the thing to signal.
        if let forwarded = found.first(where: { $0.runtime != nil }) {
            guard case .container(let container) = forwarded.stopAction else { return .runtimeOnly(forwarded) }
            guard Containers.stop(container, force: force) else { return .containerFailed(container) }
            return wait(patience, until: { holders(port).isEmpty }) ? .containerStopped(container) : .containerFailed(container)
        }

        var pids: [Int32] = []
        for entry in found where !pids.contains(entry.pid) { pids.append(entry.pid) }
        let signalled = pids.filter { ProcessControl.stop($0) }
        guard !signalled.isEmpty else { return .notPermitted(found) }

        func remaining() -> [PortEntry] {
            let now = holders(port)
            return found.filter { now.contains($0.pid) }
        }
        var forced = false
        if !wait(patience, until: { remaining().isEmpty }), force {
            forced = true
            for entry in remaining() { ProcessControl.stop(entry.pid, force: true) }
            _ = wait(patience, until: { remaining().isEmpty })
        }
        let left = remaining()
        if !left.isEmpty { return .stillHeld(left, forced: forced) }

        // A service manager brings its service back within moments.
        Thread.sleep(forTimeInterval: 0.3)
        let newcomers = holders(port).subtracting(pids)
        return newcomers.isEmpty ? .freed(found, forced: forced) : .retaken(found, by: newcomers.sorted())
    }

    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if done() { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func names(_ entries: [PortEntry]) -> String {
        var seen: [Int32] = []
        var parts: [String] = []
        for entry in entries where !seen.contains(entry.pid) {
            seen.append(entry.pid)
            parts.append("\(entry.displayName) (pid \(entry.pid))")
        }
        return parts.joined(separator: " and ")
    }

    public static func message(_ outcome: Outcome, port: Int) -> String {
        switch outcome {
        case .nothingListening:
            return "Nothing is listening on port \(port)."
        case .freed(let entries, let forced):
            return "Port \(port) is free. \(names(entries)) \(forced ? "ignored the request and was stopped outright" : "quit")."
        case .stillHeld(let entries, let forced):
            return forced
                ? "Port \(port) is still held by \(names(entries)), even after being forced."
                : "Port \(port) is still held by \(names(entries)). It ignored the request. Run it again with --force."
        case .retaken(let entries, let pids):
            return "\(names(entries)) quit, but port \(port) was taken again by pid \(pids.map(String.init).joined(separator: ", ")). "
                + "Something restarts it, such as brew services or launchd."
        case .runtimeOnly(let entry):
            let runtime = entry.runtime?.name ?? "a container runtime"
            return "Port \(port) is forwarded by \(runtime) and the container is not known. "
                + "Killing \(runtime) would stop every container, so nothing was done."
        case .notPermitted(let entries):
            return "Could not signal \(names(entries)). It may belong to another user. Try with sudo."
        case .containerStopped(let container):
            return "Port \(port) is free. Container \(container.name) was stopped. \(container.runtime.name) was left running."
        case .containerFailed(let container):
            return "Could not stop container \(container.name). Port \(port) is still taken."
        }
    }

    public static func exitCode(_ outcome: Outcome) -> CLI.ExitCode {
        switch outcome {
        case .freed, .containerStopped: return .ok
        case .nothingListening: return .notListening
        case .stillHeld, .retaken, .containerFailed: return .stillListening
        case .runtimeOnly, .notPermitted: return .refused
        }
    }
}
