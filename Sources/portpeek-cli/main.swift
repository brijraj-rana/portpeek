import Darwin
import Foundation
import PortpeekCore

// The `portpeek` command: the same scanner as the panel, for a terminal or a script.

func finish(_ code: CLI.ExitCode) -> Never {
    exit(code.rawValue)
}

func complain(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let command: CLI.Command
do {
    command = try CLI.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLI.UsageError {
    complain(error.message + " See portpeek --help.")
    finish(.usage)
} catch {
    finish(.usage)
}

switch command {
case .help:
    print(CLI.help)

case .version:
    print("portpeek \(PortpeekVersion.current)")

case .list(let all, let json):
    let entries = PortScanner.scan()
    let shown = all ? entries : entries.filter { !$0.isBackground }
    print(json ? CLI.json(shown) : CLI.table(shown))
    let hidden = entries.count - shown.count
    if hidden > 0, !json {
        // Not part of the table, so it does not end up in a pipe.
        complain("\(hidden) more in the background. See them with --all.")
    }

case .show(let port, let json):
    let holders = PortScanner.scan().filter { $0.port == port }
    print(json ? CLI.json(holders) : CLI.describe(holders, port: port))
    if holders.isEmpty { finish(.notListening) }

case .kill(let port, let force):
    let outcome = PortKiller.free(port: port, force: force)
    let code = PortKiller.exitCode(outcome)
    if code == .ok {
        print(PortKiller.message(outcome, port: port))
    } else {
        complain(PortKiller.message(outcome, port: port))
    }
    finish(code)
}
finish(.ok)
