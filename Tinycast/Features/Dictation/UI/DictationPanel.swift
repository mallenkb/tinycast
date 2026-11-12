import AppKit
import Carbon.HIToolbox
import CoreText
import SwiftUI

private extension DictationIndicatorStyle {
    var backgroundColor: Color {
        isDark ? Theme.Colors.dictationDarkBackground : Theme.Colors.dictationLightBackground
    }
}

@MainActor
@Observable
final class DictationDisplayState {
    var transcript = ""
    var previewPaused = false
    var animatesTranscript = true
    var twoLinePreview = false
    var idleHovered = false
    var indicatorWidth: CGFloat = 0
    var indicatorOffset: CGFloat = 0
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
                Capsule(style: .circular)
                    .fill(.foreground)
                    .frame(
                        width: Theme.Size.dictationWaveBar,
                        height: restingHeight + 10 * CGFloat(levels[index]))
                    .fixedSize()
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: levels)
    }
}

struct DictationIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentReady = false
    @State private var processingIndex = 0
    @State private var processingWidths: [String: CGFloat] = [:]

    enum Phase {
        case idle
        case starting
        case listening
        case transcribing([String])

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

        var isTranscribing: Bool {
            if case .transcribing = self { return true }
            return false
        }

        static func randomTranscribing() -> Self {
            .transcribing(processingLabels.shuffled())
        }

        fileprivate static let processingLabels = [
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
    var idleHovered = false
    var onStart: () -> Void = {}

    private var morphAnimation: Animation? {
        reduceMotion || !Motion.isEnabled ? nil : .easeInOut(duration: Theme.Duration.dictationIndicatorMorph)
    }

    private var processingTitles: [String] {
        guard case .transcribing(let titles) = phase, !style.isCompact else { return [] }
        return titles
    }

    var body: some View {
        let titles = processingTitles
        HStack(spacing: Theme.Spacing.xl) {
            switch phase {
            case .idle:
                Group {
                    if idleHovered {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(Theme.Colors.dictationDarkInk)
                    } else {
                        Color.clear
                    }
                }
                .frame(
                    width: idleHovered ? Theme.Size.dictationIdleHoverWidth : Theme.Size.dictationIdleWidth,
                    height: idleHovered ? Theme.Size.dictationIndicatorHeight : Theme.Size.dictationIdleHeight)
            case .starting:
                DictationProcessingRing(ink: ink)
                Text("Starting…")
            case .listening:
                DictationWaveform(levels: listeningLevels, compact: style.isCompact)
                if !style.isCompact { Text("Listening") }
            case .transcribing:
                DictationProcessingRing(ink: ink)
                if !titles.isEmpty { processingLabel(titles) }
            }
        }
        .opacity(phase.isIdle || contentReady ? 1 : 0)
        .font(Theme.Typography.panelTitle)
        .padding(.horizontal, phase.isIdle ? 0 : Theme.Spacing.dictationWaveInset)
        .frame(height: phase.isIdle && !idleHovered
            ? Theme.Size.dictationIdleHeight : Theme.Size.dictationIndicatorHeight)
        .background {
            shape
                .fill(background)
                .overlay {
                    shape.strokeBorder(borderInk, lineWidth: Theme.Size.dictationOutlineWidth)
                        .opacity(showsBorder ? 1 : 0)
                }
        }
        .fixedSize()
        .animation(morphAnimation, value: phase.isIdle)
        .animation(morphAnimation, value: phase.isTranscribing)
        .animation(morphAnimation, value: idleHovered)
        .animation(morphAnimation, value: processingIndex)
        .contentShape(shape)
        .onTapGesture { if phase.isIdle { onStart() } }
        .task(id: titles) { await cycleProcessingTitles(count: titles.count) }
        .task(id: phase.isIdle) {
            contentReady = false
            guard !phase.isIdle else { return }
            if !reduceMotion && Motion.isEnabled {
                do { try await Task.sleep(for: .seconds(Theme.Duration.dictationIndicatorMorph)) } catch { return }
            }
            withAnimation(reduceMotion || !Motion.isEnabled ? nil : .easeOut(duration: Theme.Duration.exit)) {
                contentReady = true
            }
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityStatus)
        .accessibilityAddTraits(phase.isIdle ? .isButton : [])
    }

    private func processingLabel(_ titles: [String]) -> some View {
        let title = titles[processingIndex % titles.count]
        return DictationTranscribingLabel(title: title, ink: ink)
            .fixedSize()
            .contentTransition(.opacity)
            .frame(width: processingWidths[title])
            .clipped()
            .background {
                ZStack {
                    ForEach(titles.indices, id: \.self) { index in
                        let candidate = titles[index]
                        Text(verbatim: candidate)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                                processingWidths[candidate] = $0
                            }
                            .id(candidate)
                    }
                }
                .hidden()
                .accessibilityHidden(true)
            }
    }

    private func cycleProcessingTitles(count: Int) async {
        processingIndex = 0
        guard count > 1 else { return }
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(Theme.Duration.dictationProcessingWord))
                try Task.checkCancellation()
                processingIndex = (processingIndex + 1) % count
            }
        } catch {
            return
        }
    }

    private var accessibilityStatus: Text {
        switch phase {
        case .idle: Text("Dictation ready")
        case .starting: Text("Starting…")
        case .listening: Text("Dictation listening")
        case .transcribing: Text("Transcribing dictation")
        }
    }

    private var shape: RoundedRectangle {
        let radius: CGFloat
        if phase.isIdle {
            radius = (idleHovered ? Theme.Size.dictationIndicatorHeight : Theme.Size.dictationIdleHeight) / 2
        } else if style.shape == .rounded {
            radius = Theme.Radius.card
        } else {
            radius = Theme.Size.dictationIndicatorHeight / 2
        }
        return RoundedRectangle(cornerRadius: radius, style: style.shape == .rounded ? .continuous : .circular)
    }

    private var showsBorder: Bool {
        phase.isIdle ? idleHovered : true
    }

    private var borderInk: Color {
        phase.isIdle || style.isDark ? Theme.Colors.dictationOutline : Theme.Colors.dictationLightBorder
    }

    private var ink: Color {
        style.isDark ? Theme.Colors.dictationDarkInk : Theme.Colors.dictationLightInk
    }

    private var background: Color {
        guard phase.isIdle else { return style.backgroundColor }
        guard idleHovered else { return Theme.Colors.dictationIdleBar }
        return style.isDark ? style.backgroundColor : Theme.Colors.dictationBackground
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
    let title: String
    let ink: Color

    var body: some View {
        let label = Text(verbatim: title)
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

struct DictationProcessingWidth: View {
    var body: some View {
        let titles = DictationIndicatorView.Phase.processingLabels
        HStack(spacing: Theme.Spacing.xl) {
            Color.clear.frame(width: Theme.Size.dictationSpinnerDiameter, height: 0)
            ZStack {
                ForEach(titles.indices, id: \.self) { index in
                    Text(verbatim: titles[index])
                }
            }
        }
        .font(Theme.Typography.panelTitle)
        .padding(.horizontal, Theme.Spacing.dictationWaveInset)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
    }
}

struct DictationTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transcript: String
    let animates: Bool
    let twoLines: Bool
    let style: DictationIndicatorStyle
    var maximumWidth = Theme.Size.dictationPreviewWidth
    @State private var displayedText = ""
    @State private var characterReveals: [CharacterReveal] = []

    private struct TranscriptUpdate: Equatable {
        let text: String
        let animated: Bool
    }

    private struct CharacterReveal {
        private static let fadeCurve = UnitCurve.bezier(
            startControlPoint: UnitPoint(x: 0, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))

        let range: Range<Int>
        let start: Date

        var duration: TimeInterval {
            min(Double(range.count) * Theme.Duration.dictationCharacterStep, Theme.Duration.dictationRevealLimit)
        }
        var end: Date { start.addingTimeInterval(duration + Theme.Duration.dictationCharacterFade) }

        func opacity(at date: Date, index: Int) -> Double {
            let fraction = Double(index - range.lowerBound + 1) / Double(range.count)
            let threshold = duration * (1 - cbrt(1 - fraction))
            let fade = (date.timeIntervalSince(start) - threshold) / Theme.Duration.dictationCharacterFade
            return Self.fadeCurve.value(at: min(1, max(0, fade)))
        }
    }

    private var usesMotion: Bool { animates && !reduceMotion && Motion.isEnabled }
    private var ink: Color { style.isDark ? Theme.Colors.dictationDarkInk : Theme.Colors.dictationLightInk }

    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var wrappedLines: ArraySlice<NSRange> = []

    private static var transcriptFont: NSFont { .systemFont(ofSize: Theme.Typography.dictationTranscriptSize) }

    private static var lineHeight: CGFloat {
        let font = transcriptFont
        return ceil(font.ascender - font.descender + font.leading)
    }

    private static var lineStride: CGFloat { lineHeight + Theme.Spacing.md }
    private static let verticalInset = Theme.Spacing.md

    static func maximumHeight(twoLines: Bool) -> CGFloat {
        lineHeight + (twoLines ? lineStride : 0) + 2 * verticalInset
    }

    private var lineAnimation: Animation? {
        usesMotion ? .easeInOut(duration: Theme.Duration.dictationPreviewLineShift) : nil
    }

    private var maximumTextWidth: CGFloat {
        maximumWidth - 2 * Theme.Spacing.xl
    }

    private func measuredWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: Self.transcriptFont
        ]).width)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: characterReveals.isEmpty || !usesMotion)) { timeline in
            transcriptViewport(at: timeline.date)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: transcript))
        .onChange(of: twoLines) {
            updateWrappedLines(displayedText)
            characterReveals = []
        }
        .task(id: TranscriptUpdate(text: transcript, animated: usesMotion)) {
            let next = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard usesMotion else {
                updateText(next)
                characterReveals = []
                return
            }
            await revealCharacters(next)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Self.verticalInset)
        .foregroundStyle(ink)
        .background(
            style.backgroundColor,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(
                    style.isDark ? Theme.Colors.dictationOutline : Theme.Colors.dictationLightBorder,
                    lineWidth: Theme.Size.dictationOutlineWidth)
        }
    }

    private func transcriptViewport(at date: Date) -> some View {
        let text = text(at: date)
        let lines: ArraySlice<NSRange> = twoLines ? wrappedLines.suffix(2) : []
        let lineCount = twoLines ? max(1, lines.count) : 1
        let offset = twoLines ? 0 : scrollOffset
        return Group {
            if twoLines && !lines.isEmpty {
                rollingLines(text, lines: lines)
            } else {
                transcriptLine(text)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: Self.lineHeight + CGFloat(lineCount - 1) * Self.lineStride, alignment: .topLeading)
        .animation(lineAnimation, value: lineCount)
        .offset(x: -offset)
        .frame(width: max(24, viewportWidth), alignment: .leading)
        .animation(lineAnimation, value: viewportWidth)
        .clipped()
        .mask(alignment: .leading) {
            HStack(spacing: 0) {
                if offset > 0 {
                    LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Theme.Spacing.xl)
                }
                Color.white
            }
        }
    }

    private func revealCharacters(_ source: String) async {
        let previous = displayedText
        updateText(source)
        characterReveals = []
        let first = DictationPreviewSequence.revealStart(previous: previous, incoming: source, limit: 36)
        guard first < source.count else { return }
        let changed = first..<source.count
        var start = Date()
        var pending: [CharacterReveal] = []
        let lines = twoLines ? Array(wrappedLines.suffix(2)) : [NSRange(source.startIndex..., in: source)]
        for line in lines {
            guard let range = Range(line, in: source) else { continue }
            let lower = source.distance(from: source.startIndex, to: range.lowerBound)
            let upper = source.distance(from: source.startIndex, to: range.upperBound)
            let newCharacters = changed.clamped(to: lower..<upper)
            guard !newCharacters.isEmpty else { continue }
            let reveal = CharacterReveal(range: newCharacters, start: start)
            pending.append(reveal)
            start = start.addingTimeInterval(min(reveal.duration, Theme.Duration.dictationRevealLineDelay))
        }
        characterReveals = pending
        if let end = pending.map(\.end).max() {
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
        }
        characterReveals = []
    }

    private func transcriptLine(_ text: AttributedString) -> some View {
        Text(text)
            .font(Theme.Typography.dictationTranscript)
            .lineLimit(1)
            .contentTransition(.identity)
            .fixedSize(horizontal: true, vertical: false)
            .transaction { $0.animation = nil }
    }

    private func rollingLines(_ text: AttributedString, lines: ArraySlice<NSRange>) -> some View {
        let stride = Self.lineStride
        let source = displayedText
        return ZStack(alignment: .topLeading) {
            ForEach(Array(lines.indices), id: \.self) { index in
                if let range = Range(lines[index], in: source),
                    let start = AttributedString.Index(range.lowerBound, within: text),
                    let end = AttributedString.Index(range.upperBound, within: text)
                {
                    transcriptLine(AttributedString(text[start..<end]))
                        .frame(height: Self.lineHeight)
                        .offset(y: CGFloat(index - lines.startIndex) * stride)
                        .transition(.asymmetric(insertion: .offset(y: stride), removal: .offset(y: -stride)))
                }
            }
        }
        .animation(lineAnimation, value: lines.indices)
    }

    private func updateText(_ source: String) {
        displayedText = source
        updateWrappedLines(source)
        let contentWidth = measuredWidth(source)
        viewportWidth = max(viewportWidth, min(contentWidth, maximumTextWidth))
        scrollOffset = max(0, contentWidth - viewportWidth)
    }

    private func updateWrappedLines(_ source: String) {
        guard twoLines, !source.isEmpty else {
            wrappedLines = []
            return
        }
        let attributed = NSAttributedString(string: source, attributes: [.font: Self.transcriptFont])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [NSRange] = []
        var location = 0
        while location < attributed.length {
            let length = CTTypesetterSuggestLineBreak(typesetter, location, maximumTextWidth)
            guard length > 0 else { break }
            lines.append(NSRange(location: location, length: length))
            location += length
        }
        wrappedLines = lines[...]
    }

    private func text(at date: Date) -> AttributedString {
        let source = displayedText
        guard usesMotion, !characterReveals.isEmpty else { return AttributedString(source) }
        var result = AttributedString()
        var position = source.startIndex
        var previousEnd = 0
        for reveal in characterReveals where reveal.end > date {
            let first = source.index(position, offsetBy: reveal.range.lowerBound - previousEnd)
            result.append(AttributedString(source[position..<first]))
            let end = source.index(first, offsetBy: reveal.range.count)
            for (index, character) in zip(reveal.range, source[first..<end]) {
                var part = AttributedString(String(character))
                part.foregroundColor = ink.opacity(reveal.opacity(at: date, index: index))
                result.append(part)
            }
            position = end
            previousEnd = reveal.range.upperBound
        }
        result.append(AttributedString(source[position...]))
        return result
    }
}

