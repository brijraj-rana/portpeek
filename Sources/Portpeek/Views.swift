import AppKit
import PortpeekCore
import SwiftUI

// MARK: Geometry

enum Corner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    var anchor: UnitPoint {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

enum Metrics {
    static let width: CGFloat = 320
    static let header: CGFloat = 38
    static let row: CGFloat = 46
    static let footer: CGFloat = 34
    static let empty: CGFloat = 74
    static let hint: CGFloat = 46
    static let heading: CGFloat = 30      // a project's name above its ports
    static let groupGap: CGFloat = 4       // air above and below a project
    static let groupInset: CGFloat = 6     // a project sits this far in from the panel's edges
    static let padding: CGFloat = 14       // the panel's left and right padding
    static let maxRows = 8
    static let margin: CGFloat = 36        // room for the shadow
    static let inset: CGFloat = 6          // gap between the panel and the screen edge

    static let maxList = CGFloat(maxRows) * row

    /// What the list would measure with nothing cut off. One row may be open, showing its details.
    static func contentHeight(_ sections: [PortSection], expanded: PortEntry? = nil) -> CGFloat {
        let rows = sections.reduce(0) { total, section in
            switch section {
            case .row: return total + row
            case .project(let group): return total + heading + CGFloat(group.entries.count) * row + groupGap * 2
            }
        }
        return rows + (expanded.map { detailHeight($0.details) } ?? 0)
    }

    // An open row's details: a command line, a line of facts, a line of things to copy.
    static let detailWidth = width - padding * 2
    static let commandFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let commandLine: CGFloat = 14
    static let commandLines = 3            // a longer command is cut short here; Copy command still has all of it
    static let factsLine: CGFloat = 14
    static let copyLine: CGFloat = 16
    static let detailGap: CGFloat = 6
    static let detailBottom: CGFloat = 12

    /// How tall a command is when wrapped to the panel, measured the way it will be drawn.
    static func commandHeight(_ text: String) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = commandLine
        style.maximumLineHeight = commandLine
        style.lineBreakMode = .byWordWrapping
        let box = (text as NSString).boundingRect(with: CGSize(width: detailWidth, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin],
                                                  attributes: [.font: commandFont, .paragraphStyle: style])
        let lines = max(1, min(commandLines, Int((box.height / commandLine).rounded())))
        return CGFloat(lines) * commandLine
    }

    static func detailHeight(_ details: PortDetails) -> CGFloat {
        var parts: [CGFloat] = []
        if let headline = details.headline { parts.append(commandHeight(headline)) }
        if details.facts != nil { parts.append(factsLine) }
        if !details.copies.isEmpty { parts.append(copyLine) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * detailGap + detailBottom
    }

    static func listHeight(content: CGFloat) -> CGFloat {
        content == 0 ? empty : min(content, maxList)
    }

    static func height(content: CGFloat, hint: Bool) -> CGFloat {
        header + listHeight(content: content) + footer + (hint ? Metrics.hint : 0) + 2
    }

    static let maxHeight = height(content: maxList, hint: true)
    static let windowSize = CGSize(width: width + margin * 2, height: maxHeight + margin * 2)
}

final class PanelState: ObservableObject {
    @Published var open = false
    @Published var corner: Corner = .topRight
    @Published var hint = false            // first run: explain how to summon it
}

enum Tone {
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.33)
    static let live = Color(red: 0.42, green: 0.90, blue: 0.62)
}

enum Motion {
    /// For small changes of state under the pointer. Nothing moves when Reduce Motion is on.
    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.15)
    }
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering README images, where AppKit-backed views cannot be drawn.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

// MARK: Hover

/// SwiftUI's onHover goes quiet in a panel that never becomes key, so hover is tracked with AppKit instead.
struct HoverSensor: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> SensorView { SensorView() }
    func updateNSView(_ view: SensorView, context: Context) { view.onChange = onChange }

    final class SensorView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { onChange(false) }
        }
    }
}

/// Clicks on buttons should land even though the app is in the background.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: Rows

struct PortRow: View {
    let entry: PortEntry
    let stopping: Bool
    let stubborn: Bool
    var grouped = false                    // under a project heading, which already names the folder
    var expanded = false                   // showing its details underneath
    let onOpen: () -> Void
    let onStop: () -> Void
    var onOrigin: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onToggle: () -> Void = {}
    var onCopy: (String) -> Void = { _ in }
    @State private var hovering = false
    @Environment(\.isSnapshot) private var isSnapshot

