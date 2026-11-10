import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
@Observable
final class DictationDisplayState {
    var levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
}

private struct DictationWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [Float]
    let compact: Bool

    var body: some View {
        HStack(
            alignment: .center,
            spacing: compact ? Theme.Spacing.dictationWaveGap : Theme.Spacing.dictationLabelWaveGap
        ) {
            ForEach(levels.indices, id: \.self) { index in
                let restingHeight: CGFloat = index == levels.count / 2 ? 7 : 6
                Capsule()
                    .fill(.foreground)
                    .frame(
                        width: Theme.Size.dictationWaveBar,
                        height: restingHeight + 10 * CGFloat(levels[index]))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: levels)
    }
}

struct DictationIndicatorView: View {
    enum Phase {
        case starting
        case listening
        case transcribing([String])

        static func randomTranscribing(cycling: Bool = false) -> Self {
            if cycling { return .transcribing(processingLabels.shuffled()) }
            return .transcribing([processingLabels[Int.random(in: processingLabels.indices)]])
        }

        private static let processingLabels = [
            String(localized: "Unspooling"),
            String(localized: "Stitching"),
            String(localized: "Noodling"),
            String(localized: "Sifting"),
            String(localized: "Tinkering"),
            String(localized: "Brewing"),
            String(localized: "Untangling"),
            String(localized: "Tuning"),
            String(localized: "Typesetting"),
            String(localized: "Polishing")
        ]
    }

    let style: DictationIndicatorStyle
    let phase: Phase
    var levels: [Float] = []

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            switch phase {
            case .starting:
                DictationProcessingRing(ink: ink)
                Text("Starting…")
            case .listening:
                DictationWaveform(levels: listeningLevels, compact: style.isCompact)
                if !style.isCompact { Text("Listening") }
            case .transcribing(let titles):
                DictationProcessingRing(ink: ink)
                if !style.isCompact { DictationTranscribingLabel(titles: titles, ink: ink) }
            }
        }
        .font(Theme.Typography.panelTitle)
        .padding(.horizontal, Theme.Spacing.dictationWaveInset)
        .frame(height: Theme.Size.dictationIndicatorHeight)
        .background(background, in: shape)
        .overlay {
            if outlined {
                shape.stroke(Theme.Colors.dictationOutline, lineWidth: Theme.Size.dictationOutlineWidth)
            }
        }
        .fixedSize()
        .foregroundStyle(ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityStatus)
    }

    private var accessibilityStatus: Text {
        switch phase {
        case .starting: Text("Starting…")
        case .listening: Text("Dictation listening")
        case .transcribing: Text("Transcribing dictation")
        }
    }

    private var shape: some InsettableShape {
        let base = switch style {
        case .lightRounded, .darkRounded, .outlinedRounded:
            RoundedRectangle(cornerRadius: Theme.Radius.card)
        default:
            RoundedRectangle(cornerRadius: Theme.Size.dictationIndicatorHeight / 2, style: .circular)
        }
        return base.inset(by: outlined ? Theme.Size.dictationOutlineWidth / 2 : 0)
    }

    private var ink: Color {
        switch style {
        case .lightCompact, .lightCapsule, .lightRounded: Theme.Colors.dictationLightInk
        default: Theme.Colors.dictationDarkInk
        }
    }

    private var background: Color {
        switch style {
        case .lightCompact, .lightCapsule, .lightRounded: Theme.Colors.dictationLightBackground
        case .darkCapsule, .darkRounded: Theme.Colors.dictationDarkBackground
        default: Theme.Colors.dictationBackground
        }
    }

    private var outlined: Bool {
        style == .outlinedCapsule || style == .outlinedRounded
    }

    private var listeningLevels: [Float] {
        let barCount = Theme.Size.dictationWaveBarCount
        let peaks = (0..<barCount).map { index in
            let start = index * levels.count / barCount
            let end = (index + 1) * levels.count / barCount
            return levels[start..<end].max() ?? 0
        }
        let smoothed = peaks.indices.map { index in
            let left = peaks[max(0, index - 1)]
            let right = peaks[min(peaks.count - 1, index + 1)]
            return (left + 2 * peaks[index] + right) / 4
        }
        guard !style.isCompact else { return smoothed }
        let visibleCount = Theme.Size.dictationLabelWaveBarCount
        let inset = (barCount - visibleCount) / 2
        return (0..<visibleCount).map { index in
            let start = index == 0 ? 0 : index + inset
            let end = index == visibleCount - 1 ? barCount : index + inset + 1
            return smoothed[start..<end].max() ?? 0
        }
    }
}

