import Darwin
import XCTest
@testable import PortpeekCore

/// What `ps -axww -o pid=,ppid=,tty=,etime=,comm=` prints for a dev server started with `npm run dev`, with made-up processes.
private let processes = """
    1     0 ??       9-04:11:52 /sbin/launchd
  410     1 ??       9-04:10:03 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
  420   410 ttys001    02:14:09 /usr/bin/login
  421   420 ttys001    02:14:08 -zsh
  900   421 ttys001       12:40 npm run dev
  901   900 ttys001       12:40 /bin/sh
  902   901 ttys001       12:39 /opt/homebrew/bin/node
  903   902 ttys001       12:38 next-server (v15.1.0)
  500     1 ??       1-03:00:00 /Applications/Cursor.app/Contents/MacOS/Cursor
  510   500 ??       1-02:59:58 /Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)
  511   510 ttys004    03:00:10 /bin/zsh
  950   511 ttys004    03:00:01 /opt/homebrew/bin/python3.13
  600     1 ??       6-00:00:00 /opt/homebrew/opt/postgresql@17/bin/postgres
  700   510 ??          1:00:00 /bin/zsh
  701   700 ??          1:00:00 /opt/homebrew/bin/bun
  990   989 ttys020       00:05 /opt/homebrew/bin/node
"""

/// What `ps -axww -o pid=,rss=,args=` prints for the same processes.
private let details = """
    1  18432 /sbin/launchd
  410  95312 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
  420   4096 login -pf sam
  421   6144 -zsh
  900  61440 npm run dev
  901   1024 sh -c next dev --port 3000
  902  84512 node /code/my-shop/node_modules/.bin/next dev --port 3000
  903 421888 next-server (v15.1.0)
  511   5120 /bin/zsh -il
  950  63488 python3.13 -m uvicorn app.main:app --reload
  600  20480 /opt/homebrew/opt/postgresql@17/bin/postgres -D /opt/homebrew/var/postgresql@17
  700   2048 /bin/zsh -c bun run dev
  701  40960 bun run dev
  990      0
  991  12288 /usr/bin/unlisted --flag
junk line
"""

/// What `docker ps --no-trunc --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}'` prints.
/// The last container line is as Docker Desktop printed it for a test container. The others follow its shape,
/// with made-up names and ids, to cover the forms the ports column takes.
private let dockerPS = [
    "3f2a9c1d7b0e4a5f9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b\tshop-db\tpostgres:17\tUp 2 hours\t0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp",
    "8a41c07be2d94b6f8c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b\tshop-cache\tredis:7-alpine\tUp 2 hours (healthy)\t127.0.0.1:6379->6379/tcp",
    "c0ffee1234567890c0ffee1234567890c0ffee1234567890c0ffee1234567890\tshop-web-1,shop-proxy-1/web\tghcr.io/acme/storefront:2026.11\tUp 5 minutes\t0.0.0.0:8080-8082->80-82/tcp, :::8080-8082->80-82/tcp, 9229/tcp",
    "d1e2f3a4b5c6d1e2f3a4b5c6d1e2f3a4b5c6d1e2f3a4b5c6d1e2f3a4b5c6d1e2\tshop-dns\tcoredns/coredns:1.11\tUp 5 minutes\t0.0.0.0:5353->53/udp, 0.0.0.0:9153->9153/tcp",
    "e5f6a7b8c9d0e5f6a7b8c9d0e5f6a7b8c9d0e5f6a7b8c9d0e5f6a7b8c9d0e5f6\tworker\tacme/worker:latest\tUp 3 days\t",
    "f00dbabe0000\tmailpit\tdocker.io/axllent/mailpit:latest\tUp 1 minute\t0.0.0.0:8025->8025/tcp, 0.0.0.0:1025->1025/tcp",
    "edc9951aa204d6695c832164e8cfc71f12ca3b9700a5e6aef80a2309a786eb4a\tportpeek-selftest\taxllent/mailpit:latest\tUp 2 seconds (healthy)\t0.0.0.0:18026->1025/tcp, [::]:18026->1025/tcp, 0.0.0.0:18027->1026/tcp, [::]:18027->1026/tcp, 127.0.0.1:18025->8025/tcp",
    "",
    "not a container line",
].joined(separator: "\n")

