import Darwin
import XCTest
@testable import PortpeekCore

/// What `ps -axww -o pid=,ppid=,tty=,etime=,comm=` prints, with made-up processes.
private let processes = """
    1     0 ??       9-04:11:52 /sbin/launchd
  410     1 ??       9-04:10:03 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
  420   410 ttys001    02:14:09 /usr/bin/login
  421   420 ttys001    02:14:08 -zsh
  900   421 ttys001       12:40 /opt/homebrew/bin/node
  500     1 ??       1-03:00:00 /Applications/Cursor.app/Contents/MacOS/Cursor
  510   500 ??       1-02:59:58 /Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)
  511   510 ttys004    03:00:10 /bin/zsh
  950   511 ttys004    03:00:01 /opt/homebrew/bin/node
  951   950 ttys004    03:00:00 /opt/homebrew/bin/node
  600     1 ??       6-00:00:00 /opt/homebrew/opt/postgresql@17/bin/postgres
  700     1 ??       2-00:00:00 /Users/sam/Library/Application Support/iTerm2/iTermServer-3.5.4
  701   700 ttys009    05:00:00 /bin/zsh
  702   701 ttys009       00:42 /opt/homebrew/bin/bun
  800     1 ??       4-00:00:00 /opt/homebrew/bin/tmux
  801   800 ttys012    01:00:00 -fish
  802   801 ttys012       30:00 /opt/homebrew/bin/python3.13
  850     1 ??          1:00:00 /Applications/Tabby.app/Contents/MacOS/Tabby
  851   850 ttys015       59:00 /bin/zsh
  852   851 ttys015       58:00 /opt/homebrew/bin/deno
  860     1 ??         10:00:00 /Applications/IntelliJ IDEA CE.app/Contents/MacOS/idea
  861   860 ??          9:00:00 /Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java
  870     1 ??       3-00:00:00 /Applications/Docker.app/Contents/MacOS/com.docker.backend
  880     1 ??       9-04:00:00 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
  990   989 ttys020       00:05 /opt/homebrew/bin/node
  995   996 ??            00:05 /usr/local/bin/first
  996   995 ??            00:05 /usr/local/bin/second
junk
  12 abc ?? 00:01 /bin/broken
"""

final class OriginTests: XCTestCase {
    private let table = ProcessTable.parse(processes)

