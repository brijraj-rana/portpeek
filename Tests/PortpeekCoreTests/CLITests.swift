import Darwin
import XCTest
@testable import PortpeekCore

private let node = PortEntry(port: 3000, pid: 62645, process: "node", hosts: ["*"], executable: "/opt/homebrew/bin/node", directory: "/code/my-shop",
                             origin: Origin(name: "Cursor", kind: .editor), uptime: 3 * 3600,
                             command: "node /code/my-shop/node_modules/.bin/next dev", memory: 84 * 1024 * 1024, launchCommand: "npm run dev")
private let postgres = PortEntry(port: 5432, pid: 1341, process: "postgres", hosts: ["127.0.0.1", "::1"], executable: "/opt/homebrew/bin/postgres",
                                 directory: "/", origin: .detached)
private let backend = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
private let cache = ContainerInfo(id: "8a41c07be2d94b6f8c1d", name: "shop-cache", image: "redis:7-alpine", status: "Up 2 hours", containerPort: 6379, runtime: .docker)
private let container = PortEntry(port: 16379, pid: 2210, process: "com.docker.backend", hosts: ["*"], executable: backend, runtime: .docker, container: cache)
private let unknown = PortEntry(port: 8025, pid: 2210, process: "com.docker.backend", hosts: ["*"], executable: backend, runtime: .docker)

final class CLITests: XCTestCase {
    func testReadsItsArguments() throws {
        XCTAssertEqual(try CLI.parse([]), .list(all: false, json: false))
        XCTAssertEqual(try CLI.parse(["--json", "-a"]), .list(all: true, json: true))
        XCTAssertEqual(try CLI.parse(["3000"]), .show(port: 3000, json: false))
        XCTAssertEqual(try CLI.parse(["--json", "3000"]), .show(port: 3000, json: true))
        XCTAssertEqual(try CLI.parse([":3000"]), .show(port: 3000, json: false))
        XCTAssertEqual(try CLI.parse(["localhost:3000"]), .show(port: 3000, json: false))
        XCTAssertEqual(try CLI.parse(["kill", "3000"]), .kill(port: 3000, force: false))
        XCTAssertEqual(try CLI.parse(["kill", "--force", "3000"]), .kill(port: 3000, force: true))
        XCTAssertEqual(try CLI.parse(["kill", "3000", "-f"]), .kill(port: 3000, force: true))
        XCTAssertEqual(try CLI.parse(["--help"]), .help)
        XCTAssertEqual(try CLI.parse(["kill", "-h"]), .help)
        XCTAssertEqual(try CLI.parse(["--version"]), .version)
    }

    func testRejectsWhatItCannotRead() {
        for arguments in [["kill"], ["kill", "3000", "3001"], ["0"], ["65536"], ["web"], ["-3000"], ["3000", "3001"],
                          ["--force"], ["3000", "--force"], ["kill", "3000", "--json"], ["--nope"]] {
            XCTAssertThrowsError(try CLI.parse(arguments), arguments.joined(separator: " ")) { error in
                XCTAssertTrue(error is CLI.UsageError)
            }
        }
    }

    func testListsPortsInColumns() {
        XCTAssertEqual(CLI.table([node, postgres, unknown, container]), """
         PORT  PROCESS                      PROJECT  ORIGIN      PID
         3000  node                         my-shop  Cursor    62645
         5432  postgres                     -        detached   1341
         8025  container                    -        Docker     2210
        16379  shop-cache (redis:7-alpine)  -        Docker     2210
        """)
        XCTAssertEqual(CLI.table([]), "Nothing is listening.")
        // No line ends in spaces, whatever is in the last column.
        XCTAssertFalse(CLI.table([node, postgres]).split(separator: "\n").contains { $0.hasSuffix(" ") })
    }

    func testSaysWhoHoldsAPort() {
        XCTAssertEqual(CLI.describe([node, postgres], port: 3000), """
        Port 3000 is held by node (pid 62645)
          project    my-shop
          folder     /code/my-shop
          origin     Cursor
          command    node /code/my-shop/node_modules/.bin/next dev
          running    3 hours
          memory     84 MB
          restart    cd /code/my-shop && npm run dev
          address    http://localhost:3000
        """)
        XCTAssertEqual(CLI.describe([node], port: 8080), "Nothing is listening on port 8080.")
        XCTAssertEqual(CLI.describe([container], port: 16379), """
        Port 16379 is held by container shop-cache, forwarded by Docker (pid 2210)
          image      redis:7-alpine
          container  8a41c07be2d9
          status     Up 2 hours
          inside     port 6379
          address    http://localhost:16379
        """)
        XCTAssertTrue(CLI.describe([unknown], port: 8025).hasPrefix("Port 8025 is held by a container, forwarded by Docker (pid 2210). The container is not known."))
    }

