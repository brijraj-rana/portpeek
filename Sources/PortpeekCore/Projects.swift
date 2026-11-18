import Darwin
import Foundation

/// Two or more ports served from the same folder: a dev server and its database, say.
public struct ProjectGroup: Identifiable, Equatable, Sendable {
    public var directory: String
    public var entries: [PortEntry]

    public var id: String { directory }
    public var name: String { (directory as NSString).lastPathComponent }

    public init(directory: String, entries: [PortEntry]) {
        self.directory = directory
        self.entries = entries
    }
}

/// What the list shows: a port on its own, or a project with its ports under one heading.
public enum PortSection: Identifiable, Equatable, Sendable {
    case row(PortEntry)
    case project(ProjectGroup)

    public var id: String {
        switch self {
        case .row(let entry): return entry.id
        case .project(let group): return "project:" + group.id
        }
    }

    public var entries: [PortEntry] {
        switch self {
        case .row(let entry): return [entry]
        case .project(let group): return group.entries
        }
    }
}

public enum Projects {
    /// Only something you started in a project folder can belong to a project.
    /// System services, apps and their helpers never do, wherever they happen to be running:
    /// the folder an app works in is its own business, not a project.
    public static func belongsToProject(_ entry: PortEntry) -> Bool {
        entry.project != nil && !entry.isSystem && !entry.isBackground && entry.appName == nil
    }

    /// Groups entries that share a folder when there are at least two of them, keeping the order they came in.
    /// A group sits where its first port would have been.
    public static func sections(_ entries: [PortEntry]) -> [PortSection] {
        var members: [String: [PortEntry]] = [:]
        for entry in entries where belongsToProject(entry) {
            if let directory = entry.directory { members[directory, default: []].append(entry) }
        }

        var sections: [PortSection] = []
        var placed: Set<String> = []
        for entry in entries {
            if belongsToProject(entry), let directory = entry.directory, let group = members[directory], group.count >= 2 {
                if placed.insert(directory).inserted {
                    sections.append(.project(ProjectGroup(directory: directory, entries: group)))
                }
            } else {
                sections.append(.row(entry))
            }
        }
        return sections
    }

    /// The processes "Stop all" may signal for a project folder, worked out from the latest scan
    /// rather than from whatever the heading was drawn with.
    ///
    /// The rule: the process must be running in exactly that folder, must not be a system service,
    /// an app or an app helper, and must not be launchd or Portpeek itself. Each process appears once.
    public static func stopTargets(directory: String, in entries: [PortEntry], own: Int32 = getpid()) -> [Int32] {
        var targets: [Int32] = []
        for entry in entries where entry.directory == directory && belongsToProject(entry) {
            guard entry.pid > 1, entry.pid != own, !targets.contains(entry.pid) else { continue }
            targets.append(entry.pid)
        }
        return targets
    }
}