    private var detail: String {
        // A container's port is held by its runtime, whose pid says nothing about the container.
        if let container = entry.container { return "\(container.image) · \(container.runtime.name)" }
        var parts: [String] = []
        if entry.runtime != nil {
            parts.append("container")
        } else {
            if !grouped, let project = entry.project { parts.append(project) }
            if entry.appName != nil, entry.process != entry.displayName { parts.append(entry.process) }
        }
        parts.append("pid \(entry.pid)")
        return parts.joined(separator: " · ")
    }

    /// What the red button says, or nil when there is nothing safe for it to do.
    private var stopTitle: String? {
        switch entry.stopAction {
        case .signal: return stubborn ? "Force" : "Kill"
        // Short, so a container's name has room. The row is named after the container, which says what stops.
        case .container: return "Stop"
        case .nothing: return nil
        }
    }

    private var stopLabel: String {
        switch entry.stopAction {
        case .container(let container): return "Stop container \(container.name) on port \(entry.port)"
        default: return "\(stubborn ? "Force quit" : "Quit") \(entry.displayName) on port \(entry.port)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(expanded ? "Hides the details" : "Shows the command, uptime and memory")
            if expanded {
                RowDetails(details: entry.details, onCopy: onCopy)
                    .padding(.horizontal, grouped ? Metrics.padding - Metrics.groupInset : Metrics.padding)
            }
        }
        .background {
            ZStack {
                Color.white.opacity(hovering ? 0.07 : expanded ? 0.04 : 0)
                if !isSnapshot {
                    HoverSensor {
                        hovering = $0
                        onHover($0)
                    }
                }
            }
        }
        .opacity(stopping ? 0.55 : 1)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(entry.port)")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if let origin = entry.startedFrom {
                        // Kept whole: a long process name gives way before this does.
                        OriginLabel(origin: origin, action: onOrigin)
                            .layoutPriority(1)
                    }
                }
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if stopping {
                Text("Stopping")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                if entry.url != nil {
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                            .frame(width: 24, height: 22)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open localhost \(entry.port) in the browser")
                }
                if let stopTitle {
                    Button(action: onStop) {
                        Text(stopTitle)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(hovering || stubborn ? Tone.danger : .white.opacity(0.6))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(hovering || stubborn ? Tone.danger.opacity(0.18) : .white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(stopLabel)
                }
            }
        }
        .padding(.horizontal, grouped ? Metrics.padding - Metrics.groupInset : Metrics.padding)
        .frame(height: Metrics.row)
    }
}

/// Under an open row: the command line, how long it has been up and how much memory it holds, and things to copy.
struct RowDetails: View {
    let details: PortDetails
    let onCopy: (String) -> Void
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.detailGap) {
            if let headline = details.headline {
                Text(headline)
                    .font(Font(Metrics.commandFont))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(Metrics.commandLines)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(width: Metrics.detailWidth, height: Metrics.commandHeight(headline), alignment: .topLeading)
            }
            if let facts = details.facts {
                Text(facts)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(height: Metrics.factsLine)
            }
            if !details.copies.isEmpty {
                HStack(spacing: 12) {
                    Text("Copy")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .accessibilityHidden(true)
                    ForEach(details.copies) { copy in
                        CopyButton(word: copy.word, title: copy.title, done: copied == copy.id) {
                            onCopy(copy.text)
                            copied = copy.id
                            // Long enough to read, then back to what it does.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                if copied == copy.id { copied = nil }
                            }
                        }
                    }
                }
                .frame(height: Metrics.copyLine)
            }
        }
        .frame(width: Metrics.detailWidth, height: Metrics.detailHeight(details) - Metrics.detailBottom, alignment: .topLeading)
        .padding(.bottom, Metrics.detailBottom)
    }
}

/// Words that copy something, in the manner of the footer: quiet until the pointer is on them.
struct CopyButton: View {
    let word: String
    let title: String                      // the whole of it, for VoiceOver
    let done: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            // The word keeps its place so the line does not shift when it says Copied.
            Text(word)
                .opacity(done ? 0 : 1)
                .overlay(alignment: .leading) { Text("Copied").fixedSize().opacity(done ? 1 : 0) }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering || done ? 0.95 : 0.6))
                .lineLimit(1)
                .fixedSize()
                .frame(height: Metrics.copyLine)
                .contentShape(Rectangle())
                .background { if !isSnapshot { HoverSensor { hovering = $0 } } }
        }
        .buttonStyle(.plain)
        .animation(Motion.quick(reduceMotion), value: hovering)
        .animation(Motion.quick(reduceMotion), value: done)
        .accessibilityLabel(title)
    }
}

/// "from Cursor": where the server was started. Clicking it brings that app forward.
struct OriginLabel: View {
    let origin: Origin
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: some View {
        Text(origin.label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.45))
            .lineLimit(1)
            .frame(maxWidth: 96, alignment: .leading)
            .fixedSize()
    }

    var body: some View {
        if origin.canActivate {
            Button(action: action) {
                text
                    .contentShape(Rectangle())
                    .background { if !isSnapshot { HoverSensor { hovering = $0 } } }
            }
            .buttonStyle(.plain)
            .animation(Motion.quick(reduceMotion), value: hovering)
            .accessibilityLabel("Started from \(origin.name). Bring it forward")
        } else {
            text
        }
    }
}

