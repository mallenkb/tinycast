import AppKit
import Carbon.HIToolbox
import CoreText
import SwiftUI

private extension DictationIndicatorStyle {
    var horizontalInset: CGFloat {
        isCompact ? Theme.Spacing.dictationCompactInset : Theme.Spacing.dictationRoomyInset
    }

    var waveGap: CGFloat {
        isCompact ? Theme.Spacing.dictationCompactWaveGap : Theme.Spacing.dictationWaveGap
    }

    var waveBarWidth: CGFloat {
        isCompact ? Theme.Size.dictationCompactWaveBar : Theme.Size.dictationWaveBar
    }

    var waveWidth: CGFloat {
        let count = CGFloat(Theme.Size.dictationWaveBarCount)
        return count * waveBarWidth + (count - 1) * waveGap
    }

    var backgroundColor: Color {
        isDark ? Theme.Colors.dictationDarkBackground : Theme.Colors.dictationLightBackground
    }
}

@MainActor
@Observable
final class DictationDisplayState {
    var transcript = ""
    var previewPaused = false
    var foldingCard = false
    var foldingPill = false
    var hidesStatusText = false
    var animatesTranscript = true
    var twoLinePreview = false
    var idleHovered = false
    var indicatorWidth: CGFloat = 0
    var indicatorOffset: CGFloat = 0
    var idleCenterShift: CGFloat = 0
    var idleLift: CGFloat = 0
    var remainingSeconds: Int?
    var processingStarted: Date?
    var showsElapsed = false
    var previewBelow = false
    var previewAlignment: CGFloat = 0
    var panelWidth: CGFloat = 0
    var levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
}

private struct DictationWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [Float]
    let style: DictationIndicatorStyle

    var body: some View {
        HStack(spacing: style.waveGap) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule(style: .circular)
                    .fill(.foreground)
                    .frame(
                        width: style.waveBarWidth,
                        height: 2.4 + 9.6 * CGFloat(levels[index]))
                    .fixedSize()
            }
        }
        .animation(reduceMotion || !Motion.isEnabled ? nil : .linear(duration: 0.05), value: levels)
    }
}

/// Reads the live levels itself, so only the bars re-evaluate at the capture rate.
private struct DictationLiveWaveform: View {
    let state: DictationDisplayState
    let style: DictationIndicatorStyle

    var body: some View {
        DictationWaveform(levels: DictationIndicatorView.listeningLevels(state.levels), style: style)
    }
}

