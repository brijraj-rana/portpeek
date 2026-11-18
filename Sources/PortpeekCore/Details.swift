import Foundation

public enum Memory {
    /// "512 KB", "84 MB", "1.2 GB". Counted in 1024s, the way Activity Monitor does.
    public static func format(_ bytes: Int64?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 { return "\(Int(kilobytes.rounded())) KB" }
        let megabytes = kilobytes / 1024
        if megabytes < 1024 { return short(megabytes) + " MB" }
        return short(megabytes / 1024) + " GB"
    }

    /// One decimal below ten, where it still says something; none above.
    private static func short(_ value: Double) -> String {
        if value >= 9.95 { return String(Int(value.rounded())) }
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}

public enum ShellQuote {
    /// A path as a shell would need it typed: left alone when it is plain, in single quotes otherwise.
    public static func quote(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,=")
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ plain.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What an expanded row shows under the port: one line in a fixed-width face, one line of facts, and things to copy.
public struct PortDetails: Equatable, Sendable {
    public struct Copy: Equatable, Identifiable, Sendable {
        /// What it copies, as one word or two: "Command". The row puts "Copy" in front of the lot.
        public var word: String
        public var text: String
        public var id: String { word }
        /// "Copy command", for where it stands alone.
        public var title: String { "Copy " + word.lowercased() }

        public init(_ word: String, text: String) {
            self.word = word
            self.text = text
        }
    }

    /// The command line, or the image for a container.
    public var headline: String?
    public var facts: String?
    public var copies: [Copy]
}

extension PortEntry {
    public var details: PortDetails {
        let address = PortDetails.Copy("Address", text: link)

        if let container {
            var facts: [String] = []
            if let status = container.status { facts.append(status) }
            if let inside = container.containerPort { facts.append("port \(inside) in the container") }
            return PortDetails(headline: container.image, facts: facts.isEmpty ? nil : facts.joined(separator: " · "),
                               copies: [address, PortDetails.Copy("Name", text: container.name)])
        }
        if let runtime {
            return PortDetails(headline: nil, facts: "Forwarded by \(runtime.name). The container is not known.", copies: [address])
        }

        var facts: [String] = []
        if let up = Uptime.phrase(uptime) { facts.append(up) }
        if let size = Memory.format(memory) { facts.append(size) }
        var copies: [PortDetails.Copy] = []
        if let command { copies.append(PortDetails.Copy("Command", text: command)) }
        copies.append(address)
        if let restartCommand { copies.append(PortDetails.Copy("Restart command", text: restartCommand)) }
        return PortDetails(headline: command, facts: facts.isEmpty ? nil : facts.joined(separator: " · "), copies: copies)
    }
}
