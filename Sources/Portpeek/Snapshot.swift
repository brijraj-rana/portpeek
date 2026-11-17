import AppKit
import PortpeekCore
import SwiftUI

/// Development aid: renders the panel to PNGs with made-up ports, so README images never show a real machine.
@MainActor
enum Snapshot {
    static func render(to directory: String, scale: CGFloat) {
        let sample = [
            PortEntry(port: 3000, pid: 62645, process: "node", hosts: ["*"], executable: "/opt/homebrew/bin/node", directory: "/code/portfolio"),
            PortEntry(port: 5173, pid: 48112, process: "node", hosts: ["127.0.0.1", "::1"], executable: "/opt/homebrew/bin/node", directory: "/code/dashboard"),
            PortEntry(port: 5432, pid: 1341, process: "postgres", hosts: ["127.0.0.1", "::1"], executable: "/opt/homebrew/bin/postgres", directory: "/opt/homebrew/var/postgresql@17"),
            PortEntry(port: 6379, pid: 1334, process: "redis-server", hosts: ["127.0.0.1", "::1"], executable: "/opt/homebrew/bin/redis-server", directory: "/opt/homebrew/var/db/redis"),
            PortEntry(port: 8000, pid: 51907, process: "python3.13", hosts: ["*"], executable: "/opt/homebrew/bin/python3.13", directory: "/code/api"),
            PortEntry(port: 7000, pid: 1252, process: "ControlCenter", hosts: ["*"], executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", directory: "/"),
            PortEntry(port: 59679, pid: 957, process: "rapportd", hosts: ["*"], executable: "/usr/libexec/rapportd", directory: "/"),
        ]

        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let shots: [(String, [PortEntry], Set<Int32>, Bool)] = [
            ("open", sample, [], false),
            ("stubborn", Array(sample.prefix(3)), [48112], false),
            ("empty", Array(sample.suffix(2)), [], false),
        ]
        for (name, entries, stubborn, hint) in shots {
            let model = PortsModel()
            model.showBackground = false
            model.entries = entries
            model.stubborn = stubborn
            model.loaded = true

            let menuBar: CGFloat = 32
            let height = Metrics.height(rows: model.visible.count, hint: hint)
            let view = PanelView(model: model, hint: hint, onMenu: {})
                .environment(\.isSnapshot, true)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .padding(.top, menuBar + Metrics.inset)
                .padding(.trailing, Metrics.inset)
                .frame(width: Metrics.width + 150, height: menuBar + height + 60, alignment: .topTrailing)
                .background(alignment: .top) {
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.56), Color(red: 0.62, green: 0.56, blue: 0.66)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Color.white.opacity(0.22).frame(height: menuBar)
                    }
                }
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            if let cg = renderer.cgImage,
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
        exit(0)
    }
}