private struct DictationElapsedLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(verbatim: DictationIndicatorView.clock(seconds))
        }
        .font(Theme.Typography.dictationClock)
        .frame(minWidth: Theme.Size.dictationClockWidth)
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

    private struct ProcessingCycle: Equatable {
        let titles: [String]
        let runs: Bool
    }

    let style: DictationIndicatorStyle
    let phase: Phase
    let hidesStatusText: Bool
    var folding = false
    var levels: [Float] = []
    var liveLevels: DictationDisplayState?
    var idleHovered = false
    var remainingSeconds: Int?
    var processingStarted: Date?
    var cyclesWords = true
    var onStart: () -> Void = {}

    private var animates: Bool { !reduceMotion && Motion.isEnabled }

    private var morphAnimation: Animation? {
        animates ? .easeInOut(duration: Theme.Duration.dictationIndicatorMorph) : nil
    }

    static func clock(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    private var processingTitles: [String] {
        guard case .transcribing(let titles) = phase,
            style.showsProcessingText(hidesStatusText: hidesStatusText) else { return [] }
        return titles
    }

    var body: some View {
        let titles = processingTitles
        HStack(spacing: Theme.Spacing.dictationStatusGap) {
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
                if !hidesStatusText { Text("Starting…") }
            case .listening where style.isCompact, .transcribing where style.isCompact:
                ZStack {
                    if phase.isTranscribing {
                        DictationProcessingRing(ink: ink).transition(.opacity)
                    } else {
                        waveform.transition(.opacity)
                    }
                }
                .frame(width: phase.isTranscribing ? Theme.Size.dictationSpinnerDiameter : style.waveWidth)
            case .listening:
                waveform
                if !hidesStatusText {
                    Text("Listening")
                    if let remainingSeconds { countdown(remainingSeconds) }
                }
            case .transcribing:
                DictationProcessingRing(ink: ink)
                if !titles.isEmpty {
                    processingLabel(titles)
                    if let processingStarted {
                        DictationElapsedLabel(start: processingStarted).transition(.opacity)
                    }
                }
            }
        }
        .opacity(!folding && (phase.isIdle || contentReady) ? 1 : 0)
        .font(Theme.Typography.panelTitle)
        .padding(.horizontal, phase.isIdle ? 0 : style.horizontalInset)
        .frame(height: phase.isIdle && !idleHovered
            ? Theme.Size.dictationIdleHeight : Theme.Size.dictationIndicatorHeight)
        .background {
            GeometryReader { geometry in
                shape
                    .fill(folding ? Theme.Colors.dictationIdleBar : background)
                    .overlay {
                        shape.strokeBorder(borderInk, lineWidth: Theme.Size.dictationOutlineWidth)
                            .opacity(showsBorder && !folding ? 1 : 0)
                    }
                    .frame(width: folding ? Theme.Size.dictationIdleWidth : geometry.size.width,
                           height: folding ? Theme.Size.dictationIdleHeight : geometry.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .fixedSize()
        .animation(morphAnimation, value: phase.isIdle)
        .animation(morphAnimation, value: phase.isTranscribing)
        .animation(morphAnimation, value: idleHovered)
        .animation(processingResize, value: processingIndex)
        .animation(processingResize, value: processingStarted != nil)
        .animation(
            animates ? .easeInOut(duration: Theme.Duration.dictationCountdownFade) : nil,
            value: remainingSeconds != nil)
        .contentShape(shape)
        .onTapGesture { if phase.isIdle { onStart() } }
        .task(id: ProcessingCycle(titles: titles, runs: cyclesWords)) {
            await cycleProcessingTitles(count: cyclesWords ? titles.count : 0)
        }
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
        .accessibilityValue(Text(verbatim: remainingSeconds.map {
            Duration.seconds($0).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        } ?? ""))
        .accessibilityAddTraits(phase.isIdle ? .isButton : [])
    }

    private var processingResize: Animation? {
        animates ? .easeInOut(duration: Theme.Duration.dictationProcessingResize) : nil
    }

    @ViewBuilder private var waveform: some View {
        if let liveLevels {
            DictationLiveWaveform(state: liveLevels, style: style)
        } else {
            DictationWaveform(levels: Self.listeningLevels(levels), style: style)
        }
    }

    private func countdown(_ seconds: Int) -> some View {
        Text(verbatim: Self.clock(seconds))
            .font(Theme.Typography.dictationClock)
            .contentTransition(.numericText(countsDown: true))
            .animation(animates ? .easeInOut(duration: Theme.Duration.dictationCountdownDigit) : nil, value: seconds)
            .frame(minWidth: Theme.Size.dictationClockWidth)
            .transition(.opacity)
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

    static func listeningLevels(_ levels: [Float]) -> [Float] {
        let barCount = Theme.Size.dictationWaveBarCount
        let peaks = (0..<barCount).map { index in
            let start = index * levels.count / barCount
            let end = (index + 1) * levels.count / barCount
            return levels[start..<end].max() ?? 0
        }
        return peaks.indices.map { index in
            let left = peaks[max(0, index - 1)]
            let right = peaks[min(peaks.count - 1, index + 1)]
            return (left + 2 * peaks[index] + right) / 4
        }

    }
}

private struct DictationProcessingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    let ink: Color

    private var animates: Bool { !reduceMotion && Motion.isEnabled }

    var body: some View {
        let diameter = Theme.Size.dictationSpinnerDiameter
        let stroke = Theme.Size.dictationSpinnerStroke
        Circle()
            .strokeBorder(ink.opacity(0.14), lineWidth: stroke)
            .overlay {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .padding(stroke / 2)
                    .rotationEffect(.degrees(spinning ? 270 : -90))
            }
            .frame(width: diameter, height: diameter)
            .onAppear { spin(animates) }
            .onChange(of: animates) { spin(animates) }
    }

    private func spin(_ on: Bool) {
        let rotation = Animation.linear(duration: Theme.Duration.dictationSpinnerRotation)
            .repeatForever(autoreverses: false)
        withTransaction(Transaction(animation: on ? rotation : nil)) { spinning = on }
    }
}

private struct DictationTranscribingLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false
    let title: String
    let ink: Color

    private var animates: Bool { !reduceMotion && Motion.isEnabled }

    var body: some View {
        Text(verbatim: title)
            .foregroundStyle(animates ? ink.opacity(0.72) : ink)
            .overlay {
                if animates {
                    Text(verbatim: title)
                        .foregroundStyle(ink)
                        .mask { highlight }
                }
            }
            .onAppear { sweep(animates) }
            .onChange(of: animates) { sweep(animates) }
    }

    private var highlight: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.6)
                .offset(x: proxy.size.width * (sweeping ? 1 : -0.6))
        }
    }

    private func sweep(_ on: Bool) {
        let pass = Animation.linear(duration: Theme.Duration.dictationTranscribingShimmer)
            .repeatForever(autoreverses: false)
        withTransaction(Transaction(animation: on ? pass : nil)) { sweeping = on }
    }
}