private struct DictationProcessingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ink: Color

    private var animates: Bool { !reduceMotion && Motion.isEnabled }

    var body: some View {
        let diameter = Theme.Size.dictationSpinnerDiameter
        let stroke = Theme.Size.dictationWaveBar
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animates)) { _ in
            let turns = ProcessInfo.processInfo.systemUptime / Theme.Duration.dictationSpinnerRotation
            let angle = animates ? turns.truncatingRemainder(dividingBy: 1) * 360 : 0
            Circle()
                .strokeBorder(ink.opacity(0.14), lineWidth: stroke)
                .overlay {
                    Circle()
                        .trim(from: 0, to: 0.36)
                        .stroke(ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .padding(stroke / 2)
                        .rotationEffect(.degrees(angle - 90))
                }
                .frame(width: diameter, height: diameter)
        }
    }
}

private struct DictationTranscribingLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    let titles: [String]
    let ink: Color

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(titles.indices, id: \.self) { index in
                Text(verbatim: titles[index]).hidden()
            }
            label
        }
        .task {
            guard titles.count > 1 else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(Theme.Duration.dictationProcessingWord))
                    try Task.checkCancellation()
                    index = (index + 1) % titles.count
                }
            } catch {
                return
            }
        }
    }

    @ViewBuilder private var label: some View {
        let label = Text(verbatim: titles[index])
        if reduceMotion || !Motion.isEnabled {
            label
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let period = Theme.Duration.dictationTranscribingShimmer
                let elapsed = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                let center = 1.6 * elapsed / period - 0.3
                label
                    .foregroundStyle(
                        LinearGradient(
                            colors: [ink.opacity(0.72), ink, ink.opacity(0.72)],
                            startPoint: UnitPoint(x: center - 0.3, y: 0.5),
                            endPoint: UnitPoint(x: center + 0.3, y: 0.5)))
            }
        }
    }
}

private struct DictationPanelView: View {
    let state: DictationDisplayState
    let style: DictationIndicatorStyle
    var phase: DictationIndicatorView.Phase

    var body: some View {
        DictationIndicatorView(style: style, phase: phase, levels: state.levels)
            .motionScope()
    }
}

private final class DictationPanel: NSPanel, AnimatedPanel {
    private let host: NSHostingView<DictationPanelView>
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?

    init(rootView: DictationPanelView) {
        let host = NSHostingView(rootView: rootView)
        self.host = host
        super.init(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .darkAqua)
        contentView = host
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        followMotion()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(_ phase: DictationIndicatorView.Phase) {
        let previous = frame
        host.rootView.phase = phase
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setFrame(
            NSRect(
                x: previous.midX - size.width / 2, y: previous.minY,
                width: size.width, height: size.height),
            display: true)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: onAccept?(); return
            case kVK_Escape: onCancel?(); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class DictationPanelController {
    let state = DictationDisplayState()
    private var panel: DictationPanel?
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?

    func showStarting(style: DictationIndicatorStyle) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        state.levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
        let panel = DictationPanel(rootView: DictationPanelView(state: state, style: style, phase: .starting))
        panel.onAccept = onAccept
        panel.onCancel = onCancel
        self.panel = panel
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY + Theme.Spacing.dictationPanelBottomInset))
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func showListening() { panel?.show(.listening) }

    func showTranscribing() { panel?.show(.randomTranscribing(cycling: true)) }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