private struct DictationPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: DictationDisplayState
    var style: DictationIndicatorStyle
    var phase: DictationIndicatorView.Phase
    var onStart: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}
    var onDragMoved: (CGPoint) -> CGPoint = { $0 }
    var onProcessingWidthChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !phase.isIdle && !style.isCompact {
                DictationProcessingWidth()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onProcessingWidthChanged($0) }
                    .frame(width: phase.isTranscribing ? nil : 0, height: 0)
            }
            panelContents
        }
        .frame(
            minWidth: state.transcript.isEmpty ? 0 : Theme.Size.dictationPreviewWidth,
            minHeight: Theme.Size.dictationIndicatorHeight, alignment: .bottom)
        .motionScope()
    }

    private var panelContents: some View {
        VStack(spacing: Theme.Spacing.md) {
            if !state.transcript.isEmpty {
                DictationTranscriptView(
                    transcript: state.transcript, animates: state.animatesTranscript,
                    twoLines: state.twoLinePreview, style: style)
                    .frame(height: DictationTranscriptView.maximumHeight(twoLines: state.twoLinePreview), alignment: .bottom)
                    .opacity(state.previewPaused ? 0 : 1)
                    .animation(
                        reduceMotion || !Motion.isEnabled || !state.animatesTranscript
                            ? nil : .easeInOut(duration: Theme.Duration.dictationPreviewLineShift),
                        value: state.previewPaused)
                    .accessibilityHidden(state.previewPaused)
            }
            DictationIndicatorView(
                style: style, phase: phase, levels: state.levels, idleHovered: state.idleHovered, onStart: onStart)
                .overlay {
                    WindowDragHandle(
                        onBegan: onDragBegan, onEnded: onDragEnded,
                        onClick: { if phase.isIdle { onStart() } }, onMoved: onDragMoved)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.indicatorWidth = $0 }
                .offset(x: state.indicatorOffset)
        }
    }
}