    func testPrintsJSONAScriptCanRead() throws {
        let text = CLI.json([node, container])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0]["port"] as? Int, 3000)
        XCTAssertEqual(parsed[0]["pid"] as? Int, 62645)
        XCTAssertEqual(parsed[0]["name"] as? String, "node")
        XCTAssertEqual(parsed[0]["project"] as? String, "my-shop")
        XCTAssertEqual(parsed[0]["origin"] as? String, "Cursor")
        XCTAssertEqual(parsed[0]["uptimeSeconds"] as? Int, 10800)
        XCTAssertEqual(parsed[0]["memoryBytes"] as? Int, 88_080_384)
        XCTAssertEqual(parsed[0]["restartCommand"] as? String, "cd /code/my-shop && npm run dev")
        XCTAssertEqual(parsed[0]["address"] as? String, "http://localhost:3000")
        XCTAssertEqual(parsed[0]["background"] as? Bool, false)
        XCTAssertNil(parsed[0]["container"])
        XCTAssertEqual(parsed[1]["runtime"] as? String, "docker")
        XCTAssertEqual((parsed[1]["container"] as? [String: Any])?["name"] as? String, "shop-cache")
        XCTAssertEqual((parsed[1]["container"] as? [String: Any])?["containerPort"] as? Int, 6379)
        // Paths are left readable.
        XCTAssertTrue(text.contains("\"/code/my-shop\""))
        XCTAssertEqual(CLI.json([]).filter { !$0.isWhitespace }, "[]")
    }

    func testEveryOutcomeHasAMessageAndAnExitCode() {
        let outcomes: [(PortKiller.Outcome, CLI.ExitCode, String)] = [
            (.nothingListening, .notListening, "Nothing is listening on port 3000."),
            (.freed([node], forced: false), .ok, "Port 3000 is free. node (pid 62645) quit."),
            (.freed([node], forced: true), .ok, "Port 3000 is free. node (pid 62645) ignored the request and was stopped outright."),
            (.stillHeld([node], forced: false), .stillListening, "Port 3000 is still held by node (pid 62645). It ignored the request. Run it again with --force."),
            (.stillHeld([node], forced: true), .stillListening, "Port 3000 is still held by node (pid 62645), even after being forced."),
            (.retaken([node], by: [70001]), .stillListening,
             "node (pid 62645) quit, but port 3000 was taken again by pid 70001. Something restarts it, such as brew services or launchd."),
            (.runtimeOnly(unknown), .refused,
             "Port 3000 is forwarded by Docker and the container is not known. Killing Docker would stop every container, so nothing was done."),
            (.notPermitted([node]), .refused, "Could not signal node (pid 62645). It may belong to another user. Try with sudo."),
            (.containerStopped(cache), .ok, "Port 3000 is free. Container shop-cache was stopped. Docker was left running."),
            (.containerFailed(cache), .stillListening, "Could not stop container shop-cache. Port 3000 is still taken."),
        ]
        for (outcome, code, message) in outcomes {
            XCTAssertEqual(PortKiller.exitCode(outcome), code)
            XCTAssertEqual(PortKiller.message(outcome, port: 3000), message)
        }
        XCTAssertEqual(CLI.ExitCode.ok.rawValue, 0)
        XCTAssertEqual(CLI.ExitCode.notListening.rawValue, 1)
        XCTAssertEqual(CLI.ExitCode.usage.rawValue, 2)
        XCTAssertEqual(CLI.ExitCode.stillListening.rawValue, 3)
        XCTAssertEqual(CLI.ExitCode.refused.rawValue, 4)
    }

    func testTheVersionMatchesTheAppBundle() throws {
        // Tests run from the package folder, where the plist the app is built with lives.
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, PortpeekVersion.current)
    }
}

/// `portpeek kill` against real processes started here.
final class PortKillerTests: XCTestCase {
    /// A port nothing is using: bound for a moment to learn its number, then let go.
    private func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        XCTAssertEqual(bound, 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Starts `nc` listening on a port. With `deaf`, it is started so that it ignores a request to quit.
    private func listener(on port: Int, deaf: Bool = false) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", (deaf ? "trap '' TERM; " : "") + "exec /usr/bin/nc -l 127.0.0.1 \(port)"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(5)
        while PortScanner.holders(of: port).isEmpty, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(PortScanner.holders(of: port), [child.processIdentifier])
        return child
    }

    func testFreesAPort() throws {
        let port = try freePort()
        XCTAssertEqual(PortKiller.free(port: port, force: false), .nothingListening)

        let child = try listener(on: port)
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        guard case .freed(let entries, let forced) = PortKiller.free(port: port, force: false) else { return XCTFail("the port was not freed") }
        XCTAssertEqual(entries.map(\.pid), [child.processIdentifier])
        XCTAssertFalse(forced)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, SIGTERM)
        XCTAssertTrue(PortScanner.holders(of: port).isEmpty)
    }

    func testForceIsOnlyUsedWhenAskingFails() throws {
        let port = try freePort()
        let child = try listener(on: port, deaf: true)
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        // Asked politely, it stays, and the answer says so.
        guard case .stillHeld(let held, let forced) = PortKiller.free(port: port, force: false, patience: 0.5) else {
            return XCTFail("a process that ignores SIGTERM should still hold the port")
        }
        XCTAssertEqual(held.map(\.pid), [child.processIdentifier])
        XCTAssertFalse(forced)
        XCTAssertTrue(child.isRunning)

        guard case .freed(_, let wasForced) = PortKiller.free(port: port, force: true, patience: 0.5) else { return XCTFail("force did not free the port") }
        XCTAssertTrue(wasForced)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, SIGKILL)
    }

    func testNeverSignalsItself() {
        let own = PortEntry(port: 3000, pid: getpid(), process: "xctest")
        XCTAssertEqual(PortKiller.free(port: 3000, force: true, entries: [own], holders: { _ in [getpid()] }), .nothingListening)
    }
}
