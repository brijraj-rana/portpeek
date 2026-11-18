import AppKit
import PortpeekCore
import SwiftUI

/// Development aid: renders the panel to PNGs with made-up ports, so README images never show a real machine.
@MainActor
enum Snapshot {
    static func render(to directory: String, scale: CGFloat, checks: Bool = false) {
        let cursor = Origin(name: "Cursor", kind: .editor)
        let terminal = Origin(name: "Terminal", kind: .terminal, bundleIdentifier: "com.apple.Terminal")
        let warp = Origin(name: "Warp", kind: .terminal)
        let minute: TimeInterval = 60, hour: TimeInterval = 3600, day: TimeInterval = 86_400
        let megabyte: Int64 = 1_048_576

        let sample = [
            PortEntry(port: 3000, pid: 62645, process: "node", hosts: ["*"], executable: "/opt/homebrew/bin/node", directory: "/code/my-shop",
                      origin: cursor, tty: "ttys004", uptime: 3 * hour,
                      command: "node /code/my-shop/node_modules/.bin/next dev --port 3000", memory: 412 * megabyte,
                      launchCommand: "npm run dev", launchDirectory: "/code/my-shop"),
            PortEntry(port: 3001, pid: 62702, process: "node", hosts: ["*"], executable: "/opt/homebrew/bin/node", directory: "/code/my-shop",
                      origin: cursor, tty: "ttys004", uptime: 3 * hour,
                      command: "node /code/my-shop/node_modules/.bin/storybook dev -p 3001", memory: 268 * megabyte,
                      launchCommand: "npm run storybook", launchDirectory: "/code/my-shop"),
            PortEntry(port: 5173, pid: 48112, process: "node", hosts: ["127.0.0.1", "::1"], executable: "/opt/homebrew/bin/node", directory: "/code/dashboard",
                      origin: terminal, tty: "ttys001", uptime: 12 * minute,
                      command: "node /code/dashboard/node_modules/.bin/vite", memory: 96 * megabyte,
                      launchCommand: "npm run dev", launchDirectory: "/code/dashboard"),
            PortEntry(port: 5432, pid: 1341, process: "postgres", hosts: ["127.0.0.1", "::1"], executable: "/opt/homebrew/bin/postgres", directory: "/opt/homebrew/var/postgresql@17",
                      origin: .detached, uptime: 6 * day),
            PortEntry(port: 8000, pid: 51907, process: "python3.13", hosts: ["*"], executable: "/opt/homebrew/bin/python3.13", directory: "/code/api",
                      origin: warp, tty: "ttys007", uptime: 40 * minute,
                      command: "python3.13 -m uvicorn app.main:app --reload --port 8000", memory: 61 * megabyte),
            PortEntry(port: 7000, pid: 1252, process: "ControlCenter", hosts: ["*"], executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", directory: "/",
                      origin: .detached, uptime: 6 * day),
            PortEntry(port: 59679, pid: 957, process: "rapportd", hosts: ["*"], executable: "/usr/libexec/rapportd", directory: "/",
                      origin: .detached, uptime: 6 * day),
        ]

        // Ports that containers published. The process holding each one is the runtime, not the server.
        let backend = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
        let database = ContainerInfo(id: "3f2a9c1d7b0e", name: "shop-db", image: "postgres:17", status: "Up 2 hours", containerPort: 5432, runtime: .docker)
        let cache = ContainerInfo(id: "8a41c07be2d9", name: "shop-cache", image: "redis:7-alpine", status: "Up 2 hours", containerPort: 6379, runtime: .docker)
        let containers = [
            PortEntry(port: 5433, pid: 2210, process: "com.docker.backend", hosts: ["*"], executable: backend, directory: "/",
                      origin: Origin(name: "Docker", kind: .containers, isOwnApp: true), uptime: 2 * day, runtime: .docker, container: database),
            PortEntry(port: 6379, pid: 2210, process: "com.docker.backend", hosts: ["127.0.0.1"], executable: backend, directory: "/",
                      origin: Origin(name: "Docker", kind: .containers, isOwnApp: true), uptime: 2 * day, runtime: .docker, container: cache),
            PortEntry(port: 8025, pid: 2210, process: "com.docker.backend", hosts: ["*"], executable: backend, directory: "/",
                      origin: Origin(name: "Docker", kind: .containers, isOwnApp: true), uptime: 2 * day, runtime: .docker),
        ]

        // Awkward cases, to check that nothing breaks when names run long.
        let ide = Origin(name: "IntelliJ IDEA", kind: .editor)
        let code = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let crowded = [
            PortEntry(port: 3000, pid: 62645, process: "next-server (v15.1.0)", hosts: ["*"], executable: "/opt/homebrew/bin/node",
                      directory: "/code/acme-storefront-checkout-redesign-2026", origin: ide, tty: "ttys004", uptime: 26 * hour),
            PortEntry(port: 24678, pid: 62645, process: "next-server (v15.1.0)", hosts: ["*"], executable: "/opt/homebrew/bin/node",
                      directory: "/code/acme-storefront-checkout-redesign-2026", origin: ide, tty: "ttys004", uptime: 26 * hour),
            PortEntry(port: 54321, pid: 9310, process: "postgres", hosts: ["*"], executable: "/opt/homebrew/bin/postgres",
                      directory: "/code/acme-storefront-checkout-redesign-2026", origin: Origin(name: "tmux", kind: .multiplexer), uptime: 9 * day),
            PortEntry(port: 5500, pid: 28256, process: "Code Helper (Plugin)", hosts: ["*"], executable: code,
                      directory: "/code/a-folder-with-quite-a-long-name-indeed", origin: Origin(name: "VS Code", kind: .editor, isOwnApp: true), uptime: 2 * hour),
            PortEntry(port: 8080, pid: 733, process: "java", hosts: ["*"], executable: "/usr/bin/java",
                      directory: "/code/billing-service-migration", origin: ide, uptime: 20,
                      command: "/usr/bin/java -Xmx2g -Dspring.profiles.active=local -Dfile.encoding=UTF-8 -classpath /code/billing-service-migration/build/classes/java/main:/code/billing-service-migration/build/resources/main:/code/lib/spring-boot-3.4.0.jar com.acme.billing.Application --server.port=8080",
                      memory: 1400 * megabyte),
            PortEntry(port: 9000, pid: 4410, process: "php-fpm", hosts: ["*"], executable: "/opt/homebrew/sbin/php-fpm", directory: "/code/blog"),
        ]

        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        struct Shot {
            var name: String
            var entries: [PortEntry]
            var stubborn: Set<Int32> = []
            var stopping: Set<Int32> = []
            var expanded: String?
            var hint = false
        }

        // The ones after the first six are for checking the layout and are only written with --checks.
        var shots = [
            Shot(name: "open", entries: Array(sample.prefix(3)) + [containers[0]] + Array(sample[4...])),
            Shot(name: "stubborn", entries: Array(sample[2...4]), stubborn: [48112]),
            Shot(name: "project", entries: Array(sample.prefix(3))),
            Shot(name: "details", entries: Array(sample.prefix(3)) + [sample[4]], expanded: "62645:3000"),
            Shot(name: "container", entries: containers + [sample[4]], expanded: "2210:5433"),
        ]
        if checks {
            shots += [
                Shot(name: "empty", entries: Array(sample.suffix(2))),
                Shot(name: "stopping", entries: Array(sample.prefix(3)), stubborn: [62702], stopping: [62645]),
                Shot(name: "crowded", entries: crowded, hint: true),
                Shot(name: "long-command", entries: crowded, expanded: "733:8080"),
                Shot(name: "plain-details", entries: Array(sample[2...4]), expanded: "51907:8000"),
                Shot(name: "unknown-container", entries: containers, expanded: "2210:8025"),
            ]
        }
        for shot in shots {
            let hint = shot.hint
            let model = PortsModel()
            model.showBackground = false
            model.entries = shot.entries
            model.stubborn = shot.stubborn
            model.stopping = shot.stopping
            model.expanded = shot.expanded
            model.loaded = true

            let menuBar: CGFloat = 32
            let height = Metrics.height(content: model.contentHeight, hint: hint)
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
                try? data.write(to: out.appendingPathComponent("\(shot.name).png"))
            }
        }
        exit(0)
    }
}