private final class DictationPanel: NSPanel, AnimatedPanel {
    private let host: NSHostingView<DictationPanelView>
    private let settings: AppSettings
    private let guides = PaletteDropGuideController(forAllApplications: true)
    private var dragging = false
    private var guidesVisible = false
    private var snappedX = false
    private var snappedY = false
    private var dragScreen: NSScreen?
    private var dragBottom: CGFloat?
    private var dragStartOffset: CGFloat = 0
    private var dragOwner: pid_t?
    private var dragSourceDisplay: String?
    private var chosenDisplay: String?
    private var processingWidth: CGFloat = 0
    private var observers: [NotificationToken] = []
    private var presentationObservation: NSKeyValueObservation?
    private var placementTimer: Timer?
    private var dockLookup: Task<Void, Never>?
    private var dockAccessibilityBounds: CGRect?
    private var idleHoverMonitors: [Any] = []
    var onAccept: (() -> Void)?
    var onStart: (() -> Void)?

    init(rootView: DictationPanelView, settings: AppSettings) {
        let host = NSHostingView(rootView: rootView)
        self.host = host
        self.settings = settings
        super.init(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .darkAqua)
        contentView = host
        isOpaque = false
        backgroundColor = .clear
        hasShadow = rootView.style.isDark && !rootView.phase.isIdle
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        host.rootView.onDragBegan = { [weak self] in self?.beginDrag() }
        host.rootView.onDragEnded = { [weak self] in self?.endDrag() }
        host.rootView.onDragMoved = { [weak self] point in self?.drag(to: point) ?? point }
        host.rootView.onProcessingWidthChanged = { [weak self] width in
            guard let self, processingWidth != width else { return }
            processingWidth = width
            reposition(refreshDock: false)
        }
        followMotion()
        observePlacementChanges()
    }

