import Foundation

/// The things that run containers on a Mac and listen on the host for them.
public enum ContainerRuntime: String, Equatable, Sendable, CaseIterable {
    case docker, orbstack, colima, lima, podman

    public var name: String {
        switch self {
        case .docker: return "Docker"
        case .orbstack: return "OrbStack"
        case .colima: return "Colima"
        case .lima: return "Lima"
        case .podman: return "Podman"
        }
    }

    /// The tool that can list this runtime's containers. Lima on its own may be running anything, so it has none.
    public var cli: String? {
        switch self {
        case .docker, .orbstack, .colima: return "docker"
        case .podman: return "podman"
        case .lima: return nil
        }
    }

    /// Whether a listening process is a runtime forwarding a port into a container or its virtual machine.
    public static func detect(executable: String?, process: String, command: String?) -> ContainerRuntime? {
        let path = executable ?? process
        let name = (path as NSString).lastPathComponent.lowercased()
        let command = command ?? ""

        // Docker Desktop forwards from its backend; older versions used vpnkit. The window is "Docker Desktop" and is not one.
        if name.hasPrefix("com.docker.") || name == "vpnkit-bridge" { return .docker }
        if path.contains("/OrbStack.app/") { return .orbstack }
        // podman machine forwards through gvproxy.
        if name == "gvproxy" { return .podman }
        // Lima, and Colima on top of it, forward from the host agent or over an ssh connection kept in Lima's folder.
        if name == "limactl" || (name == "ssh" && (command.contains("/.lima/") || command.contains("/_lima/"))) {
            return (path + command).lowercased().contains("colima") ? .colima : .lima
        }
        return nil
    }
}

/// The container behind a forwarded port.
public struct ContainerInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    /// As the runtime puts it: "Up 2 hours".
    public var status: String?
    /// The port inside the container that the host port leads to.
    public var containerPort: Int?
    public var runtime: ContainerRuntime

    public init(id: String, name: String, image: String, status: String? = nil, containerPort: Int? = nil, runtime: ContainerRuntime) {
        self.id = id
        self.name = name
        self.image = image
        self.status = status
        self.containerPort = containerPort
        self.runtime = runtime
    }
}

/// One line of `docker ps`: a container and the host ports it published.
public struct PublishedContainer: Equatable, Sendable {
    public struct Mapping: Equatable, Sendable {
        /// Host ports. One port is a range of one.
        public var host: ClosedRange<Int>
        /// The container port the first host port leads to.
        public var container: Int

        public init(host: ClosedRange<Int>, container: Int) {
            self.host = host
            self.container = container
        }
    }

    public var id: String
    public var name: String
    public var image: String
    public var status: String?
    public var mappings: [Mapping]

    /// The container port a host port leads to, or nil when this container did not publish it.
    public func containerPort(for port: Int) -> Int? {
        guard let mapping = mappings.first(where: { $0.host.contains(port) }) else { return nil }
        return mapping.container + (port - mapping.host.lowerBound)
    }
}

public enum Containers {
    /// Asked of `docker ps` and `podman ps` alike. Tabs, because names and images never contain one. Ports come last.
    public static let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

    /// Reads `ps --format` output in the format above.
    public static func parse(_ text: String) -> [PublishedContainer] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            // Old links show up as extra names after a comma; the first is the container's own.
            let name = fields[1].split(separator: ",").first.map(String.init) ?? fields[1]
            let status = fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil
            return PublishedContainer(id: fields[0], name: name, image: fields[2], status: status,
                                      mappings: fields.count > 4 ? parsePorts(fields[4]) : [])
        }
    }

    /// Reads the ports column: "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 9000-9002/tcp".
    /// Only TCP ports published on the host count; a port that is merely exposed has no arrow.
    public static func parsePorts(_ text: String) -> [PublishedContainer.Mapping] {
        var mappings: [PublishedContainer.Mapping] = []
        for part in text.split(separator: ",") {
            let part = part.trimmingCharacters(in: .whitespaces)
            guard let arrow = part.range(of: "->") else { continue }
            let target = part[arrow.upperBound...]
            guard target.hasSuffix("/tcp") || !target.contains("/") else { continue }
            // The host side is "address:port" and the address may itself be full of colons.
            let host = part[..<arrow.lowerBound]
            let hostPorts = host.lastIndex(of: ":").map { host[host.index(after: $0)...] } ?? host
            guard let published = portRange(hostPorts), let inside = portRange(target.split(separator: "/").first ?? "")?.lowerBound else { continue }
            let mapping = PublishedContainer.Mapping(host: published, container: inside)
            if !mappings.contains(mapping) { mappings.append(mapping) }
        }
        return mappings
    }

    /// "8080" or "9000-9002".
    private static func portRange<S: StringProtocol>(_ text: S) -> ClosedRange<Int>? {
        let ends = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...2).contains(ends.count), let first = ends[0], let last = ends[ends.count - 1],
              first > 0, last >= first, last <= 65535 else { return nil }
        return first...last
    }

    /// Names the container behind each forwarded port, given what each tool listed.
    /// A port nothing claims keeps its runtime and no container, and the row says so.
    public static func attach(_ listed: [String: [PublishedContainer]], to entries: [PortEntry]) -> [PortEntry] {
        entries.map { entry in
            guard let runtime = entry.runtime, let cli = runtime.cli, let containers = listed[cli] else { return entry }
            var entry = entry
            for container in containers {
                guard let inside = container.containerPort(for: entry.port) else { continue }
                entry.container = ContainerInfo(id: container.id, name: container.name, image: container.image,
                                                status: container.status, containerPort: inside, runtime: runtime)
                break
            }
            return entry
        }
    }

    /// Where a runtime's tool is installed. An app does not inherit the shell's PATH, so the usual places are tried too.
    public static func locate(_ tool: String, path: String? = ProcessInfo.processInfo.environment["PATH"],
                              home: String = NSHomeDirectory(),
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        var directories = (path ?? "").split(separator: ":").map(String.init)
        directories += ["/usr/local/bin", "/opt/homebrew/bin", home + "/.docker/bin", home + "/.orbstack/bin",
                        "/Applications/Docker.app/Contents/Resources/bin", "/opt/podman/bin", home + "/.rd/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let candidate = directory + "/" + tool
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Asks each runtime that is forwarding a port which containers it is running. Does nothing, and starts nothing,
    /// unless such a listener is in the list and its tool is installed.
    static func resolve(_ entries: [PortEntry]) -> [PortEntry] {
        let tools = Set(entries.compactMap { $0.runtime?.cli })
        guard !tools.isEmpty else { return entries }
        var listed: [String: [PublishedContainer]] = [:]
        for tool in tools {
            guard let path = locate(tool) else { continue }
            let result = Subprocess.run(path, ["ps", "--no-trunc", "--format", format], timeout: 2)
            if result.status == 0 { listed[tool] = parse(result.output) }
        }
        return attach(listed, to: entries)
    }

    /// The arguments that stop one container: `stop` lets it shut down, `kill` does not wait.
    /// Nil for an id that does not look like one.
    public static func stopArguments(id: String, force: Bool) -> [String]? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !id.isEmpty, !id.hasPrefix("-"), id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return [force ? "kill" : "stop", id]
    }

    /// Stops one container with its runtime's own tool. The runtime itself is never signalled. Blocks until the tool returns.
    @discardableResult
    public static func stop(_ container: ContainerInfo, force: Bool = false) -> Bool {
        guard let tool = container.runtime.cli, let path = locate(tool),
              let arguments = stopArguments(id: container.id, force: force) else { return false }
        return Subprocess.run(path, arguments, timeout: 30).status == 0
    }
}
