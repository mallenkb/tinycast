import AppKit
import Carbon.HIToolbox
import CoreText
import SwiftUI

@MainActor
@Observable
final class DictationDisplayState {
    var transcript = ""
    var animatesTranscript = true
    var twoLinePreview = false
    var idleHovered = false
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
    enum Phase {
        case idle
        case starting
        case listening
        case transcribing([String])

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

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
    var idleHovered = false
    var onStart: () -> Void = {}

    private var morphAnimation: Animation? {
        reduceMotion || !Motion.isEnabled ? nil : .easeInOut(duration: Theme.Duration.dictationIndicatorMorph)
    }

    var body: some View {
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
            case .transcribing(let titles):
                DictationProcessingRing(ink: ink)
                if !style.isCompact { DictationTranscribingLabel(titles: titles, ink: ink) }
            }
        }
        .opacity(phase.isIdle || contentReady ? 1 : 0)
        .font(Theme.Typography.panelTitle)
        .padding(.horizontal, phase.isIdle ? 0 : Theme.Spacing.dictationWaveInset)
        .frame(height: phase.isIdle && !idleHovered
            ? Theme.Size.dictationIdleHeight : Theme.Size.dictationIndicatorHeight)
        .background {
            shape
                .fill(phase.isIdle ? (idleHovered ? Theme.Colors.dictationBackground : Theme.Colors.dictationIdleBar)
                    : background)
                .overlay {
                    shape.strokeBorder(borderInk, lineWidth: Theme.Size.dictationOutlineWidth)
                        .opacity(showsBorder ? 1 : 0)
                }
        }
        .fixedSize()
        .animation(morphAnimation, value: phase.isIdle)
        .animation(morphAnimation, value: idleHovered)
        .contentShape(shape)
        .onTapGesture { if phase.isIdle { onStart() } }
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
        phase.isIdle ? idleHovered : !style.isDark || outlined
    }

    private var borderInk: Color {
        phase.isIdle || style.isDark ? Theme.Colors.dictationOutline : Theme.Colors.dictationLightBorder
    }

    private var ink: Color {
        style.isDark ? Theme.Colors.dictationDarkInk : Theme.Colors.dictationLightInk
    }

    private var background: Color {
        switch style {
        case .lightCompact, .lightGrayCompact, .lightCapsule, .lightRounded,
            .lightOutlinedCapsule, .lightOutlinedRounded:
            Theme.Colors.dictationLightBackground
        case .grayCompact, .darkCapsule, .darkRounded: Theme.Colors.dictationDarkBackground
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

struct DictationTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transcript: String
    let animates: Bool
    let twoLines: Bool
    let style: DictationIndicatorStyle
    @State private var words: [String] = []
    @State private var revealStarts: [Int: Date] = [:]
    @State private var revealing = false

    private var usesMotion: Bool { animates && !reduceMotion && Motion.isEnabled }
    private var ink: Color { style.isDark ? Theme.Colors.dictationDarkInk : Theme.Colors.dictationLightInk }

    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var wrappedLines: ArraySlice<NSRange> = []

    private var transcriptFont: NSFont { .systemFont(ofSize: Theme.Typography.dictationTranscriptSize) }

    private var maximumTextWidth: CGFloat {
        Theme.Size.dictationPreviewWidth - 2 * Theme.Spacing.xl
    }

    private func measuredWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: transcriptFont
        ]).width)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !revealing || !usesMotion)) { timeline in
            let text = text(at: timeline.date)
            if twoLines {
                rollingLines(text)
            } else {
                transcriptLine(text)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .offset(x: twoLines ? 0 : -scrollOffset)
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
        .mask(alignment: .leading) {
            HStack(spacing: 0) {
                if !twoLines && scrollOffset > 0 {
                    LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Theme.Spacing.xl)
                }
                Color.white
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: transcript))
        .onChange(of: twoLines) { updateWrappedLines(words.joined(separator: " ")) }
        .task(id: transcript) {
            let next = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
            guard usesMotion else {
                updateWords(next, animated: false)
                revealing = false
                revealStarts = [:]
                return
            }
            let inserted = Set(next.difference(from: words).compactMap { change -> Int? in
                if case .insert(let offset, _, _) = change { return offset }
                return nil
            })
            let lastRetained = next.indices.last { !inserted.contains($0) }
            let retainedCount = lastRetained.map { $0 + 1 } ?? min(words.count, next.count)
            updateWords(Array(next.prefix(retainedCount)), animated: false)
            var count = retainedCount
            while count < next.count {
                count = min(count + 3, next.count)
                reveal(Array(next.prefix(count)))
                do { try await Task.sleep(for: .seconds(Theme.Duration.dictationWordGroup)) } catch { return }
            }
            do { try await Task.sleep(for: .seconds(Theme.Duration.dictationWordFade)) } catch { return }
            revealing = false
            revealStarts = [:]
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.xl * 0.8)
        .foregroundStyle(ink)
        .background(
            style.isDark ? Theme.Colors.dictationDarkBackground : Theme.Colors.dictationLightBackground,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay {
            if !style.isDark {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.dictationLightBorder, lineWidth: Theme.Size.dictationOutlineWidth)
            }
        }
    }

    private func transcriptLine(_ text: AttributedString) -> some View {
        Text(text)
            .font(Theme.Typography.dictationTranscript)
            .lineLimit(1)
            .contentTransition(.identity)
            .fixedSize(horizontal: true, vertical: false)
            .transaction { $0.animation = nil }
    }

    private func rollingLines(_ text: AttributedString) -> some View {
        let font = transcriptFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let stride = lineHeight + Theme.Spacing.md
        let source = words.joined(separator: " ")
        let lines = wrappedLines
        return ZStack(alignment: .topLeading) {
            ForEach(Array(lines.indices), id: \.self) { index in
                if let range = Range(lines[index], in: source),
                    let start = AttributedString.Index(range.lowerBound, within: text),
                    let end = AttributedString.Index(range.upperBound, within: text)
                {
                    transcriptLine(AttributedString(text[start..<end]))
                        .frame(height: lineHeight)
                        .offset(y: CGFloat(index - lines.startIndex) * stride)
                        .transition(.asymmetric(insertion: .offset(y: stride), removal: .offset(y: -stride)))
                }
            }
        }
        .frame(height: lineHeight + CGFloat(max(0, lines.count - 1)) * stride, alignment: .top)
        .clipped()
        .animation(usesMotion ? .easeInOut(duration: Theme.Duration.dictationWordFade) : nil, value: lines.indices)
    }

    private func reveal(_ next: [String]) {
        updateWords(next, animated: true)
        revealing = !revealStarts.isEmpty
    }

    private func updateWords(_ next: [String], animated: Bool) {
        let difference = next.difference(from: words)
        let removed = Set(difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        let inserted = Set(difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        })
        var retained = words.indices.filter { !removed.contains($0) }.makeIterator()
        var starts: [Int: Date] = [:]
        let now = Date()
        for index in next.indices {
            if inserted.contains(index) {
                if animated { starts[index] = now }
            } else if let previous = retained.next(), let start = revealStarts[previous] {
                starts[index] = start
            }
        }
        revealStarts = starts
        words = next
        let source = next.joined(separator: " ")
        updateWrappedLines(source)
        let contentWidth = measuredWidth(source)
        let width = max(viewportWidth, min(contentWidth, maximumTextWidth))
        let animation: Animation? = animated && usesMotion
            ? .easeOut(duration: Theme.Duration.dictationWordGroup) : nil
        withAnimation(animation) {
            viewportWidth = width
            scrollOffset = max(0, contentWidth - width)
        }
    }

    private func updateWrappedLines(_ source: String) {
        guard twoLines, !source.isEmpty else {
            wrappedLines = []
            return
        }
        let attributed = NSAttributedString(string: source, attributes: [.font: transcriptFont])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [NSRange] = []
        var location = 0
        while location < attributed.length {
            let length = CTTypesetterSuggestLineBreak(typesetter, location, maximumTextWidth)
            guard length > 0 else { break }
            lines.append(NSRange(location: location, length: length))
            location += length
        }
        wrappedLines = lines.suffix(2)
    }

    private func text(at date: Date) -> AttributedString {
        var result = AttributedString()
        for index in words.indices {
            var part = AttributedString(index == 0 ? words[index] : " " + words[index])
            let start = revealStarts[index]
            let progress = min(1, max(0, date.timeIntervalSince(start ?? .distantPast)
                / Theme.Duration.dictationWordFade))
            let opacity = progress * progress * (3 - 2 * progress)
            part.foregroundColor = ink.opacity(usesMotion && start != nil ? opacity : 1)
            result.append(part)
        }
        return result
    }
}