    override var canBecomeKey: Bool { !host.rootView.phase.isIdle }
    override var canBecomeMain: Bool { false }

    func setStyle(_ style: DictationIndicatorStyle) { host.rootView.style = style }
    func setStartAction(_ action: (() -> Void)?) {
        onStart = action
        host.rootView.onStart = { action?() }
    }

    func show(_ phase: DictationIndicatorView.Phase) {
        let previous = frame
        if !phase.isIdle { stopWatchingIdleHover() }
        host.rootView.phase = phase
        hasShadow = host.rootView.style.isDark && !phase.isIdle
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let width = phase.isTranscribing ? max(previous.width, size.width) : size.width
        let destination = NSRect(
            x: previous.midX - width / 2, y: previous.minY,
            width: width, height: size.height)
        setFrame(destination, display: true)
        reposition()
    }

    func position(on screen: NSScreen, refreshDock: Bool = true) {
        let bounds = screen.frame
        let bottom = minimumY(on: screen, refreshDock: refreshDock)
        let centerX: CGFloat
        let y: CGFloat
        if let stored = settings.dictationIndicatorPositions[screen.displayKey], stored.count == 2,
            stored.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        {
            centerX = bounds.minX + bounds.width * stored[0]
            y = bounds.minY + bounds.height * stored[1]
        } else {
            centerX = bounds.midX
            y = bottom
        }
        let center = clampedCenter(centerX, on: screen)
        let origin = clamped(CGPoint(x: center - frame.width / 2, y: y), on: screen, bottom: bottom)
        let offset = center - (origin.x + frame.width / 2)
        if host.rootView.state.indicatorOffset != offset { host.rootView.state.indicatorOffset = offset }
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    private func minimumY(on screen: NSScreen, refreshDock: Bool = true) -> CGFloat {
        let bounds = screen.frame
        let visible = screen.visibleFrame
        let reservesDockSpace = visible.minY - bounds.minY > 4
        let presentation = NSApp.currentSystemPresentationOptions
        let hidesDock = !presentation.isDisjoint(with: [.fullScreen, .hideDock, .autoHideDock])
        let geometry = dockGeometry(on: screen)
        let bottom: CGFloat
        if let dockTop = geometry.top {
            bottom = dockTop
        } else {
            if refreshDock { refreshDockAccessibilityBounds() }
            if let dockAccessibilityBounds {
                bottom = bottomDockTop(for: dockAccessibilityBounds, on: screen) ?? bounds.minY
            } else {
                bottom = reservesDockSpace && !hidesDock && !geometry.windowFillsDisplay ? visible.minY : bounds.minY
            }
        }
        return bottom + Theme.Spacing.dictationPanelBottomInset
    }

    private func clamped(_ point: CGPoint, on screen: NSScreen, bottom: CGFloat) -> CGPoint {
        let bounds = screen.frame
        let inset = Theme.Spacing.dictationPanelBottomInset
        let minX = bounds.minX + inset
        let maxX = max(minX, bounds.maxX - frame.width - inset)
        let maxY = max(bottom, bounds.maxY - frame.height - inset)
        return CGPoint(x: min(max(point.x, minX), maxX), y: min(max(point.y, bottom), maxY))
    }

    private func clampedCenter(_ center: CGFloat, on screen: NSScreen) -> CGFloat {
        let inset = Theme.Spacing.dictationPanelBottomInset
        let half = placementWidth / 2
        let minimum = screen.frame.minX + inset + half
        let maximum = max(minimum, screen.frame.maxX - inset - half)
        return min(max(center, minimum), maximum)
    }

    private var placementWidth: CGFloat {
        let root = host.rootView
        let indicatorWidth = min(max(root.state.indicatorWidth, 2), frame.width)
        guard !root.phase.isIdle, !root.style.isCompact, processingWidth > 0 else { return indicatorWidth }
        if root.phase.isTranscribing { return min(processingWidth, frame.width) }
        return max(indicatorWidth, processingWidth)
    }

    private func beginDrag() {
        dragging = true
        guidesVisible = false
        snappedX = false
        snappedY = false
        dragScreen = nil
        dragBottom = nil
        dragStartOffset = host.rootView.state.indicatorOffset
        dragOwner = NSWorkspace.shared.frontmostApplication?.processIdentifier
        dragSourceDisplay = Self.activeScreen?.displayKey
    }

    private func drag(to point: CGPoint) -> CGPoint {
        guard dragging, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? self.screen ?? Self.activeScreen
        else { return point }
        let bottom: CGFloat
        if dragScreen?.displayKey == screen.displayKey, let cached = dragBottom {
            bottom = cached
        } else {
            bottom = minimumY(on: screen)
            dragBottom = bottom
        }
        let bounded = clamped(point, on: screen, bottom: bottom)
        let bounds = screen.frame
        let inset = Theme.Spacing.dictationPanelBottomInset
        let indicatorWidth = min(max(host.rootView.state.indicatorWidth, 1), frame.width)
        let center = clampedCenter(point.x + frame.width / 2 + dragStartOffset, on: screen)
        let xs = [bounds.minX + inset + placementWidth / 2, bounds.midX,
                  bounds.maxX - inset - placementWidth / 2]
        let ys = [bottom, bounds.midY - Theme.Size.dictationIndicatorHeight / 2,
                  bounds.maxY - frame.height - inset]
        let targetX = xs.min { abs($0 - center) < abs($1 - center) } ?? center
        let targetY = ys.min { abs($0 - bounded.y) < abs($1 - bounded.y) } ?? bounded.y
        let distance = Theme.Size.paletteSnapDistance
        let hitX = abs(targetX - center) <= distance * (snappedX ? 2 : 1)
        let hitY = abs(targetY - bounded.y) <= distance * (snappedY ? 2 : 1)
        let resultCenter = clampedCenter(hitX ? targetX : center, on: screen)
        let result = clamped(CGPoint(x: resultCenter - frame.width / 2, y: hitY ? targetY : bounded.y),
                             on: screen, bottom: bottom)
        host.rootView.state.indicatorOffset = resultCenter - (result.x + frame.width / 2)
        let home = CGPoint(x: targetX - indicatorWidth / 2, y: targetY + Theme.Size.dictationIndicatorHeight)
        let dragged = CGPoint(x: center - indicatorWidth / 2, y: bounded.y + Theme.Size.dictationIndicatorHeight)
        if !guidesVisible {
            guides.show(home: home, width: indicatorWidth, screenFrame: bounds, dragged: dragged)
            guidesVisible = true
        } else {
            guides.move(home: home, screenFrame: bounds, dragged: dragged, width: indicatorWidth)
        }
        if (hitX && !snappedX) || (hitY && !snappedY) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
            guides.flash(hitX && hitY ? .both : hitX ? .vertical : .horizontal)
        }
        snappedX = hitX
        snappedY = hitY
        dragScreen = screen
        return result
    }

