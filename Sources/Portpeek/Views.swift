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
    static let maxRows = 8
    static let margin: CGFloat = 36        // room for the shadow
    static let inset: CGFloat = 6          // gap between the panel and the screen edge

    static func listHeight(rows: Int) -> CGFloat {
        rows == 0 ? empty : CGFloat(min(rows, maxRows)) * row
    }

    static func height(rows: Int, hint: Bool) -> CGFloat {
        header + listHeight(rows: rows) + footer + (hint ? Metrics.hint : 0) + 2
    }

    static let maxHeight = height(rows: maxRows, hint: true)
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
    let onOpen: () -> Void
    let onStop: () -> Void
    @State private var hovering = false
    @Environment(\.isSnapshot) private var isSnapshot

    private var detail: String {
        var parts: [String] = []
        if let project = entry.project { parts.append(project) }
        if entry.appName != nil, entry.process != entry.displayName { parts.append(entry.process) }
        parts.append("pid \(entry.pid)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(entry.port)")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
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
                Button(action: onStop) {
                    Text(stubborn ? "Force" : "Kill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(hovering || stubborn ? Tone.danger : .white.opacity(0.6))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(hovering || stubborn ? Tone.danger.opacity(0.18) : .white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(stubborn ? "Force quit" : "Quit") \(entry.displayName) on port \(entry.port)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.row)
        .background {
            ZStack {
                Color.white.opacity(hovering ? 0.07 : 0)
                if !isSnapshot { HoverSensor { hovering = $0 } }
            }
        }
        .opacity(stopping ? 0.55 : 1)
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
        VStack(spacing: 0) {
            header(count: rows.count)
            hairline
            if rows.isEmpty {
                Text(model.loaded ? "Nothing is listening." : "Looking…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.empty)
            } else if rows.count > Metrics.maxRows, !isSnapshot {
                ScrollView(.vertical, showsIndicators: false) { list(rows) }
                    .frame(height: Metrics.listHeight(rows: rows.count))
            } else {
                list(rows)
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

    private func list(_ rows: [PortEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { entry in
                PortRow(entry: entry,
                        stopping: model.stopping.contains(entry.pid),
                        stubborn: model.stubborn.contains(entry.pid),
                        onOpen: { model.open(entry) },
                        onStop: { model.stop(entry) })
            }
        }
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
            .ignoresSafeArea()
    }
}