private struct DictationPanelView: View {
    let state: DictationDisplayState
    var style: DictationIndicatorStyle
    var phase: DictationIndicatorView.Phase
    var onStart: () -> Void = {}

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            if !state.transcript.isEmpty {
                DictationTranscriptView(
                    transcript: state.transcript, animates: state.animatesTranscript,
                    twoLines: state.twoLinePreview, style: style)
            }
            DictationIndicatorView(
                style: style, phase: phase, levels: state.levels, idleHovered: state.idleHovered, onStart: onStart)
        }
        .frame(minWidth: Theme.Size.dictationPreviewWidth, minHeight: Theme.Size.dictationIndicatorHeight, alignment: .bottom)
        .motionScope()
    }
}

private final class DictationPanel: NSPanel, AnimatedPanel {
    private let host: NSHostingView<DictationPanelView>
    private var observers: [NotificationToken] = []
    private var presentationObservation: NSKeyValueObservation?
    private var placementTimer: Timer?
    private var dockLookup: Task<Void, Never>?
    private var dockAccessibilityBounds: CGRect?
    private var idleHoverMonitors: [Any] = []
    var onAccept: (() -> Void)?
    var onStart: (() -> Void)?

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
        hasShadow = rootView.style.isDark && !rootView.phase.isIdle
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
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
        let destination = NSRect(
            x: previous.midX - size.width / 2, y: previous.minY,
            width: size.width, height: size.height)
        setFrame(destination, display: true)
        reposition()
    }

    func position(on screen: NSScreen, refreshDock: Bool = true) {
        let frame = screen.frame
        let visible = screen.visibleFrame
        // A hidden Dock still reserves a narrow strip for revealing it.
        let dockRevealMargin: CGFloat = 4
        let reservesDockSpace = visible.minY - frame.minY > dockRevealMargin
        let presentation = NSApp.currentSystemPresentationOptions
        let hidesDock = !presentation.isDisjoint(with: [.fullScreen, .hideDock, .autoHideDock])
        let geometry = dockGeometry(on: screen)
        let bottom: CGFloat
        if let dockTop = geometry.top {
            bottom = dockTop
        } else {
            if refreshDock { refreshDockAccessibilityBounds() }
            if let dockAccessibilityBounds {
                bottom = bottomDockTop(for: dockAccessibilityBounds, on: screen) ?? frame.minY
            } else {
                bottom = reservesDockSpace && !hidesDock && !geometry.windowFillsDisplay ? visible.minY : frame.minY
            }
        }
        let origin = NSPoint(
            x: frame.midX - self.frame.width / 2,
            y: bottom + Theme.Spacing.dictationPanelBottomInset)
        if self.frame.origin != origin { setFrameOrigin(origin) }
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
        guard isVisible, let screen = Self.activeScreen else { return }
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
        if event.type == .leftMouseDown, host.rootView.phase.isIdle, host.rootView.state.idleHovered {
            onStart?()
            return
        }
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
    private var panel: DictationPanel?
    private var escapeMonitors: [Any] = []
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?

    func showStarting(style: DictationIndicatorStyle) {
        let screen = DictationPanel.activeScreen
        guard let screen else { return }
        state.levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
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
        let panel = DictationPanel(rootView: DictationPanelView(state: state, style: style, phase: .starting))
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
        let panel = DictationPanel(rootView: DictationPanelView(state: state, style: style, phase: .idle))
        panel.ignoresMouseEvents = true
        panel.setStartAction(onStart)
        self.panel = panel
        panel.position(on: screen)
        panel.orderFrontRegardless()
        panel.watchIdleHover()
    }

    func showListening() { panel?.show(.listening) }

    func showPreview(_ text: String) {
        state.transcript = String(text.suffix(500))
        panel?.show(.listening)
    }

    func showTranscribing() { panel?.show(.randomTranscribing(cycling: true)) }

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
        state.transcript = ""
        panel?.stopObservingPlacementChanges()
        panel?.orderOut(nil)
        panel = nil
    }
}