private let backend = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"

final class DetailsTests: XCTestCase {
    private let table = ProcessTable.addDetails(details, to: ProcessTable.parse(processes))

    func testReadsCommandLinesAndMemory() {
        XCTAssertEqual(table[902]?.command, "node /code/my-shop/node_modules/.bin/next dev --port 3000")
        XCTAssertEqual(table[902]?.memory, 84512 * 1024)
        XCTAssertEqual(table[903]?.command, "next-server (v15.1.0)")
        XCTAssertEqual(table[421]?.command, "-zsh")
        // A line with no command, a process the first table never saw, and junk are all passed over.
        XCTAssertNil(table[990]?.command)
        XCTAssertNil(table[990]?.memory)
        XCTAssertNil(table[991])
        XCTAssertEqual(table.count, ProcessTable.parse(processes).count)
    }

    func testFindsWhatWasTypedToStartAServer() {
        // next-server renamed itself; above it are node, a shell wrapper and npm, and above that the shell it was typed into.
        XCTAssertEqual(ProcessTable.launcher(of: 903, in: table)?.command, "npm run dev")
        XCTAssertEqual(ProcessTable.launcher(of: 902, in: table)?.pid, 900)
        // Typed straight into an editor's terminal.
        XCTAssertEqual(ProcessTable.launcher(of: 950, in: table)?.command, "python3.13 -m uvicorn app.main:app --reload")
        // Under launchd, the service is its own launcher.
        XCTAssertEqual(ProcessTable.launcher(of: 600, in: table)?.pid, 600)
        // Started by an app through `zsh -c`: the wrapper is passed over, and the app is where the walk stops.
        XCTAssertEqual(ProcessTable.launcher(of: 701, in: table)?.command, "bun run dev")
        // A broken chain or a process with no command line gives nothing.
        XCTAssertNil(ProcessTable.launcher(of: 990, in: table))
        XCTAssertNil(ProcessTable.launcher(of: 4242, in: table))
    }

    func testTellsAnInteractiveShellFromAScript() {
        XCTAssertTrue(Shells.isShell("-zsh"))
        XCTAssertTrue(Shells.isShell("/bin/bash"))
        XCTAssertTrue(Shells.isShell("/opt/homebrew/bin/fish"))
        XCTAssertFalse(Shells.isShell("/opt/homebrew/bin/node"))
        XCTAssertTrue(Shells.isInteractive("-zsh"))
        XCTAssertTrue(Shells.isInteractive("/bin/zsh -il"))
        XCTAssertTrue(Shells.isInteractive("/bin/bash --login"))
        XCTAssertFalse(Shells.isInteractive("sh -c next dev"))
        XCTAssertFalse(Shells.isInteractive("/bin/bash ./start.sh"))
    }

    func testTheScannerAttachesCommandMemoryAndLauncher() {
        let entries = PortScanner.attach(table, directories: [903: "/code/my-shop/apps/web", 900: "/code/my-shop", 600: "/opt/homebrew/var/postgresql@17"],
                                         to: [PortEntry(port: 3000, pid: 903, process: "next-server (v15.1.0)"),
                                              PortEntry(port: 5432, pid: 600, process: "postgres")])
        XCTAssertEqual(entries[0].command, "next-server (v15.1.0)")
        XCTAssertEqual(entries[0].memory, 421888 * 1024)
        XCTAssertEqual(entries[0].launchCommand, "npm run dev")
        // The folder is the one npm ran in, not the one the server moved to.
        XCTAssertEqual(entries[0].restartCommand, "cd /code/my-shop && npm run dev")
        XCTAssertEqual(entries[1].restartCommand,
                       "cd /opt/homebrew/var/postgresql@17 && /opt/homebrew/opt/postgresql@17/bin/postgres -D /opt/homebrew/var/postgresql@17")
        XCTAssertNil(entries[0].runtime)
    }

