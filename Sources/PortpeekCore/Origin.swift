import Foundation

/// One line of the process table: enough to walk from a server up to the app it was started from.
public struct ProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    /// The controlling terminal ("ttys003"), when there is one.
    public var tty: String?
    /// Seconds since the process started.
    public var elapsed: TimeInterval?
    public var executable: String

    public init(pid: Int32, parent: Int32, tty: String? = nil, elapsed: TimeInterval? = nil, executable: String) {
        self.pid = pid
        self.parent = parent
        self.tty = tty
        self.elapsed = elapsed
        self.executable = executable
    }
}

/// The app a server was started from: a terminal, an editor, Docker, or nothing that is still around.
public struct Origin: Equatable, Sendable {
    public enum Kind: Sendable {
        case terminal, editor, containers, app
        /// tmux and friends: the session outlives the terminal window, so there is no app to point at.
        case multiplexer
        /// Its parent is launchd: either a service launchd runs, or a server whose terminal has gone.
        /// The two look the same from here, so the row says what is true of both.
        case detached
    }

    public var name: String
    public var kind: Kind
    /// The outermost process of that app, which is the one that can be brought forward.
    public var pid: Int32?
    public var bundleIdentifier: String?
    /// True when the listening process is part of the app itself, so naming the app again would say nothing.
    public var isOwnApp: Bool

    public init(name: String, kind: Kind, pid: Int32? = nil, bundleIdentifier: String? = nil, isOwnApp: Bool = false) {
        self.name = name
        self.kind = kind
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.isOwnApp = isOwnApp
    }

    public static let detached = Origin(name: "launchd", kind: .detached)

    /// How a row says it.
    public var label: String {
        kind == .detached ? "detached" : "from \(name)"
    }

    /// Whether there is an app to bring forward.
    public var canActivate: Bool {
        kind != .detached && kind != .multiplexer
    }

    /// Terminal and iTerm2 can be asked for the exact tab; the others only come forward as a whole.
    public var terminalScripting: TerminalFocus.App? {
        switch bundleIdentifier {
        case "com.apple.Terminal": return .terminal
        case "com.googlecode.iterm2": return .iTerm
        default: return nil
        }
    }
}

public enum ProcessTable {
    /// Reads `ps -ax -o pid=,ppid=,tty=,etime=,comm=` output. The path comes last because it may contain spaces.
    public static func parse(_ text: String) -> [Int32: ProcessRecord] {
        var result: [Int32: ProcessRecord] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            let path = fields[4].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            result[pid] = ProcessRecord(pid: pid, parent: parent,
                                        tty: fields[2].hasPrefix("tty") ? String(fields[2]) : nil,
                                        elapsed: parseElapsed(fields[3]),
                                        executable: path)
        }
        return result
    }

    /// Reads the `etime` column, `[[dd-]hh:]mm:ss`, into seconds.
    public static func parseElapsed<S: StringProtocol>(_ text: S) -> TimeInterval? {
        var days = 0
        var clock = Substring(text)
        if let dash = clock.firstIndex(of: "-") {
            guard let value = Int(clock[..<dash]), value >= 0 else { return nil }
            days = value
            clock = clock[clock.index(after: dash)...]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return TimeInterval(days * 86_400 + seconds)
    }

    /// Walks up from a process through its parents until it reaches an app we can name, or launchd.
    /// Nil when the chain breaks before either, which happens when a parent has just exited.
    public static func origin(of pid: Int32, in table: [Int32: ProcessRecord]) -> Origin? {
        var current = pid
        var seen: Set<Int32> = []
        while seen.insert(current).inserted, seen.count <= 64 {
            if current == 1 { return .detached }
            guard let record = table[current] else { return nil }
            if let host = Host.match(record.executable) {
                // A helper process cannot be brought forward; the app at the top of its own bundle can.
                var top = record
                var climbed: Set<Int32> = [record.pid]
                while let bundle = Host.bundleName(top.executable), top.parent > 1, let above = table[top.parent],
                      Host.bundleName(above.executable) == bundle, climbed.insert(above.pid).inserted {
                    top = above
                }
                return Origin(name: host.name, kind: host.kind, pid: host.kind == .multiplexer ? nil : top.pid,
                              bundleIdentifier: host.bundleIdentifier, isOwnApp: record.pid == pid)
            }
            current = record.parent
        }
        return nil
    }
}

/// The apps a dev server is usually started from.
public enum Host {
    struct Known {
        var name: String
        var kind: Origin.Kind
        var bundleIdentifier: String?
        /// App bundle names, lowercased, without ".app".
        var bundles: [String] = []
        /// Executable names for copies that do not live in an app bundle, lowercased. A trailing "*" matches a prefix.
        var binaries: [String] = []
    }