/// The name of a project above its ports, with one button to stop them all.
struct ProjectHeading: View {
    let group: ProjectGroup
    let stopping: Bool
    let onStopAll: () -> Void
    @State private var hovering = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(group.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)

            if stopping {
                Text("Stopping")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Button(action: onStopAll) {
                    Text("Stop all")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(hovering ? Tone.danger : .white.opacity(0.6))
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(hovering ? Tone.danger.opacity(0.18) : .white.opacity(0.1)))
                        .background { if !isSnapshot { HoverSensor { hovering = $0 } } }
                }
                .buttonStyle(.plain)
                .animation(Motion.quick(reduceMotion), value: hovering)
                .accessibilityLabel("Stop every port in \(group.name)")
            }
        }
        .padding(.horizontal, Metrics.padding - Metrics.groupInset)
        .frame(height: Metrics.heading)
    }
}

// MARK: Panel

struct PanelView: View {
    @ObservedObject var model: PortsModel
    let hint: Bool
    let onMenu: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let rows = model.visible
        let sections = Projects.sections(rows)
        let content = Metrics.contentHeight(sections, expanded: rows.first { $0.id == model.expanded })
        VStack(spacing: 0) {
            header(count: rows.count)
            hairline
            if rows.isEmpty {
                Text(model.loaded ? "Nothing is listening." : "Looking…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.empty)
            } else if content > Metrics.maxList, !isSnapshot {
                ScrollView(.vertical, showsIndicators: false) { list(sections) }
                    .frame(height: Metrics.listHeight(content: content))
            } else {
                list(sections)
            }
            hairline
            footer
            if hint {
                Text("Push the pointer into this corner to see your ports.\nRight-click here to move it to another corner.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.hint)
                    .background(.white.opacity(0.06))
            }
        }
        .frame(width: Metrics.width)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var hairline: some View {
        Color.white.opacity(0.08).frame(height: 1)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("PORTS")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .contentTransition(.numericText())
            Spacer()
            if count > 0 {
                Circle().fill(Tone.live).frame(width: 5, height: 5)
                Text("listening")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.header)
    }

    private func list(_ sections: [PortSection]) -> some View {
        VStack(spacing: 0) {
            ForEach(sections) { section in
                switch section {
                case .row(let entry):
                    row(entry, grouped: false)
                case .project(let group):
                    VStack(spacing: 0) {
                        ProjectHeading(group: group,
                                       stopping: group.entries.allSatisfy { model.stopping.contains($0.pid) },
                                       onStopAll: { model.stopAll(group) })
                        ForEach(group.entries) { entry in
                            row(entry, grouped: true)
                        }
                    }
                    .background(.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, Metrics.groupInset)
                    .padding(.vertical, Metrics.groupGap)
                }
            }
        }
    }

    private func row(_ entry: PortEntry, grouped: Bool) -> some View {
        PortRow(entry: entry,
                stopping: model.isStopping(entry),
                stubborn: model.stubborn.contains(entry.pid) && entry.stopAction == .signal,
                grouped: grouped,
                expanded: model.expanded == entry.id,
                onOpen: { model.open(entry) },
                onStop: { model.stop(entry) },
                onOrigin: { model.showOrigin(of: entry) },
                onHover: { model.hover(entry, $0) },
                onToggle: { model.toggle(entry) },
                onCopy: { model.copy($0) })
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                model.showBackground.toggle()
            } label: {
                Text(model.showBackground ? "Hide background ports" : "Show \(model.backgroundCount) in the background")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(height: Metrics.footer)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(model.backgroundCount > 0 || model.showBackground ? 1 : 0)

            Spacer()

            Button(action: onMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 30, height: Metrics.footer)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Options")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: Metrics.footer)
    }
}

// MARK: Root

struct RootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var model: PortsModel
    let onMenu: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelView(model: model, hint: state.hint, onMenu: onMenu)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            // The panel grows out of the corner it lives in.
            .scaleEffect(state.open || reduceMotion ? 1 : 0.86, anchor: state.corner.anchor)
            .opacity(state.open ? 1 : 0)
            .padding(Metrics.margin)
            .frame(width: Metrics.windowSize.width, height: Metrics.windowSize.height, alignment: state.corner.alignment)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.84), value: state.open)
            .animation(.easeOut(duration: 0.18), value: model.visible.map(\.id))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.expanded)
            .ignoresSafeArea()
    }
}
