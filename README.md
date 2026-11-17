<p align="center">
  <img src="docs/icon.png" width="128" alt="Portpeek icon">
</p>

<h1 align="center">Portpeek</h1>

<p align="center">
  See what is listening on your ports, from a corner of the screen.<br>
  Push the pointer into the corner. Kill what should not be there.
</p>

<p align="center">
  <a href="https://github.com/BRIJRAJ-02/portpeek/actions/workflows/ci.yml"><img src="https://github.com/BRIJRAJ-02/portpeek/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-native-black" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-black" alt="MIT">
</p>

<p align="center">
  <img src="docs/open.png" width="470" alt="The Portpeek panel in the top right corner listing ports 3000, 5173, 5432, 6379 and 8000 with the process and project behind each">
</p>

## What it does

`Error: listen EADDRINUSE: address already in use :::3000`. Then a search for the `lsof` incantation, a PID, a `kill`. Portpeek is that, without the terminal.

- **Lives in a corner.** Any of the four. Push the pointer into it and the list opens; move away and it closes.
- **Says whose port it is.** Each row shows the port, the process, and the folder it was started in, so two `node` servers read as `portfolio` and `dashboard`.
- **Kills in one click.** *Kill* asks the process to quit. If it is still there a couple of seconds later, the button becomes *Force*.
- **Opens in the browser.** One click to `localhost:<port>`, offered for everything except databases and caches.
- **Hides the noise.** AirPlay, Handoff and app helpers on random ports are tucked behind *Show in the background*.
- **Costs nothing while closed.** No menu bar icon, no Dock icon, and it only scans while the panel is open.

<p align="center">
  <img src="docs/stubborn.png" width="470" alt="A row whose Kill button has turned into a red Force button after the process ignored the first request">
</p>

## Install

### Download

Get `Portpeek-x.y.z.dmg` from the [latest release](https://github.com/BRIJRAJ-02/portpeek/releases/latest), open it and drag Portpeek to Applications. It runs on Apple Silicon and Intel, macOS 14 or later.

The app is not notarized, so macOS blocks the first launch. Either allow it under System Settings → Privacy & Security → Open Anyway, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Portpeek.app
```

### Build from source

Requires Xcode 16 or later (for the Swift toolchain).

```bash
git clone https://github.com/BRIJRAJ-02/portpeek.git
cd portpeek
./scripts/build-app.sh --install   # builds, copies Portpeek.app to /Applications, launches it
```

## Using it

| Do this | To |
|---|---|
| Push the pointer into the corner | Open the list |
| Move away | Close it |
| Click the arrow | Open `localhost:<port>` in the browser |
| Click *Kill* | Ask the process to quit |
| Click *Force* | Stop a process that ignored *Kill* |
| Click *Show … in the background* | Include system services and app helpers |
| Right-click the panel, or click ⋯ | Corner, Show Background Ports, Launch at Login, Quit |
| Open Portpeek again from Spotlight | Show the panel, if you forget which corner it is in |

It starts in the top right corner. If you use a macOS Hot Corner there, pick a different corner for one of them.

The panel sits clear of the menu bar and the Dock. With more than one display, the same corner works on each.

Services managed by Homebrew or launchd, such as Postgres, are restarted by their manager after you kill them. Stop those with `brew services stop`.

## Design notes

- **A corner is the largest target on a screen.** The pointer cannot overshoot it, so there is nothing to aim at.
- **Nothing until asked.** No icon, no badge, no window. The panel grows out of the corner it lives in and shrinks back into it.
- **A beat before opening.** A pointer thrown at the corner on its way somewhere else does not trigger it.
- **Polite first.** *Kill* sends SIGTERM so servers can clean up. SIGKILL is offered only after that has failed.
- **Color means something.** Green is listening. Red is the destructive button, and only under the pointer.
- **Numbers that hold still.** Ports and PIDs use tabular digits.
- **Click-through.** The window ignores the mouse everywhere outside the visible panel.

## How it is built

```
Sources/
  PortpeekCore/   UI-free scanner: parses lsof and ps, classifies entries, sends signals
  Portpeek/       the panel: corner tracking, window placement, SwiftUI views
Tests/            parsing, classification, a real listening socket, a real process being stopped
scripts/          build-app.sh bundles the app and the DMG; make-icon.swift draws the icon in code
```

Where the list comes from:

| Reading | Source |
|---|---|
| Listening sockets | `lsof -iTCP -sTCP:LISTEN` |
| Project folder | each process's working directory, from `lsof -d cwd` |
| App and system detection | the executable path, from `ps` |

Portpeek sees the processes your user owns, which is what a dev machine runs. It needs no special permissions, and nothing leaves your Mac.

### Developing

```bash
swift build && swift test       # or open Package.swift in Xcode
./scripts/build-app.sh --open   # build and launch the app bundle
./scripts/build-app.sh --dmg    # universal build, packaged as build/Portpeek-<version>.dmg
.build/debug/Portpeek --snapshot docs   # re-render the README screenshots with sample data
```

## License

[MIT](LICENSE)