    func testParsesTheProcessTable() {
        XCTAssertEqual(table.count, 27)

        let helper = table[510]
        XCTAssertEqual(helper?.parent, 500)
        XCTAssertNil(helper?.tty)
        XCTAssertEqual(helper?.executable, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        XCTAssertEqual(helper?.elapsed, 97_198)       // 1 day, 2 h, 59 min, 58 s

        let server = table[900]
        XCTAssertEqual(server?.tty, "ttys001")
        XCTAssertEqual(server?.elapsed, 760)
        XCTAssertEqual(table[700]?.executable, "/Users/sam/Library/Application Support/iTerm2/iTermServer-3.5.4")
        XCTAssertNil(table[12])
    }

    func testParsesElapsedTime() {
        XCTAssertEqual(ProcessTable.parseElapsed("00:05"), 5)
        XCTAssertEqual(ProcessTable.parseElapsed("12:40"), 760)
        XCTAssertEqual(ProcessTable.parseElapsed("02:14:09"), 8049)
        XCTAssertEqual(ProcessTable.parseElapsed("9-04:11:52"), 792_712)
        XCTAssertNil(ProcessTable.parseElapsed(""))
        XCTAssertNil(ProcessTable.parseElapsed("soon"))
        XCTAssertNil(ProcessTable.parseElapsed("1:2:3:4"))
        XCTAssertNil(ProcessTable.parseElapsed("x-01:02"))
    }

    func testFindsTheTerminalBehindAShell() {
        // node, started in zsh, inside login, inside Terminal.
        let origin = ProcessTable.origin(of: 900, in: table)
        XCTAssertEqual(origin?.name, "Terminal")
        XCTAssertEqual(origin?.kind, .terminal)
        XCTAssertEqual(origin?.pid, 410)
        XCTAssertEqual(origin?.label, "from Terminal")
        XCTAssertEqual(origin?.terminalScripting, .terminal)
        XCTAssertEqual(origin?.isOwnApp, false)
        XCTAssertEqual(origin?.canActivate, true)
    }

    func testClimbsFromAHelperToTheAppItself() {
        // The shell belongs to a helper process; the thing to bring forward is Cursor.
        let origin = ProcessTable.origin(of: 951, in: table)
        XCTAssertEqual(origin?.name, "Cursor")
        XCTAssertEqual(origin?.kind, .editor)
        XCTAssertEqual(origin?.pid, 500)
        XCTAssertNil(origin?.terminalScripting)
    }

    func testFindsITermThroughItsServerProcess() {
        let origin = ProcessTable.origin(of: 702, in: table)
        XCTAssertEqual(origin?.name, "iTerm2")
        XCTAssertEqual(origin?.bundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(origin?.terminalScripting, .iTerm)
    }

    func testNamesOtherHosts() {
        XCTAssertEqual(ProcessTable.origin(of: 861, in: table)?.name, "IntelliJ IDEA")
        XCTAssertEqual(ProcessTable.origin(of: 861, in: table)?.kind, .editor)

        // An app nobody listed is still named.
        let unknown = ProcessTable.origin(of: 852, in: table)
        XCTAssertEqual(unknown?.name, "Tabby")
        XCTAssertEqual(unknown?.kind, .app)
        XCTAssertEqual(unknown?.pid, 850)

        // tmux outlives the window it was started in, so there is nothing to bring forward.
        let tmux = ProcessTable.origin(of: 802, in: table)
        XCTAssertEqual(tmux?.name, "tmux")
        XCTAssertEqual(tmux?.canActivate, false)
        XCTAssertNil(tmux?.pid)
    }

    func testAParentOfLaunchdMeansDetached() {
        let postgres = ProcessTable.origin(of: 600, in: table)
        XCTAssertEqual(postgres, .detached)
        XCTAssertEqual(postgres?.label, "detached")
        XCTAssertEqual(postgres?.canActivate, false)

        // A part of macOS that happens to be an app is not a place servers are started from.
        XCTAssertEqual(ProcessTable.origin(of: 880, in: table), .detached)
    }

    func testAnAppIsNotStartedFromItself() {
        let docker = ProcessTable.origin(of: 870, in: table)
        XCTAssertEqual(docker?.name, "Docker")
        XCTAssertEqual(docker?.isOwnApp, true)

        let entry = PortEntry(port: 2375, pid: 870, process: "com.docker.backend", origin: docker)
        XCTAssertNil(entry.startedFrom)
    }

    func testGivesUpOnBrokenAndCircularChains() {
        XCTAssertNil(ProcessTable.origin(of: 990, in: table))     // the parent has gone
        XCTAssertNil(ProcessTable.origin(of: 995, in: table))     // two processes naming each other
        XCTAssertNil(ProcessTable.origin(of: 4242, in: table))    // not in the table at all
        XCTAssertNil(ProcessTable.origin(of: 7, in: [7: ProcessRecord(pid: 7, parent: 7, executable: "/bin/self")]))
    }

    func testRecognisesEveryHostByItsPath() {
        let paths = [
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal": "Terminal",
            "/Applications/iTerm.app/Contents/MacOS/iTerm2": "iTerm2",
            "/Applications/Warp.app/Contents/MacOS/stable": "Warp",
            "/Applications/Ghostty.app/Contents/MacOS/ghostty": "Ghostty",
            "/Applications/kitty.app/Contents/MacOS/kitty": "kitty",
            "/opt/homebrew/bin/kitty": "kitty",
            "/Applications/Alacritty.app/Contents/MacOS/alacritty": "Alacritty",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui": "WezTerm",
            "/Applications/Visual Studio Code.app/Contents/MacOS/Electron": "VS Code",
            "/Applications/Cursor.app/Contents/MacOS/Cursor": "Cursor",
            "/Applications/Zed.app/Contents/MacOS/zed": "Zed",
            "/Applications/Xcode.app/Contents/MacOS/Xcode": "Xcode",
            "/Applications/WebStorm.app/Contents/MacOS/webstorm": "WebStorm",
            "/Applications/PyCharm CE.app/Contents/MacOS/pycharm": "PyCharm",
            "/Applications/Docker.app/Contents/MacOS/com.docker.backend": "Docker",
        ]
        for (path, name) in paths {
            XCTAssertEqual(Host.match(path)?.name, name, path)
        }
        XCTAssertNil(Host.match("/opt/homebrew/bin/node"))
        XCTAssertNil(Host.match("/bin/zsh"))
        XCTAssertNil(Host.match("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
        for name in ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "Alacritty", "WezTerm", "VS Code", "Cursor", "Zed", "Xcode", "Docker"] {
            XCTAssertTrue(Host.recognised.contains(name), name)
        }
    }

    func testAttachesWhatTheTableKnowsToEachPort() {
        let listeners = [
            PortEntry(port: 3000, pid: 951, process: "node"),
            PortEntry(port: 3001, pid: 951, process: "node"),
            PortEntry(port: 5432, pid: 600, process: "postgres"),
            PortEntry(port: 9999, pid: 4242, process: "gone"),
        ]
        let entries = PortScanner.attach(table, directories: [951: "/code/my-shop"], to: listeners)

        XCTAssertEqual(entries[0].startedFrom?.label, "from Cursor")
        XCTAssertEqual(entries[1].origin, entries[0].origin)
        XCTAssertEqual(entries[0].tty, "ttys004")
        XCTAssertEqual(entries[0].uptime, 10_800)
        XCTAssertEqual(entries[0].executable, "/opt/homebrew/bin/node")
        XCTAssertEqual(entries[0].project, "my-shop")
        XCTAssertEqual(entries[2].startedFrom, .detached)
        XCTAssertNil(entries[2].tty)
        XCTAssertNil(entries[3].origin)
        XCTAssertNil(entries[3].uptime)
        XCTAssertNil(entries[3].executable)
    }

    func testBuildsATabScriptOnlyForARealTerminalDevice() throws {
        XCTAssertEqual(TerminalFocus.device(for: "ttys004"), "/dev/ttys004")
        XCTAssertNil(TerminalFocus.device(for: nil))
        XCTAssertNil(TerminalFocus.device(for: "??"))
        XCTAssertNil(TerminalFocus.device(for: "console"))
        // Nothing that could end the string and start a command of its own.
        XCTAssertNil(TerminalFocus.device(for: "ttys004\" then do shell script \"true"))
        XCTAssertNil(TerminalFocus.device(for: "ttys004\n"))
        XCTAssertNil(TerminalFocus.device(for: "tty/../x"))

        let terminal = try XCTUnwrap(TerminalFocus.script(for: .terminal, tty: "ttys004"))
        XCTAssertTrue(terminal.contains("application id \"com.apple.Terminal\""))
        XCTAssertTrue(terminal.contains("if tty of t is \"/dev/ttys004\""))

        let iTerm = try XCTUnwrap(TerminalFocus.script(for: .iTerm, tty: "ttys009"))
        XCTAssertTrue(iTerm.contains("application id \"com.googlecode.iterm2\""))
        XCTAssertTrue(iTerm.contains("if tty of s is \"/dev/ttys009\""))

        XCTAssertNil(TerminalFocus.script(for: .terminal, tty: "??"))
    }

    func testSaysHowLongItHasBeenUp() {
        XCTAssertEqual(Uptime.phrase(20), "Up less than a minute")
        XCTAssertEqual(Uptime.phrase(60), "Up 1 minute")
        XCTAssertEqual(Uptime.phrase(760), "Up 12 minutes")
        XCTAssertEqual(Uptime.phrase(3600), "Up 1 hour")
        XCTAssertEqual(Uptime.phrase(169_200), "Up 47 hours")
        XCTAssertEqual(Uptime.phrase(518_400), "Up 6 days")
        XCTAssertNil(Uptime.phrase(nil))
        XCTAssertNil(Uptime.phrase(-1))
    }

    func testAddressForCopying() {
        XCTAssertEqual(PortEntry(port: 3000, pid: 10, process: "node").address, "localhost:3000")
        XCTAssertEqual(PortEntry(port: 5432, pid: 11, process: "postgres").address, "localhost:5432")
    }
}

final class ProjectTests: XCTestCase {
    private let node = "/opt/homebrew/bin/node"

    private func entry(_ port: Int, _ pid: Int32, _ directory: String?, executable: String? = "/opt/homebrew/bin/node",
                       hosts: [String] = ["*"]) -> PortEntry {
        PortEntry(port: port, pid: pid, process: "node", hosts: hosts, executable: executable, directory: directory)
    }

    func testGroupsPortsThatShareAFolder() {
        let entries = [
            entry(3000, 10, "/code/my-shop"),
            entry(5173, 20, "/code/dashboard"),
            entry(8025, 11, "/code/my-shop"),
            entry(9000, 30, "/code/blog"),
        ]
        let sections = Projects.sections(entries)

        XCTAssertEqual(sections.map(\.id), ["project:/code/my-shop", "20:5173", "30:9000"])
        guard case .project(let group) = sections[0] else { return XCTFail("expected a project first") }
        XCTAssertEqual(group.name, "my-shop")
        XCTAssertEqual(group.entries.map(\.port), [3000, 8025])
        // Every port is still shown exactly once.
        XCTAssertEqual(sections.flatMap(\.entries).map(\.port).sorted(), [3000, 5173, 8025, 9000])
    }

    func testAProjectWithOnePortStaysAPlainRow() {
        let sections = Projects.sections([entry(3000, 10, "/code/my-shop"), entry(5173, 20, "/code/dashboard")])
        XCTAssertEqual(sections, [.row(entry(3000, 10, "/code/my-shop")), .row(entry(5173, 20, "/code/dashboard"))])
        XCTAssertTrue(Projects.sections([]).isEmpty)
    }

    func testFoldersWithTheSameNameAreDifferentProjects() {
        let sections = Projects.sections([entry(3000, 10, "/work/site"), entry(4000, 20, "/personal/site")])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(Projects.stopTargets(directory: "/work/site", in: [entry(3000, 10, "/work/site"), entry(4000, 20, "/personal/site")], own: 0), [10])
    }

    func testSystemServicesAndHelpersNeverJoinAProject() {
        let system = entry(7000, 40, "/code/my-shop", executable: "/usr/libexec/rapportd")
        let helper = entry(13602, 41, "/code/my-shop", executable: "/Applications/Cursor.app/Contents/MacOS/Cursor Helper", hosts: ["127.0.0.1"])
        let random = entry(59679, 42, "/code/my-shop")
        // An app listening where everyone can reach it is shown, but the folder it works in is not a project.
        let app = entry(8000, 48, "/code/my-shop", executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        let rootless = [entry(5432, 43, "/"), entry(6379, 44, "/"), entry(8000, 45, nil), entry(8001, 46, nil)]
        let entries = [entry(3000, 10, "/code/my-shop"), entry(3001, 11, "/code/my-shop"), system, helper, random, app] + rootless

        let sections = Projects.sections(entries)
        XCTAssertEqual(sections.count, 9)
        guard case .project(let group) = sections[0] else { return XCTFail("expected a project first") }
        XCTAssertEqual(group.entries.map(\.pid), [10, 11])
        for other in [system, helper, random, app] + rootless {
            XCTAssertTrue(sections.contains(.row(other)), "\(other.port) should stay a row of its own")
        }
    }

    /// The rule behind "Stop all".
    func testStopAllOnlyReachesProcessesInThatProject() {
        let entries = [
            entry(3000, 10, "/code/my-shop"),
            entry(3001, 10, "/code/my-shop"),                                     // same process, second port
            entry(8025, 11, "/code/my-shop"),
            entry(5173, 20, "/code/dashboard"),                                   // another project
            entry(4000, 21, "/code/my-shop-admin"),                               // a folder whose name merely starts the same
            entry(4001, 22, "/code/my-shop/api"),                                 // a folder inside it
            entry(7000, 40, "/code/my-shop", executable: "/usr/libexec/rapportd"),      // a system service that happens to sit there
            entry(7001, 47, "/code/my-shop", executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
            entry(13602, 41, "/code/my-shop", executable: "/Applications/Cursor.app/Contents/MacOS/Cursor Helper", hosts: ["127.0.0.1"]),
            entry(59679, 42, "/code/my-shop"),                                    // a random high port, hidden with the background ones
            entry(8000, 48, "/code/my-shop", executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),   // an app
            entry(9000, 1, "/code/my-shop"),                                      // launchd, whatever the table claims
            entry(9001, 77, "/code/my-shop"),                                     // Portpeek itself
            entry(9002, 50, nil),
        ]
        XCTAssertEqual(Projects.stopTargets(directory: "/code/my-shop", in: entries, own: 77), [10, 11])
        XCTAssertEqual(Projects.stopTargets(directory: "/code/dashboard", in: entries, own: 77), [20])
        XCTAssertEqual(Projects.stopTargets(directory: "/code/nothing-here", in: entries, own: 77), [])
        XCTAssertEqual(Projects.stopTargets(directory: "/", in: [entry(5432, 43, "/")], own: 77), [])

        // Whatever is asked, a system service is never among the targets.
        for directory in Set(entries.compactMap(\.directory)) {
            let targets = Projects.stopTargets(directory: directory, in: entries, own: 77)
            XCTAssertFalse(targets.contains(40))
            XCTAssertFalse(targets.contains(47))
            XCTAssertFalse(targets.contains(48))
            XCTAssertFalse(targets.contains(1))
            XCTAssertFalse(targets.contains(77))
        }
    }

    /// Stops two real processes that stand in for a project and checks a third, outside it, is left running.
    func testStopAllLeavesOtherProcessesRunning() throws {
        func sleeper() throws -> Process {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try child.run()
            return child
        }
        let web = try sleeper(), database = try sleeper(), bystander = try sleeper()
        defer { for child in [web, database, bystander] where child.isRunning { child.terminate() } }

        let entries = [
            entry(3000, web.processIdentifier, "/code/my-shop"),
            entry(5433, database.processIdentifier, "/code/my-shop"),
            entry(5173, bystander.processIdentifier, "/code/dashboard"),
        ]
        let targets = Projects.stopTargets(directory: "/code/my-shop", in: entries)
        XCTAssertEqual(targets, [web.processIdentifier, database.processIdentifier])
        for pid in targets { XCTAssertTrue(ProcessControl.stop(pid)) }

        web.waitUntilExit()
        database.waitUntilExit()
        XCTAssertEqual(web.terminationStatus, SIGTERM)
        XCTAssertEqual(database.terminationStatus, SIGTERM)
        XCTAssertTrue(bystander.isRunning)
        XCTAssertTrue(ProcessControl.isRunning(bystander.processIdentifier))
    }
}
