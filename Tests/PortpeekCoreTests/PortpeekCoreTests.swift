import Darwin
import XCTest
@testable import PortpeekCore

final class PortpeekCoreTests: XCTestCase {
    func testParsesListenersAndMergesAddressFamilies() {
        let text = """
        p1252
        cControlCenter
        Lsam
        f10
        n*:7000
        f11
        n*:7000
        p1341
        cpostgres
        Lsam
        f7
        n[::1]:5432
        f8
        n127.0.0.1:5432
        p62645
        cnode
        Lsam
        f16
        n*:3000
        f18
        n*:3001
        """
        let entries = PortScanner.parseListeners(text)

        XCTAssertEqual(entries.map(\.port), [3000, 3001, 5432, 7000])
        XCTAssertEqual(entries.map(\.process), ["node", "node", "postgres", "ControlCenter"])
        XCTAssertEqual(entries[2].hosts, ["127.0.0.1", "::1"])
        XCTAssertEqual(entries[2].pid, 1341)
        XCTAssertEqual(entries[2].user, "sam")
        XCTAssertEqual(entries[3].hosts, ["*"])
    }

    func testIgnoresLinesItCannotRead() {
        let text = "p12\ncnode\nnnot-a-socket\nn*:abc\n\npoops\nn*:8080\n"
        XCTAssertTrue(PortScanner.parseListeners(text).isEmpty)
    }

    func testParsesDirectoriesAndProcessPathsWithSpaces() {
        let directories = PortScanner.parseDirectories("p12\nfcwd\nn/Users/sam/My Projects/site\np13\nfcwd\nn/\n")
        XCTAssertEqual(directories, [12: "/Users/sam/My Projects/site", 13: "/"])

        let processes = PortScanner.parseProcesses("""
           12 /usr/local/bin/node
        28256 /Applications/Visual Studio Code.app/Contents/MacOS/Code Helper (Plugin)
        junk
        """)
        XCTAssertEqual(processes[12], "/usr/local/bin/node")
        XCTAssertEqual(processes[28256], "/Applications/Visual Studio Code.app/Contents/MacOS/Code Helper (Plugin)")
        XCTAssertEqual(processes.count, 2)
    }

    func testClassifiesEntries() {
        let dev = PortEntry(port: 3000, pid: 10, process: "node", hosts: ["*"],
                            executable: "/opt/homebrew/bin/node", directory: "/Users/sam/code/portfolio")
        XCTAssertEqual(dev.project, "portfolio")
        XCTAssertFalse(dev.isSystem)
        XCTAssertFalse(dev.isBackground)
        XCTAssertFalse(dev.isLocalOnly)
        XCTAssertEqual(dev.url?.absoluteString, "http://localhost:3000")

        let database = PortEntry(port: 5432, pid: 11, process: "postgres", hosts: ["127.0.0.1", "::1"], directory: "/")
        XCTAssertNil(database.project)
        XCTAssertTrue(database.isLocalOnly)
        XCTAssertNil(database.url)

        let airplay = PortEntry(port: 7000, pid: 12, process: "ControlCenter",
                                executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")
        XCTAssertTrue(airplay.isSystem)
        XCTAssertTrue(airplay.isBackground)

        let helper = PortEntry(port: 59679, pid: 13, process: "Code Helper", executable: "/Applications/Code.app/Contents/MacOS/Code Helper")
        XCTAssertFalse(helper.isSystem)
        XCTAssertTrue(helper.isBackground)

        // An editor's live preview server is listed under the app's name, and stays visible because other devices can reach it.
        let path = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let preview = PortEntry(port: 5500, pid: 14, process: "Code Helper (Plugin)", hosts: ["*"], executable: path)
        XCTAssertEqual(preview.displayName, "Visual Studio Code")
        XCTAssertFalse(preview.isBackground)

        // The same app talking to itself on loopback is noise.
        let chatter = PortEntry(port: 13602, pid: 14, process: "Code Helper (Plugin)", hosts: ["127.0.0.1"], executable: path)
        XCTAssertTrue(chatter.isBackground)
        XCTAssertEqual(dev.displayName, "node")
    }

    func testRefusesToSignalLaunchd() {
        XCTAssertFalse(ProcessControl.stop(1))
        XCTAssertFalse(ProcessControl.stop(0))
        XCTAssertFalse(ProcessControl.stop(-1))
    }

    func testStopsAProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        XCTAssertTrue(ProcessControl.isRunning(pid))

        XCTAssertTrue(ProcessControl.stop(pid))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    /// Opens a real listening socket and checks the scanner finds it, attributed to this process.
    func testFindsALiveListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))

        let entry = try XCTUnwrap(PortScanner.scan().first { $0.port == port })
        XCTAssertEqual(entry.pid, getpid())
        XCTAssertEqual(entry.hosts, ["127.0.0.1"])
        XCTAssertTrue(entry.isLocalOnly)
        XCTAssertNotNil(entry.executable)
        XCTAssertNotNil(entry.uptime)
        XCTAssertTrue(ProcessControl.isRunning(entry.pid))
    }
}