    static let known: [Known] = [
        Known(name: "Terminal", kind: .terminal, bundleIdentifier: "com.apple.Terminal", bundles: ["terminal"]),
        // iTerm2 runs its shells under a small server process that is not inside the app bundle.
        Known(name: "iTerm2", kind: .terminal, bundleIdentifier: "com.googlecode.iterm2", bundles: ["iterm", "iterm2"], binaries: ["itermserver*"]),
        Known(name: "Warp", kind: .terminal, bundleIdentifier: "dev.warp.Warp-Stable", bundles: ["warp", "warppreview"]),
        Known(name: "Ghostty", kind: .terminal, bundleIdentifier: "com.mitchellh.ghostty", bundles: ["ghostty"], binaries: ["ghostty"]),
        Known(name: "kitty", kind: .terminal, bundleIdentifier: "net.kovidgoyal.kitty", bundles: ["kitty"], binaries: ["kitty"]),
        Known(name: "Alacritty", kind: .terminal, bundleIdentifier: "org.alacritty", bundles: ["alacritty"], binaries: ["alacritty"]),
        Known(name: "WezTerm", kind: .terminal, bundleIdentifier: "com.github.wez.wezterm", bundles: ["wezterm"], binaries: ["wezterm-gui", "wezterm-mux-server"]),
        Known(name: "VS Code", kind: .editor, bundleIdentifier: "com.microsoft.VSCode", bundles: ["visual studio code", "code"]),
        Known(name: "VS Code", kind: .editor, bundles: ["visual studio code - insiders", "code - insiders"]),
        Known(name: "Cursor", kind: .editor, bundleIdentifier: "com.todesktop.230313mzl4w4u92", bundles: ["cursor"]),
        Known(name: "Zed", kind: .editor, bundleIdentifier: "dev.zed.Zed", bundles: ["zed"]),
        Known(name: "Zed", kind: .editor, bundles: ["zed preview"]),
        Known(name: "Xcode", kind: .editor, bundleIdentifier: "com.apple.dt.Xcode", bundles: ["xcode"]),
        Known(name: "Xcode", kind: .editor, bundles: ["xcode-beta"]),
        Known(name: "Docker", kind: .containers, bundleIdentifier: "com.docker.docker", bundles: ["docker", "docker desktop"]),
        Known(name: "tmux", kind: .multiplexer, binaries: ["tmux"]),
        Known(name: "screen", kind: .multiplexer, binaries: ["screen"]),
        Known(name: "Zellij", kind: .multiplexer, binaries: ["zellij"]),
    ]

    /// JetBrains IDEs are named after the product, with an edition or a version after it ("PyCharm CE", "IntelliJ IDEA Ultimate").
    static let jetBrains = ["IntelliJ IDEA", "WebStorm", "PyCharm", "GoLand", "RubyMine", "PhpStorm", "CLion", "Rider",
                            "DataGrip", "RustRover", "DataSpell", "Android Studio", "Fleet"]

    /// The names a row can show, for the README and the tests.
    public static var recognised: [String] {
        var names: [String] = []
        for name in known.map(\.name) + jetBrains where !names.contains(name) { names.append(name) }
        return names
    }

    /// The outermost app bundle an executable lives in.
    static func bundleName(_ executable: String) -> String? {
        for component in executable.split(separator: "/") where component.hasSuffix(".app") && component.count > 4 {
            return String(component.dropLast(4))
        }
        return nil
    }

    static func match(_ executable: String) -> (name: String, kind: Origin.Kind, bundleIdentifier: String?)? {
        if let bundle = bundleName(executable) {
            let key = bundle.lowercased()
            if let host = known.first(where: { $0.bundles.contains(key) }) {
                return (host.name, host.kind, host.bundleIdentifier)
            }
            if let product = jetBrains.first(where: { key == $0.lowercased() || key.hasPrefix($0.lowercased() + " ") }) {
                return (product, .editor, nil)
            }
            // Parts of macOS that happen to be apps are not where anyone starts a server from.
            if executable.hasPrefix("/System/") && key != "terminal" { return nil }
            // Any other app is still a better answer than nothing: a terminal or an editor this list has not heard of.
            return (bundle, .app, nil)
        }
        let binary = (executable as NSString).lastPathComponent.lowercased()
        for host in known {
            for pattern in host.binaries {
                if pattern.hasSuffix("*") ? binary.hasPrefix(pattern.dropLast()) : binary == pattern {
                    return (host.name, host.kind, host.bundleIdentifier)
                }
            }
        }
        return nil
    }
}

/// AppleScript that brings forward the Terminal or iTerm2 tab a process is running in.
public enum TerminalFocus {
    public enum App: Sendable {
        case terminal, iTerm
    }

    /// The device path for a `ps` tty name, or nil for anything that does not look like one.
    /// The result goes into a script, so nothing but letters and digits gets through.
    public static func device(for tty: String?) -> String? {
        guard let tty, tty.hasPrefix("tty"), tty.count <= 16,
              tty.unicodeScalars.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }) else { return nil }
        return "/dev/" + tty
    }

    public static func script(for app: App, tty: String?) -> String? {
        guard let device = device(for: tty) else { return nil }
        switch app {
        case .terminal:
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(device)" then
                            set selected tab of w to t
                            set index of w to 1
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case .iTerm:
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(device)" then
                                select w
                                select t
                                select s
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        }
    }
}

public enum Uptime {
    /// "Up 3 hours". Coarse on purpose: nobody needs the seconds.
    public static func phrase(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        func count(_ value: Int, _ unit: String) -> String { "Up \(value) \(unit)\(value == 1 ? "" : "s")" }
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "Up less than a minute" }
        if minutes < 60 { return count(minutes, "minute") }
        let hours = minutes / 60
        if hours < 48 { return count(hours, "hour") }
        return count(hours / 24, "day")
    }
}