    func testRestartCommandNeedsACommandAndAFolder() {
        let node = "/opt/homebrew/bin/node"
        XCTAssertEqual(PortEntry(port: 1, pid: 2, process: "node", executable: node, directory: "/code/api", command: "node server.js").restartCommand,
                       "cd /code/api && node server.js")
        // The launcher's command and folder win over the listener's own.
        XCTAssertEqual(PortEntry(port: 1, pid: 2, process: "node", executable: node, directory: "/code/api/dist", command: "node server.js",
                                 launchCommand: "pnpm dev", launchDirectory: "/code/api").restartCommand, "cd /code/api && pnpm dev")
        XCTAssertEqual(PortEntry(port: 1, pid: 2, process: "node", directory: "/code/my shop/it's", command: "node server.js").restartCommand,
                       "cd '/code/my shop/it'\\''s' && node server.js")
        XCTAssertNil(PortEntry(port: 1, pid: 2, process: "node", directory: "/code/api").restartCommand)
        XCTAssertNil(PortEntry(port: 1, pid: 2, process: "node", command: "node server.js").restartCommand)
        // Not for system services, apps or containers: none of them is started by typing its command line.
        XCTAssertNil(PortEntry(port: 1, pid: 2, process: "rapportd", executable: "/usr/libexec/rapportd", directory: "/", command: "/usr/libexec/rapportd").restartCommand)
        XCTAssertNil(PortEntry(port: 1, pid: 2, process: "Code Helper", executable: "/Applications/Code.app/Contents/MacOS/Code Helper",
                               directory: "/code/api", command: "Code Helper --type=utility").restartCommand)
        XCTAssertNil(PortEntry(port: 1, pid: 2, process: "com.docker.backend", executable: backend, directory: "/code/api",
                               command: "com.docker.backend services", runtime: .docker).restartCommand)
    }

    func testAServerRunByHomebrewPythonIsNotAnApp() {
        // Homebrew's Python runs from an app bundle inside its framework. That is plumbing, not an app.
        let python = "/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
        let entry = PortEntry(port: 8000, pid: 7, process: "Python", hosts: ["127.0.0.1"], executable: python, directory: "/code/api",
                              command: python + " -m http.server 8000")
        XCTAssertNil(entry.appName)
        XCTAssertFalse(entry.isBackground)
        XCTAssertTrue(Projects.belongsToProject(entry))
        XCTAssertEqual(entry.restartCommand, "cd /code/api && " + python + " -m http.server 8000")
        // A helper inside a real app is still that app.
        let helper = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
        XCTAssertEqual(PortEntry(port: 1, pid: 2, process: "Cursor Helper (Plugin)", executable: helper).appName, "Cursor")
    }

    func testQuotesOnlyWhatAShellWouldTrip() {
        XCTAssertEqual(ShellQuote.quote("/code/my-shop_2/v1.0+a@b"), "/code/my-shop_2/v1.0+a@b")
        XCTAssertEqual(ShellQuote.quote("/code/my shop"), "'/code/my shop'")
        XCTAssertEqual(ShellQuote.quote("/code/$HOME/(x)"), "'/code/$HOME/(x)'")
        XCTAssertEqual(ShellQuote.quote(""), "''")
    }

    func testFormatsMemory() {
        XCTAssertEqual(Memory.format(0), "0 KB")
        XCTAssertEqual(Memory.format(512 * 1024), "512 KB")
        XCTAssertEqual(Memory.format(1023 * 1024), "1023 KB")
        XCTAssertEqual(Memory.format(1024 * 1024), "1 MB")
        XCTAssertEqual(Memory.format(8_808_038), "8.4 MB")
        XCTAssertEqual(Memory.format(84 * 1024 * 1024), "84 MB")
        XCTAssertEqual(Memory.format(1000 * 1024 * 1024), "1000 MB")
        XCTAssertEqual(Memory.format(1024 * 1024 * 1024), "1 GB")
        XCTAssertEqual(Memory.format(1_288_490_189), "1.2 GB")
        XCTAssertEqual(Memory.format(12 * 1024 * 1024 * 1024), "12 GB")
        XCTAssertNil(Memory.format(nil))
        XCTAssertNil(Memory.format(-1))
    }