    private func endDrag() {
        defer {
            dragging = false
            dragScreen = nil
            guidesVisible = false
            guides.hide()
        }
        guard dragging, isVisible, let screen = dragScreen else { return }
        let bounds = screen.frame
        let x = min(max((frame.midX + host.rootView.state.indicatorOffset - bounds.minX) / bounds.width, 0), 1)
        let y = min(max((frame.minY - bounds.minY) / bounds.height, 0), 1)
        settings.dictationIndicatorPositions[screen.displayKey] = [x, y]
        chosenDisplay = screen.displayKey
    }

    private func dockGeometry(on screen: NSScreen) -> (top: CGFloat?, windowFillsDisplay: Bool) {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return (nil, false) }
        let display = screen.frame
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var top: CGFloat?
        var windowFillsDisplay = false
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            if layer > 0, window[kCGWindowOwnerName as String] as? String == "Dock",
               let dockTop = bottomDockTop(for: rectangle, on: screen) {
                top = max(top ?? dockTop, dockTop)
            } else if !windowFillsDisplay, layer == 0, let frontPID,
                      window[kCGWindowOwnerPID as String] as? pid_t == frontPID {
                windowFillsDisplay = rectangle.height >= display.height * 0.75
                    && abs(primary.frame.maxY - rectangle.maxY - display.minY) <= 2
                    && rectangle.minX <= display.minX + 2 && rectangle.maxX >= display.maxX - 2
            }
        }
        return (top, windowFillsDisplay)
    }

    private func bottomDockTop(for bounds: CGRect, on screen: NSScreen) -> CGFloat? {
        guard let primary = NSScreen.screens.first else { return nil }
        let display = screen.frame
        let top = primary.frame.maxY - bounds.minY
        let bottom = top - bounds.height
        let dockBottomTolerance: CGFloat = 24
        guard bounds.width > bounds.height, bounds.height > 4, bounds.height < display.height / 2,
              bounds.minX <= display.midX, bounds.maxX >= display.midX,
              bottom <= display.minY + dockBottomTolerance, top > display.minY + 4
        else { return nil }
        return top
    }

    private func refreshDockAccessibilityBounds() {
        guard dockLookup == nil, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        let pid = dock.processIdentifier
        dockLookup = Task { @MainActor [weak self] in
            let bounds = await Self.readDockAccessibilityBounds(pid: pid)
            guard let self, !Task.isCancelled else { return }
            dockLookup = nil
            guard dockAccessibilityBounds != bounds else { return }
            dockAccessibilityBounds = bounds
            reposition(refreshDock: false)
        }
    }

    private func clearDockAccessibilityBounds() {
        dockLookup?.cancel()
        dockLookup = nil
        dockAccessibilityBounds = nil
    }

    @concurrent private static func readDockAccessibilityBounds(pid: pid_t) async -> CGRect? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXChildren" as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.05)
            var attributes: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(
                child, ["AXRole", "AXPosition", "AXSize"] as CFArray, [], &attributes) == .success,
                let values = attributes as? [AnyObject], values.count == 3, values[0] as? String == "AXList",
                CFGetTypeID(values[1]) == AXValueGetTypeID(), CFGetTypeID(values[2]) == AXValueGetTypeID()
            else { continue }
            var origin = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(unsafeDowncast(values[1], to: AXValue.self), .cgPoint, &origin),
               AXValueGetValue(unsafeDowncast(values[2], to: AXValue.self), .cgSize, &size) {
                return CGRect(origin: origin, size: size)
            }
        }
        return nil
    }

    private func reposition(refreshDock: Bool = true) {
        guard isVisible, !dragging, let active = Self.activeScreen else { return }
        let sameContext = dragOwner == NSWorkspace.shared.frontmostApplication?.processIdentifier
            && dragSourceDisplay == active.displayKey
        if !sameContext { chosenDisplay = nil }
        let screen = sameContext ? NSScreen.screens.first { $0.displayKey == chosenDisplay } ?? active : active
        position(on: screen, refreshDock: refreshDock)
        if host.rootView.phase.isIdle { updateIdleHover() }
    }

    static var activeScreen: NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return screens.first }
        guard let primary = screens.first,
              let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return NSScreen.underCursor }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == processID,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rectangle.width > 0, rectangle.height > 0
            else { continue }
            let frame = CGRect(
                x: rectangle.minX, y: primary.frame.maxY - rectangle.maxY,
                width: rectangle.width, height: rectangle.height)
            let overlaps = screens.map { screen in
                let intersection = screen.frame.intersection(frame)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (screen: screen, area: area)
            }
            if let match = overlaps.max(by: { $0.area < $1.area }), match.area > 0 {
                return match.screen
            }
        }
        return NSScreen.underCursor
    }

    private func observePlacementChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        let application = NotificationCenter.default
        observers = [
            NotificationToken(
                workspace.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.reposition() }
                }, center: workspace),
            NotificationToken(
                workspace.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.clearDockAccessibilityBounds()
                        self?.reposition()
                    }
                }, center: workspace),
            NotificationToken(
                application.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.clearDockAccessibilityBounds()
                        self?.reposition()
                    }
                }, center: application)
        ]
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        placementTimer = timer
        presentationObservation = NSApp.observe(
            \.currentSystemPresentationOptions, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.reposition() }
        }
    }

    func stopObservingPlacementChanges() {
        observers.removeAll()
        presentationObservation = nil
        placementTimer?.invalidate()
        placementTimer = nil
        clearDockAccessibilityBounds()
        stopWatchingIdleHover()
        dragging = false
        dragScreen = nil
        dragBottom = nil
        chosenDisplay = nil
        guides.close()
    }

    func watchIdleHover() {
        guard idleHoverMonitors.isEmpty else { updateIdleHover(); return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.updateIdleHover()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateIdleHover()
            return event
        }
        idleHoverMonitors = [global, local].compactMap { $0 }
        updateIdleHover()
    }

    private func stopWatchingIdleHover() {
        idleHoverMonitors.forEach(NSEvent.removeMonitor)
        idleHoverMonitors = []
        host.rootView.state.idleHovered = false
    }

    private func updateIdleHover() {
        guard isVisible, host.rootView.phase.isIdle else { return }
        let hovered = host.rootView.state.idleHovered
        let width = hovered ? Theme.Size.dictationIdleHoverWidth : Theme.Size.dictationIdleWidth
        let height = hovered ? Theme.Size.dictationIndicatorHeight : Theme.Size.dictationIdleHeight
        let target = NSRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: height)
            .insetBy(dx: -Theme.Spacing.xs, dy: -Theme.Spacing.xs)
        let inside = target.contains(NSEvent.mouseLocation)
        ignoresMouseEvents = !inside
        guard inside != hovered else { return }
        host.rootView.state.idleHovered = inside
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: onAccept?(); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class DictationPanelController {
    let state = DictationDisplayState()
    private let settings: AppSettings
    private var panel: DictationPanel?
    private var escapeMonitors: [Any] = []
    private var previewPauseTask: Task<Void, Never>?
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?

    init(settings: AppSettings) { self.settings = settings }

    func showStarting(style: DictationIndicatorStyle) {
        let screen = DictationPanel.activeScreen
        guard let screen else { return }
        state.levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
        previewPauseTask?.cancel()
        previewPauseTask = nil
        state.previewPaused = false
        state.transcript = ""
        if let panel, panel.isVisible {
            panel.ignoresMouseEvents = false
            panel.onAccept = onAccept
            panel.setStyle(style)
            panel.show(.starting)
            watchForEscape()
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }
        close()
        let panel = DictationPanel(rootView: DictationPanelView(state: state, style: style, phase: .starting), settings: settings)
        panel.onAccept = onAccept
        self.panel = panel
        watchForEscape()
        panel.position(on: screen)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func showIdle(style: DictationIndicatorStyle) {
        stopWatchingForEscape()
        let screen = DictationPanel.activeScreen
        guard let screen else { return }
        if let panel, panel.isVisible {
            previewPauseTask?.cancel()
            previewPauseTask = nil
            state.previewPaused = false
            state.transcript = ""
            panel.setStyle(style)
            panel.show(.idle)
            panel.ignoresMouseEvents = true
            panel.resignKey()
            panel.setStartAction(onStart)
            panel.watchIdleHover()
            return
        }
        close()
        let panel = DictationPanel(rootView: DictationPanelView(state: state, style: style, phase: .idle), settings: settings)
        panel.ignoresMouseEvents = true
        panel.setStartAction(onStart)
        self.panel = panel
        panel.position(on: screen)
        panel.orderFrontRegardless()
        panel.watchIdleHover()
    }

    func showListening() { panel?.show(.listening) }

    func showPreview(_ text: String, twoLines: Bool, cumulative: Bool) {
        let incoming = text.split(whereSeparator: \.isWhitespace).suffix(100).joined(separator: " ")
        let previous = state.transcript
        let preview = cumulative ? incoming : DictationPreviewSequence.merge(previous, incoming)
        let hasNewText = !preview.isEmpty && preview != previous
            && (cumulative || !previous.hasSuffix(" " + preview))
        guard hasNewText || state.twoLinePreview != twoLines else { return }
        if hasNewText {
            state.transcript = preview
            schedulePreviewPause()
        }
        state.twoLinePreview = twoLines
        panel?.show(.listening)
    }

    private func schedulePreviewPause() {
        previewPauseTask?.cancel()
        state.previewPaused = false
        previewPauseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Theme.Duration.dictationPreviewPause)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            state.previewPaused = true
            previewPauseTask = nil
        }
    }

    func hidePreview() {
        guard !state.transcript.isEmpty else { return }
        previewPauseTask?.cancel()
        previewPauseTask = nil
        state.previewPaused = false
        state.transcript = ""
        panel?.show(.listening)
    }

    func showTranscribing() {
        previewPauseTask?.cancel()
        previewPauseTask = nil
        panel?.show(.randomTranscribing())
    }

    private func watchForEscape() {
        guard escapeMonitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleEscape(event)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEscape(event) == true ? nil : event
        }
        escapeMonitors = [global, local].compactMap { $0 }
    }

    private func handleEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == kVK_Escape, !event.isARepeat, !escapeMonitors.isEmpty else { return false }
        onCancel?()
        return true
    }

    private func stopWatchingForEscape() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
    }

    func close() {
        stopWatchingForEscape()
        previewPauseTask?.cancel()
        previewPauseTask = nil
        state.previewPaused = false
        state.transcript = ""
        panel?.stopObservingPlacementChanges()
        panel?.orderOut(nil)
        panel = nil
    }
}