struct DictationProcessingWidth: View {
    let style: DictationIndicatorStyle
    var showsElapsed = false

    var body: some View {
        let titles = DictationIndicatorView.Phase.processingLabels
        HStack(spacing: Theme.Spacing.dictationStatusGap) {
            Color.clear.frame(width: Theme.Size.dictationSpinnerDiameter, height: 0)
            ZStack {
                ForEach(titles.indices, id: \.self) { index in
                    Text(verbatim: titles[index])
                }
            }
            if showsElapsed { Color.clear.frame(width: Theme.Size.dictationClockWidth, height: 0) }
        }
        .font(Theme.Typography.panelTitle)
        .padding(.horizontal, style.horizontalInset)
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
    var folding = false
    var maximumWidth = Theme.Size.dictationPreviewWidth
    @State private var displayedText = ""
    @State private var words: [Substring] = []
    @State private var reveals: [Int: WordReveal] = [:]
    @State private var outgoing: [OutgoingWord] = []

    private struct TranscriptUpdate: Equatable {
        let text: String
        let animated: Bool
        let twoLines: Bool
    }

    private struct WordReveal {
        let start: Date
        var previous: String?
        var previousInk: Color?

        var end: Date { start.addingTimeInterval(Theme.Duration.dictationWordFade) }

        func color(at date: Date, accent: Color, ink: Color) -> Color {
            let progress = min(1, max(0, date.timeIntervalSince(start) / Theme.Duration.dictationWordFade))
            let blend = min(1, max(0, (progress - 0.3) / 0.7))
            let opacity = previous == nil
                ? 0.16 + 0.84 * min(1, progress / 0.46)
                : min(1, max(0, date.timeIntervalSince(start) / Theme.Duration.dictationCorrectionFade))
            return accent.mix(with: ink, by: blend * blend * (3 - 2 * blend)).opacity(opacity)
        }
    }

    private struct OutgoingWord: Identifiable {
        let id: Int
        let lineStart: Int
        let x: CGFloat
        let width: CGFloat
        let text: String
        let ink: Color
        let start: Date
    }

    private var accent: Color { style.isDark ? Theme.Colors.dictationDarkLiveInk : Theme.Colors.dictationLightLiveInk }
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
    private static let verticalInset = Theme.Spacing.dictationTranscriptVerticalInset

    static func maximumHeight(twoLines: Bool) -> CGFloat {
        lineHeight + (twoLines ? lineStride : 0) + 2 * verticalInset
    }

    private var lineAnimation: Animation? {
        usesMotion ? .easeInOut(duration: Theme.Duration.dictationPreviewLineShift) : nil
    }

    private var maximumTextWidth: CGFloat {
        maximumWidth - 2 * Theme.Spacing.dictationTranscriptInset
    }

    private func measuredWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: Self.transcriptFont
        ]).width)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reveals.isEmpty || !usesMotion)) { timeline in
            transcriptViewport(at: timeline.date)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: transcript))
        .opacity(folding ? 0 : 1)
        .animation(usesMotion ? .easeInOut(duration: Theme.Duration.dictationPreviewLineShift / 2) : nil, value: folding)
        .task(id: TranscriptUpdate(text: transcript, animated: usesMotion, twoLines: twoLines)) {
            let next = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            await revealWords(in: next)
        }
        .padding(.horizontal, Theme.Spacing.dictationTranscriptInset)
        .padding(.vertical, Self.verticalInset)
        .foregroundStyle(ink)
        .background(
            style.backgroundColor,
            in: RoundedRectangle(cornerRadius: Theme.Radius.dictationTranscript))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.dictationTranscript)
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
                rollingLines(text, lines: lines, at: date)
            } else {
                transcriptLine(text, startingAt: 0, at: date)
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

    private func revealWords(in source: String) async {
        updateText(source)
        let old = words
        words = DictationPreviewSequence.words(in: source)
        guard usesMotion else {
            reveals = [:]
            outgoing = []
            return
        }
        let edits = DictationPreviewSequence.wordEdits(from: old, to: words)
        let now = Date()
        var active: [Int: WordReveal] = [:]
        var delay: TimeInterval = 0
        for (index, edit) in edits.enumerated() {
            switch edit {
            case .inserted:
                active[index] = WordReveal(start: now.addingTimeInterval(delay))
                delay = min(Theme.Duration.dictationBatchDelay, delay + Theme.Duration.dictationWordStagger)
            case .kept(let prior), .followsDeletion(let prior):
                if let reveal = reveals[prior], reveal.end > now { active[index] = reveal }
            case .replaced(let prior):
                let oldInk = reveals[prior]?.color(at: now, accent: accent, ink: ink) ?? ink
                active[index] = WordReveal(start: now, previous: String(old[prior]), previousInk: oldInk)
            }
        }
        reveals = active
        outgoing = outgoingWords(for: active, in: source, at: now)
        guard let end = active.values.map(\.end).max() else { return }
        do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
        reveals = [:]
        outgoing = []
    }

    private func outgoingWords(for active: [Int: WordReveal], in source: String, at now: Date) -> [OutgoingWord] {
        let replacements = active.filter { _, reveal in
            reveal.previous != nil && now.timeIntervalSince(reveal.start) < Theme.Duration.dictationCorrectionFade
        }
        guard !replacements.isEmpty else { return [] }
        let lines = twoLines ? Array(wrappedLines.suffix(2)) : [NSRange(source.startIndex..., in: source)]
        var result: [OutgoingWord] = []
        for line in lines {
            guard let range = Range(line, in: source) else { continue }
            let attributed = NSAttributedString(string: String(source[range]), attributes: [.font: Self.transcriptFont])
            let layout = CTLineCreateWithAttributedString(attributed)
            for (index, reveal) in replacements {
                let word = words[index]
                guard let previous = reveal.previous, let oldInk = reveal.previousInk,
                      range.contains(word.startIndex), word.endIndex <= range.upperBound else { continue }
                let location = NSRange(word.startIndex..<word.endIndex, in: source)
                let start = CTLineGetOffsetForStringIndex(layout, location.location - line.location, nil)
                let end = CTLineGetOffsetForStringIndex(layout, NSMaxRange(location) - line.location, nil)
                result.append(OutgoingWord(id: index, lineStart: line.location, x: min(start, end), width: abs(end - start),
                                           text: previous, ink: oldInk, start: reveal.start))
            }
        }
        return result
    }

    private func transcriptLine(_ text: AttributedString, startingAt lineStart: Int, at date: Date) -> some View {
        Text(text)
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    ForEach(outgoing) { word in
                        let fade = date.timeIntervalSince(word.start) / Theme.Duration.dictationCorrectionFade
                        if usesMotion, word.lineStart == lineStart, fade < 1 {
                            Text(verbatim: word.text)
                                .foregroundStyle(word.ink)
                                .fixedSize()
                                .frame(width: word.width, alignment: .leading)
                                .clipped()
                                .opacity(1 - max(0, fade))
                                .offset(x: word.x)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.Typography.dictationTranscript)
            .lineLimit(1)
            .contentTransition(.identity)
            .fixedSize(horizontal: true, vertical: false)
            .transaction { $0.animation = nil }
    }

    private func rollingLines(_ text: AttributedString, lines: ArraySlice<NSRange>, at date: Date) -> some View {
        let stride = Self.lineStride
        let source = displayedText
        return ZStack(alignment: .topLeading) {
            ForEach(Array(lines.indices), id: \.self) { index in
                if let range = Range(lines[index], in: source),
                    let start = AttributedString.Index(range.lowerBound, within: text),
                    let end = AttributedString.Index(range.upperBound, within: text)
                {
                    transcriptLine(AttributedString(text[start..<end]), startingAt: lines[index].location, at: date)
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
        var result = AttributedString(displayedText)
        guard usesMotion else { return result }
        for (index, reveal) in reveals where reveal.end > date {
            let word = words[index]
            guard let start = AttributedString.Index(word.startIndex, within: result),
                  let end = AttributedString.Index(word.endIndex, within: result) else { continue }
            result[start..<end].foregroundColor = reveal.color(at: date, accent: accent, ink: ink)
        }
        return result
    }
}

private struct DictationPanelView: View {
    @State private var previewWidth: CGFloat = 0
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
            if !phase.isIdle && style.showsProcessingText(hidesStatusText: state.hidesStatusText) {
                DictationProcessingWidth(style: style, showsElapsed: state.showsElapsed)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onProcessingWidthChanged($0) }
                    .frame(width: phase.isTranscribing ? nil : 0, height: 0)
            }
            panelContents
        }
        .frame(
            minWidth: minimumPanelWidth,
            minHeight: Theme.Size.dictationIndicatorHeight, alignment: .bottom)
        .motionScope()
    }

    var minimumPanelWidth: CGFloat {
        if !state.transcript.isEmpty { return Theme.Size.dictationPreviewWidth }
        guard style.isCompact, phase.isTranscribing else { return 0 }
        return style.waveWidth + 2 * style.horizontalInset
    }

    private var previewOffset: CGFloat {
        let freeHalfWidth = max(0, state.panelWidth - previewWidth) / 2
        let edgeOffset = (previewWidth - state.indicatorWidth) / 2 * state.previewAlignment
        return min(max(state.indicatorOffset + edgeOffset, -freeHalfWidth), freeHalfWidth)
    }

    private var panelContents: some View {
        ZStack(alignment: state.previewBelow ? .top : .bottom) {
            if !state.transcript.isEmpty {
                DictationTranscriptView(
                    transcript: state.transcript, animates: state.animatesTranscript,
                    twoLines: state.twoLinePreview, style: style, folding: state.foldingCard)
                    .scaleEffect(x: state.foldingCard ? 0.16 : 1, y: state.foldingCard ? 0 : 1,
                                 anchor: state.previewBelow ? .top : .bottom)
                    .offset(y: state.foldingCard ? (state.previewBelow ? -Theme.Spacing.md : Theme.Spacing.md) : 0)
                    .opacity(state.foldingCard ? 0 : 1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
                    .offset(x: previewOffset)
                    .frame(height: DictationTranscriptView.maximumHeight(twoLines: state.twoLinePreview),
                           alignment: state.previewBelow ? .top : .bottom)
                    .padding(state.previewBelow ? .top : .bottom,
                             Theme.Size.dictationIndicatorHeight + Theme.Spacing.md)
                    .opacity(state.previewPaused ? 0 : 1)
                    .animation(
                        reduceMotion || !Motion.isEnabled || !state.animatesTranscript
                            ? nil : .easeInOut(duration: Theme.Duration.dictationPreviewLineShift),
                        value: state.previewPaused)
                    .accessibilityHidden(state.previewPaused || state.foldingCard)
            }
            DictationIndicatorView(
                style: style, phase: phase, hidesStatusText: state.hidesStatusText, folding: state.foldingPill,
                liveLevels: state, idleHovered: state.idleHovered,
                remainingSeconds: state.remainingSeconds,
                processingStarted: state.showsElapsed ? state.processingStarted : nil, onStart: onStart)
                .overlay {
                    WindowDragHandle(
                        onBegan: onDragBegan, onEnded: onDragEnded,
                        onClick: { if phase.isIdle { onStart() } }, onMoved: onDragMoved)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.indicatorWidth = $0 }
                .offset(
                    x: state.indicatorOffset + (state.foldingPill ? state.idleCenterShift : 0),
                    y: state.foldingPill || (phase.isIdle && !state.idleHovered) ? -state.idleLift : 0)
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
    private var dragStartCenterOffset: CGFloat = 0
    private var dragStartLift: CGFloat = 0
    private var dragOwner: pid_t?
    private var dragSourceDisplay: String?
    private var chosenDisplay: String?
    private var processingWidth: CGFloat = 0
    private var observers: [NotificationToken] = []
    private var presentationObservation: NSKeyValueObservation?
    private var placementTimer: Timer?
    private var dockLookup: Task<Void, Never>?
    private var dockAccessibilityBounds: CGRect?
    private var hoverTracking: NSTrackingArea?
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
        updatePlacementTimer()
    }

    override var canBecomeKey: Bool { !host.rootView.phase.isIdle && !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    func setStyle(_ style: DictationIndicatorStyle) { host.rootView.style = style }
    func setStartAction(_ action: (() -> Void)?) {
        onStart = action
        host.rootView.onStart = { action?() }
    }

    func show(_ phase: DictationIndicatorView.Phase) {
        let previous = frame
        let previousPillY = previous.minY + pillLift
        let root = host.rootView
        let reserveWidth = phase.isTranscribing && root.phase.isTranscribing
            && root.style.showsProcessingText(hidesStatusText: root.state.hidesStatusText)
        if !phase.isIdle { stopWatchingIdleHover() }
        host.rootView.phase = phase
        hasShadow = host.rootView.style.isDark && !phase.isIdle
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let width = reserveWidth ? max(previous.width, size.width) : size.width
        let destination = NSRect(
            x: previous.midX - width / 2, y: previousPillY - pillLift(for: size.height),
            width: width, height: size.height)
        setFrame(destination, display: true)
        updatePlacementTimer()
        if dragging, let dragScreen, let dragBottom {
            let origin = panelOrigin(
                center: previous.midX + host.rootView.state.indicatorOffset,
                pillY: previousPillY, on: dragScreen, bottom: dragBottom)
            setFrameOrigin(origin)
        } else {
            reposition()
        }
    }

    func refit() { show(host.rootView.phase) }

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
        let origin = panelOrigin(center: centerX, pillY: y, on: screen, bottom: bottom)
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    private var hasPreview: Bool { !host.rootView.state.transcript.isEmpty }

    private var pillLift: CGFloat {
        host.rootView.state.previewBelow ? max(0, frame.height - Theme.Size.dictationIndicatorHeight) : 0
    }

    private func pillLift(for height: CGFloat) -> CGFloat {
        hasPreview && host.rootView.state.previewBelow ? max(0, height - Theme.Size.dictationIndicatorHeight) : 0
    }

    private func top(on screen: NSScreen) -> CGFloat {
        screen.visibleFrame.maxY - Theme.Spacing.dictationPanelBottomInset
    }

    private func panelOrigin(center: CGFloat, pillY: CGFloat, on screen: NSScreen, bottom: CGFloat) -> CGPoint {
        let state = host.rootView.state
        let pillHeight = hasPreview ? Theme.Size.dictationIndicatorHeight : frame.height
        let upperLimit = max(bottom, top(on: screen) - pillHeight)
        let y = min(max(pillY, bottom), upperLimit)
        let roomAbove = upperLimit - y
        let previewHeight = max(0, frame.height - pillHeight)
        let below = hasPreview && previewHeight > roomAbove && y - bottom > roomAbove
        let idleCenter = clampedCenter(center, on: screen, width: Theme.Size.dictationIdleWidth)
        let center = clampedCenter(center, on: screen, width: placementWidth)
        let idleCenterShift = idleCenter - center
        let verticalFraction = upperLimit > bottom ? (y - bottom) / (upperLimit - bottom) : 0
        let idleLift = verticalFraction * (Theme.Size.dictationIndicatorHeight - Theme.Size.dictationIdleHeight)
        if state.idleCenterShift != idleCenterShift { state.idleCenterShift = idleCenterShift }
        if state.idleLift != idleLift { state.idleLift = idleLift }
        let visible = screen.visibleFrame
        let inset = Theme.Spacing.dictationPanelBottomInset
        let minX = visible.minX + inset
        let maxX = max(minX, visible.maxX - frame.width - inset)
        let alignment: CGFloat = if center < visible.minX + visible.width / 3 {
            1
        } else if center > visible.maxX - visible.width / 3 {
            -1
        } else {
            0
        }
        let indicatorWidth = min(max(state.indicatorWidth, 1), frame.width)
        let edgeOffset = hasPreview ? (frame.width - indicatorWidth) / 2 * alignment : 0
        let x = min(max(center + edgeOffset - frame.width / 2, minX), maxX)
        if state.previewAlignment != alignment { state.previewAlignment = alignment }
        if state.panelWidth != frame.width { state.panelWidth = frame.width }
        if state.previewBelow != below { state.previewBelow = below }
        let offset = center - (x + frame.width / 2)
        if state.indicatorOffset != offset { state.indicatorOffset = offset }
        return CGPoint(x: x, y: y - (below ? previewHeight : 0))
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
            if refreshDock, dockAccessibilityBounds == nil { refreshDockAccessibilityBounds() }
            if let dockAccessibilityBounds {
                bottom = bottomDockTop(for: dockAccessibilityBounds, on: screen) ?? bounds.minY
            } else {
                bottom = reservesDockSpace && !hidesDock && !geometry.windowFillsDisplay ? visible.minY : bounds.minY
            }
        }
        return bottom + Theme.Spacing.dictationPanelBottomInset
    }

    private func clampedCenter(_ center: CGFloat, on screen: NSScreen, width: CGFloat) -> CGFloat {
        let inset = Theme.Spacing.dictationPanelBottomInset
        let half = width / 2
        let minimum = screen.visibleFrame.minX + inset + half
        let maximum = max(minimum, screen.visibleFrame.maxX - inset - half)
        return min(max(center, minimum), maximum)
    }

    private var placementWidth: CGFloat {
        let root = host.rootView
        if root.phase.isIdle {
            return root.state.idleHovered ? Theme.Size.dictationIdleHoverWidth : Theme.Size.dictationIdleWidth
        }
        if root.style.isCompact, root.phase.isTranscribing { return root.minimumPanelWidth }
        let indicatorWidth = min(max(root.state.indicatorWidth, 2), frame.width)
        guard root.style.showsProcessingText(hidesStatusText: root.state.hidesStatusText), processingWidth > 0 else {
            return indicatorWidth
        }
        if root.phase.isTranscribing { return min(processingWidth, frame.width) }
        return max(indicatorWidth, processingWidth)
    }

    private func beginDrag() {
        dragging = true
        updatePlacementTimer()
        guidesVisible = false
        snappedX = false
        snappedY = false
        dragScreen = nil
        dragBottom = nil
        dragStartCenterOffset = frame.width / 2 + host.rootView.state.indicatorOffset
        dragStartLift = pillLift
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
        let bounds = screen.frame
        let visible = screen.visibleFrame
        let inset = Theme.Spacing.dictationPanelBottomInset
        let indicatorWidth = min(max(host.rootView.state.indicatorWidth, 1), frame.width)
        let pillHeight = hasPreview ? Theme.Size.dictationIndicatorHeight : frame.height
        let maxY = max(bottom, top(on: screen) - pillHeight)
        let y = min(max(point.y + dragStartLift, bottom), maxY)
        let center = clampedCenter(point.x + dragStartCenterOffset, on: screen, width: placementWidth)
        let xs = [visible.minX + inset + placementWidth / 2, visible.midX,
                  visible.maxX - inset - placementWidth / 2]
        let ys = [bottom, min(max(bounds.midY - pillHeight / 2, bottom), maxY), maxY]
        let targetX = xs.min { abs($0 - center) < abs($1 - center) } ?? center
        let targetY = ys.min { abs($0 - y) < abs($1 - y) } ?? y
        let distance = Theme.Size.paletteSnapDistance
        let hitX = abs(targetX - center) <= distance * (snappedX ? 2 : 1)
        let hitY = abs(targetY - y) <= distance * (snappedY ? 2 : 1)
        let result = panelOrigin(
            center: hitX ? targetX : center, pillY: hitY ? targetY : y, on: screen, bottom: bottom)
        let home = CGPoint(x: targetX - indicatorWidth / 2, y: targetY + pillHeight)
        let dragged = CGPoint(x: center - indicatorWidth / 2, y: y + pillHeight)
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
            updatePlacementTimer()
        }
        guard dragging, isVisible, let screen = dragScreen else { return }
        let bounds = screen.frame
        let x = min(max((frame.midX + host.rootView.state.indicatorOffset - bounds.minX) / bounds.width, 0), 1)
        let y = min(max((frame.minY + pillLift - bounds.minY) / bounds.height, 0), 1)
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
        presentationObservation = NSApp.observe(
            \.currentSystemPresentationOptions, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.reposition() }
        }
    }

    /// Window moves and Dock reveals have no notification, so only an active pill polls for them.
    private func updatePlacementTimer() {
        let needed = dragging || !host.rootView.phase.isIdle
        guard needed != (placementTimer != nil) else { return }
        guard needed else {
            placementTimer?.invalidate()
            placementTimer = nil
            return
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        placementTimer = timer
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
        if hoverTracking == nil {
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            host.addTrackingArea(area)
            hoverTracking = area
        }
        ignoresMouseEvents = false
        updateIdleHover()
    }

    private func stopWatchingIdleHover() {
        if let hoverTracking { host.removeTrackingArea(hoverTracking) }
        hoverTracking = nil
        host.rootView.state.idleHovered = false
    }

    override func mouseEntered(with event: NSEvent) { updateIdleHover() }

    override func mouseExited(with event: NSEvent) { updateIdleHover() }

    private func updateIdleHover() {
        guard isVisible, hoverTracking != nil, host.rootView.phase.isIdle else { return }
        let inside = frame.contains(NSEvent.mouseLocation)
        guard inside != host.rootView.state.idleHovered else { return }
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
    private var transitionTask: Task<Void, Never>?
    private var collapseID: UUID?
    private var previewPauseTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        state.hidesStatusText = settings.dictationHideIndicatorText
    }

    func applyTextVisibility() {
        guard state.hidesStatusText != settings.dictationHideIndicatorText else { return }
        state.hidesStatusText = settings.dictationHideIndicatorText
        panel?.refit()
    }

    private var animatesTransitions: Bool {
        Motion.isEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func cancelTransition() {
        collapseID = nil
        transitionTask?.cancel()
        transitionTask = nil
        state.foldingCard = false
        state.foldingPill = false
    }

    func showStarting(style: DictationIndicatorStyle) {
        cancelTransition()
        let screen = DictationPanel.activeScreen
        guard let screen else { return }
        state.levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
        resetClocks()
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
        cancelTransition()
        stopWatchingForEscape()
        resetClocks()
        let screen = DictationPanel.activeScreen
        guard let screen else { return }
        if let panel, panel.isVisible {
            previewPauseTask?.cancel()
            previewPauseTask = nil
            state.previewPaused = false
            state.transcript = ""
            panel.setStyle(style)
            panel.show(.idle)
            panel.resignKey()
            panel.setStartAction(onStart)
            panel.watchIdleHover()
            return
        }
        close()
        let panel = DictationPanel(rootView: DictationPanelView(state: state, style: style, phase: .idle), settings: settings)
        panel.setStartAction(onStart)
        self.panel = panel
        panel.position(on: screen)
        panel.orderFrontRegardless()
        panel.watchIdleHover()
    }

    func showListening() { panel?.show(.listening) }

    func showCountdown(_ seconds: Int) {
        let appeared = state.remainingSeconds == nil
        state.remainingSeconds = seconds
        switch seconds {
        case 60: AccessibilityNotification.Announcement(String(localized: "One minute of recording left")).post()
        case 10: AccessibilityNotification.Announcement(String(localized: "Ten seconds of recording left")).post()
        default: break
        }
        if appeared { panel?.show(.listening) }
    }

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

    func releaseForDelivery() {
        stopWatchingForEscape()
        resetClocks()
        panel?.ignoresMouseEvents = true
        panel?.resignKey()
    }

    func collapsePill(onDismiss: @escaping @MainActor () -> Void) {
        guard panel?.isVisible == true, animatesTransitions else { onDismiss(); return }
        let id = UUID()
        collapseID = id
        withAnimation(.easeInOut(duration: Theme.Duration.dictationPillCollapse), completionCriteria: .removed) {
            state.foldingPill = true
        } completion: { [weak self] in
            guard let self, collapseID == id else { return }
            collapseID = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onDismiss() }
        }
    }

    func waitForCardToClose() async {
        await transitionTask?.value
    }

    func showTranscribing() {
        previewPauseTask?.cancel()
        previewPauseTask = nil
        resetClocks()
        state.levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
        guard !state.transcript.isEmpty, !state.previewPaused, state.animatesTranscript, animatesTransitions else {
            beginProcessing()
            return
        }
        let duration = Theme.Duration.dictationPreviewLineShift
        withAnimation(.easeInOut(duration: duration)) { state.foldingCard = true }
        transitionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration + Theme.Duration.dictationCardToProcessing)) } catch { return }
            guard let self else { return }
            transitionTask = nil
            beginProcessing()
        }
    }

    private func beginProcessing() {
        state.transcript = ""
        state.foldingCard = false
        state.processingStarted = .now
        elapsedTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Theme.Duration.dictationElapsedDelay)) } catch { return }
            guard let self, !Task.isCancelled, state.processingStarted != nil else { return }
            state.showsElapsed = true
            panel?.refit()
        }
        panel?.show(.randomTranscribing())
    }

    private func resetClocks() {
        elapsedTask?.cancel()
        elapsedTask = nil
        state.remainingSeconds = nil
        state.processingStarted = nil
        state.showsElapsed = false
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
        cancelTransition()
        stopWatchingForEscape()
        resetClocks()
        previewPauseTask?.cancel()
        previewPauseTask = nil
        state.previewPaused = false
        state.transcript = ""
        state.remainingSeconds = nil
        panel?.stopObservingPlacementChanges()
        panel?.orderOut(nil)
        panel = nil
    }
}