    func testSaysHowLongInWords() {
        XCTAssertEqual(Uptime.duration(20), "less than a minute")
        XCTAssertEqual(Uptime.duration(60), "1 minute")
        XCTAssertEqual(Uptime.duration(3 * 3600), "3 hours")
        XCTAssertEqual(Uptime.duration(9 * 86_400), "9 days")
        XCTAssertNil(Uptime.duration(nil))
        XCTAssertEqual(Uptime.phrase(3 * 3600), "Up 3 hours")
    }

    func testAnOpenRowShowsCommandFactsAndThingsToCopy() {
        let entry = PortEntry(port: 3000, pid: 9, process: "node", executable: "/opt/homebrew/bin/node", directory: "/code/my-shop",
                              uptime: 3 * 3600, command: "node server.js", memory: 84 * 1024 * 1024, launchCommand: "npm start")
        let shown = entry.details
        XCTAssertEqual(shown.headline, "node server.js")
        XCTAssertEqual(shown.facts, "Up 3 hours · 84 MB")
        XCTAssertEqual(shown.copies.map(\.title), ["Copy command", "Copy address", "Copy restart command"])
        XCTAssertEqual(shown.copies.map(\.text), ["node server.js", "http://localhost:3000", "cd /code/my-shop && npm start"])

        // Nothing known but the port: the address can still be copied.
        let bare = PortEntry(port: 5432, pid: 9, process: "postgres").details
        XCTAssertNil(bare.headline)
        XCTAssertNil(bare.facts)
        XCTAssertEqual(bare.copies, [PortDetails.Copy("Address", text: "http://localhost:5432")])
    }
}

final class ContainerTests: XCTestCase {
    private let containers = Containers.parse(dockerPS)

    func testReadsDockerPS() {
        XCTAssertEqual(containers.map(\.name), ["shop-db", "shop-cache", "shop-web-1", "shop-dns", "worker", "mailpit", "portpeek-selftest"])
        XCTAssertEqual(containers[6].mappings, [PublishedContainer.Mapping(host: 18026...18026, container: 1025),
                                                PublishedContainer.Mapping(host: 18027...18027, container: 1026),
                                                PublishedContainer.Mapping(host: 18025...18025, container: 8025)])
        XCTAssertEqual(containers[6].status, "Up 2 seconds (healthy)")
        XCTAssertEqual(containers[0].image, "postgres:17")
        XCTAssertEqual(containers[0].status, "Up 2 hours")
        // IPv4 and IPv6 say the same thing once.
        XCTAssertEqual(containers[0].mappings, [PublishedContainer.Mapping(host: 5433...5433, container: 5432)])
        XCTAssertEqual(containers[1].status, "Up 2 hours (healthy)")
        XCTAssertEqual(containers[1].mappings, [PublishedContainer.Mapping(host: 6379...6379, container: 6379)])
        // A range, and a port that is exposed but not published.
        XCTAssertEqual(containers[2].mappings, [PublishedContainer.Mapping(host: 8080...8082, container: 80)])
        // UDP is not a listening TCP port.
        XCTAssertEqual(containers[3].mappings, [PublishedContainer.Mapping(host: 9153...9153, container: 9153)])
        XCTAssertEqual(containers[4].mappings, [])
        XCTAssertEqual(containers[5].mappings.count, 2)
    }

    func testReadsThePortsColumn() {
        XCTAssertEqual(Containers.parsePorts("0.0.0.0:3000->3000/tcp"), [PublishedContainer.Mapping(host: 3000...3000, container: 3000)])
        XCTAssertEqual(Containers.parsePorts(":::8443->443/tcp"), [PublishedContainer.Mapping(host: 8443...8443, container: 443)])
        XCTAssertEqual(Containers.parsePorts("[::1]:8443->443/tcp"), [PublishedContainer.Mapping(host: 8443...8443, container: 443)])
        XCTAssertEqual(Containers.parsePorts("8080->80/tcp"), [PublishedContainer.Mapping(host: 8080...8080, container: 80)])
        XCTAssertEqual(Containers.parsePorts("80/tcp, 443/tcp"), [])
        XCTAssertEqual(Containers.parsePorts("0.0.0.0:53->53/udp"), [])
        XCTAssertEqual(Containers.parsePorts("0.0.0.0:x->80/tcp, 0.0.0.0:99999->80/tcp, 0.0.0.0:9-3->80/tcp"), [])
        XCTAssertEqual(Containers.parsePorts(""), [])
    }

    func testMapsAPortInARangeToItsPortInside() {
        XCTAssertEqual(containers[2].containerPort(for: 8080), 80)
        XCTAssertEqual(containers[2].containerPort(for: 8082), 82)
        XCTAssertNil(containers[2].containerPort(for: 8083))
        XCTAssertNil(containers[2].containerPort(for: 9229))
    }

    func testRecognisesRuntimesThatForwardPorts() {
        XCTAssertEqual(ContainerRuntime.detect(executable: backend, process: "com.docker.backend", command: nil), .docker)
        XCTAssertEqual(ContainerRuntime.detect(executable: nil, process: "com.docker.backend", command: nil), .docker)
        XCTAssertEqual(ContainerRuntime.detect(executable: "/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper", process: "OrbStack Helper", command: nil), .orbstack)
        XCTAssertEqual(ContainerRuntime.detect(executable: "/opt/homebrew/bin/gvproxy", process: "gvproxy", command: nil), .podman)
        XCTAssertEqual(ContainerRuntime.detect(executable: "/opt/homebrew/bin/limactl", process: "limactl",
                                               command: "limactl hostagent --pidfile /Users/sam/.lima/default/ha.pid default"), .lima)
        XCTAssertEqual(ContainerRuntime.detect(executable: "/opt/homebrew/bin/limactl", process: "limactl",
                                               command: "limactl hostagent --pidfile /Users/sam/.colima/_lima/colima/ha.pid colima"), .colima)
        XCTAssertEqual(ContainerRuntime.detect(executable: "/usr/bin/ssh", process: "ssh",
                                               command: "ssh: /Users/sam/.colima/_lima/colima/ssh.sock [mux]"), .colima)
        XCTAssertEqual(ContainerRuntime.detect(executable: "/usr/bin/ssh", process: "ssh",
                                               command: "ssh: /Users/sam/.lima/default/ssh.sock [mux]"), .lima)
        // An ordinary ssh tunnel, the Docker window and a dev server are not runtimes.
        XCTAssertNil(ContainerRuntime.detect(executable: "/usr/bin/ssh", process: "ssh", command: "ssh -L 5432:db:5432 bastion"))
        XCTAssertNil(ContainerRuntime.detect(executable: "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop",
                                             process: "Docker Desktop", command: nil))
        XCTAssertNil(ContainerRuntime.detect(executable: "/opt/homebrew/bin/node", process: "node", command: "node server.js"))
        XCTAssertEqual(ContainerRuntime.docker.cli, "docker")
        XCTAssertEqual(ContainerRuntime.orbstack.cli, "docker")
        XCTAssertEqual(ContainerRuntime.podman.cli, "podman")
        XCTAssertNil(ContainerRuntime.lima.cli)
    }

    private func forwarded(_ port: Int, hosts: [String] = ["*"], runtime: ContainerRuntime = .docker) -> PortEntry {
        PortEntry(port: port, pid: 2210, process: "com.docker.backend", hosts: hosts, executable: backend, directory: "/code/my-shop", runtime: runtime)
    }

    func testNamesTheContainerBehindAPort() {
        let node = PortEntry(port: 8080, pid: 7, process: "node", executable: "/opt/homebrew/bin/node")
        let entries = Containers.attach(["docker": containers],
                                        to: [forwarded(5433), forwarded(6379, hosts: ["127.0.0.1"]), forwarded(8081), forwarded(4000), node,
                                             forwarded(8025, runtime: .podman), forwarded(9153, runtime: .lima)])
        XCTAssertEqual(entries[0].container?.name, "shop-db")
        XCTAssertEqual(entries[0].container?.image, "postgres:17")
        XCTAssertEqual(entries[0].container?.containerPort, 5432)
        XCTAssertEqual(entries[0].displayName, "shop-db")
        XCTAssertEqual(entries[2].container?.name, "shop-web-1")
        XCTAssertEqual(entries[2].container?.containerPort, 81)
        // No container published 4000, so the row can only say it is a container's port.
        XCTAssertNil(entries[3].container)
        XCTAssertEqual(entries[3].displayName, "Docker")
        // A process that is not a runtime is never matched, even on a port a container also uses.
        XCTAssertNil(entries[4].container)
        // podman was not asked and Lima has nothing to ask.
        XCTAssertNil(entries[5].container)
        XCTAssertNil(entries[6].container)

        // A port published on loopback from inside an app would be hidden as noise; a container's is not.
        XCTAssertTrue(forwarded(6379, hosts: ["127.0.0.1"]).isBackground)
        XCTAssertFalse(entries[1].isBackground)
        // What is served is decided by the port inside: Postgres on 5433 is still not for a browser.
        XCTAssertNil(entries[0].url)
        XCTAssertNotNil(entries[2].url)
    }

    func testAContainerRowNeverSignalsTheRuntime() {
        let known = Containers.attach(["docker": containers], to: [forwarded(5433)])[0]
        guard case .container(let container) = known.stopAction else { return XCTFail("expected a container to stop") }
        XCTAssertEqual(container.name, "shop-db")
        XCTAssertEqual(forwarded(4000).stopAction, .nothing)
        XCTAssertEqual(PortEntry(port: 3000, pid: 7, process: "node").stopAction, .signal)

        // Nor does it join a project, so Stop all cannot reach the runtime either.
        XCTAssertNil(forwarded(4000).project)
        XCTAssertFalse(Projects.belongsToProject(forwarded(4000)))
        XCTAssertEqual(Projects.stopTargets(directory: "/code/my-shop", in: [forwarded(4000), known], own: 1), [])

        // And the command line tool refuses, without sending anything.
        XCTAssertEqual(PortKiller.free(port: 4000, force: true, entries: [forwarded(4000)], holders: { _ in [2210] }), .runtimeOnly(forwarded(4000)))
    }

    func testStopsAContainerByItsIdOnly() {
        XCTAssertEqual(Containers.stopArguments(id: "3f2a9c1d7b0e", force: false) ?? [], ["stop", "3f2a9c1d7b0e"])
        XCTAssertEqual(Containers.stopArguments(id: "3f2a9c1d7b0e", force: true) ?? [], ["kill", "3f2a9c1d7b0e"])
        XCTAssertNil(Containers.stopArguments(id: "", force: false))
        XCTAssertNil(Containers.stopArguments(id: "--all", force: false))
        XCTAssertNil(Containers.stopArguments(id: "abc def", force: false))
    }

    func testFindsTheToolWhereAnAppWouldNotLook() {
        let installed: Set<String> = ["/opt/homebrew/bin/docker", "/Users/sam/.orbstack/bin/docker", "/opt/podman/bin/podman"]
        let exists: (String) -> Bool = { installed.contains($0) }
        // An app's PATH has none of the places a shell adds.
        XCTAssertEqual(Containers.locate("docker", path: "/usr/bin:/bin", home: "/Users/sam", isExecutable: exists), "/opt/homebrew/bin/docker")
        XCTAssertEqual(Containers.locate("docker", path: "/Users/sam/.orbstack/bin:/usr/bin", home: "/Users/sam", isExecutable: exists), "/Users/sam/.orbstack/bin/docker")
        XCTAssertEqual(Containers.locate("podman", path: nil, home: "/Users/sam", isExecutable: exists), "/opt/podman/bin/podman")
        XCTAssertNil(Containers.locate("nerdctl", path: "/usr/bin:relative/bin", home: "/Users/sam", isExecutable: exists))
    }

    func testAContainerRowShowsImageAndStatus() {
        let known = Containers.attach(["docker": containers], to: [forwarded(5433)])[0].details
        XCTAssertEqual(known.headline, "postgres:17")
        XCTAssertEqual(known.facts, "Up 2 hours · port 5432 in the container")
        XCTAssertEqual(known.copies.map(\.title), ["Copy address", "Copy name"])
        XCTAssertEqual(known.copies.map(\.text), ["http://localhost:5433", "shop-db"])

        let unknown = forwarded(4000).details
        XCTAssertNil(unknown.headline)
        XCTAssertEqual(unknown.facts, "Forwarded by Docker. The container is not known.")
        XCTAssertEqual(unknown.copies.map(\.title), ["Copy address"])
    }
}
