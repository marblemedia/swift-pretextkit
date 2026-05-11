import Foundation

// MARK: - Prepared Segment Builder

/// Collects measured segments during the measurement phase, handling CJK grapheme splitting.
struct PreparedSegmentBuilder {
    var widths: [Float] = []
    var lineEndFitAdvances: [Float] = []
    var lineEndPaintAdvances: [Float] = []
    var kinds: [SegmentBreakKind] = []
    var breakAfterFlags: [Bool] = []
    var breakableWidths: [ContiguousArray<Float>?] = []
    var segments: [String] = []
    var simpleLineWalkFastPath = true

    /// Pre-allocate arrays when the segment count is known (non-CJK texts).
    mutating func reserveCapacity(_ n: Int) {
        widths.reserveCapacity(n)
        lineEndFitAdvances.reserveCapacity(n)
        lineEndPaintAdvances.reserveCapacity(n)
        kinds.reserveCapacity(n)
        breakAfterFlags.reserveCapacity(n)
        breakableWidths.reserveCapacity(n)
        segments.reserveCapacity(n)
    }

    mutating func push(
        text: String,
        width: Float,
        fitAdvance: Float,
        paintAdvance: Float,
        kind: SegmentBreakKind,
        breakable: ContiguousArray<Float>? = nil
    ) {
        widths.append(width)
        lineEndFitAdvances.append(fitAdvance)
        lineEndPaintAdvances.append(paintAdvance)
        kinds.append(kind)
        breakAfterFlags.append(segmentBreaksAfter(text: text, kind: kind))
        breakableWidths.append(breakable)
        segments.append(text)
        if kind != .text && kind != .breakableText && kind != .space && kind != .zeroWidthBreak {
            simpleLineWalkFastPath = false
        }
    }
}

// MARK: - Main Measurement

/// Result of measurement: the PreparedCore plus the expanded segment texts
/// (which may differ from analysis segments due to CJK splitting).
struct MeasurementResult {
    let core: PreparedCore
    let segments: [String]
}

/// Measures all segments in the analysis and builds the PreparedCore.
///
/// Key difference from a naive port: CJK text segments are split into
/// individual graphemes (with kinsoku merging) so each CJK character
/// becomes its own segment in the prepared data. This matches how
/// CTFramesetter breaks CJK text.
func measureAnalysis(
    _ analysis: TextAnalysis,
    font: FontDescriptor,
    measurer: any SegmentMeasuring,
    profiler: InternalPrepareProfiler? = nil
) -> MeasurementResult {
    let seg = analysis.segmentation
    var builder = PreparedSegmentBuilder()
    builder.reserveCapacity(seg.count)

    let staticMetricsStart = profiler.map { _ in DispatchTime.now().uptimeNanoseconds }
    let needsTabStop = seg.kinds.contains(.tab)
    let needsSoftHyphen = seg.kinds.contains(.softHyphen)
    let tabStopAdvance = needsTabStop ? measurer.measureSpaceWidth() * 8 : 0
    let hyphenWidth = needsSoftHyphen ? measurer.measureHyphenWidth() : 0
    if let profiler, let staticMetricsStart {
        profiler.staticMetricsNs += DispatchTime.now().uptimeNanoseconds - staticMetricsStart
    }

    let segmentLoopStart = profiler.map { _ in DispatchTime.now().uptimeNanoseconds }
    for i in 0..<seg.count {
        let text = seg.texts[i]
        let kind = seg.kinds[i]
        let isWord = seg.isWordLike[i]

        switch kind {
        case .softHyphen:
            builder.push(text: text, width: 0, fitAdvance: hyphenWidth, paintAdvance: hyphenWidth, kind: kind)

        case .hardBreak:
            builder.push(text: text, width: 0, fitAdvance: 0, paintAdvance: 0, kind: kind)

        case .tab:
            builder.push(text: text, width: 0, fitAdvance: 0, paintAdvance: 0, kind: kind)

        case .space:
            let w = sharedMetricsCache.getOrMeasure(text, font: font, measurer: measurer, profiler: profiler).width
            builder.push(text: text, width: w, fitAdvance: 0, paintAdvance: 0, kind: kind)

        case .preservedSpace:
            let w = sharedMetricsCache.getOrMeasure(text, font: font, measurer: measurer, profiler: profiler).width
            builder.push(text: text, width: w, fitAdvance: 0, paintAdvance: 0, kind: kind)

        case .glue:
            let w = sharedMetricsCache.getOrMeasure(text, font: font, measurer: measurer, profiler: profiler).width
            builder.push(text: text, width: w, fitAdvance: w, paintAdvance: w, kind: kind)

        case .zeroWidthBreak:
            builder.push(text: text, width: 0, fitAdvance: 0, paintAdvance: 0, kind: kind)

        case .text, .breakableText:
            if isWord && text.count > 1 {
                if let cachedMetrics = sharedMetricsCache.metrics(for: text, font: font) {
                    profiler?.cacheHits += 1
                    if cachedMetrics.containsCJK {
                        profiler?.cjkSplitSegments += 1
                        splitCJKIntoGraphemes(text, font: font, measurer: measurer, builder: &builder, profiler: profiler)
                    } else {
                        let breakable = sharedMetricsCache.getOrMeasureGraphemeWidths(text, font: font, measurer: measurer, profiler: profiler)
                        builder.push(
                            text: text,
                            width: cachedMetrics.width,
                            fitAdvance: cachedMetrics.width,
                            paintAdvance: cachedMetrics.width,
                            kind: .text,
                            breakable: breakable
                        )
                    }
                } else {
                    profiler?.cacheMisses += 1
                    if isCJK(text) {
                        let width = measurer.measureWidth(text)
                        let metrics = SegmentMetrics(width: width, containsCJK: true)
                        sharedMetricsCache.store(metrics, for: text, font: font)
                        profiler?.cjkSplitSegments += 1
                        splitCJKIntoGraphemes(text, font: font, measurer: measurer, builder: &builder, profiler: profiler)
                    } else if let cachedBreakable = sharedMetricsCache.graphemeWidths(for: text, font: font) {
                        profiler?.graphemeCacheHits += 1
                        let width = measurer.measureWidth(text)
                        let metrics = SegmentMetrics(width: width, containsCJK: false)
                        sharedMetricsCache.store(metrics, for: text, font: font)
                        builder.push(text: text, width: width, fitAdvance: width, paintAdvance: width, kind: .text, breakable: cachedBreakable)
                    } else {
                        profiler?.graphemeCacheMisses += 1
                        let measured = measurer.measureSegmentAndGraphemeWidths(text)
                        let metrics = SegmentMetrics(width: measured.width, containsCJK: false)
                        sharedMetricsCache.store(metrics, for: text, font: font)
                        sharedMetricsCache.storeGraphemeWidths(measured.graphemeWidths, for: text, font: font)
                        builder.push(
                            text: text,
                            width: measured.width,
                            fitAdvance: measured.width,
                            paintAdvance: measured.width,
                            kind: .text,
                            breakable: measured.graphemeWidths
                        )
                    }
                }
            } else {
                let metrics = sharedMetricsCache.getOrMeasure(text, font: font, measurer: measurer, profiler: profiler)
                if metrics.containsCJK {
                    profiler?.cjkSplitSegments += 1
                    splitCJKIntoGraphemes(text, font: font, measurer: measurer, builder: &builder, profiler: profiler)
                } else {
                    builder.push(text: text, width: metrics.width, fitAdvance: metrics.width, paintAdvance: metrics.width, kind: .text)
                }
            }
        }
    }
    if let profiler, let segmentLoopStart {
        profiler.segmentLoopNs += DispatchTime.now().uptimeNanoseconds - segmentLoopStart
    }

    // CJK splitting changes segment count, so chunk boundaries must be remapped.
    let chunks: [PreparedLineChunk]
    let chunkBuildStart = profiler.map { _ in DispatchTime.now().uptimeNanoseconds }
    if analysis.chunks.count <= 1 {
        if builder.widths.isEmpty {
            chunks = []
        } else {
            chunks = [PreparedLineChunk(
                startSegmentIndex: 0,
                endSegmentIndex: builder.widths.count,
                consumedEndSegmentIndex: builder.widths.count
            )]
        }
    } else {
        chunks = remapChunksFromBuilder(builder)
    }
    if let profiler, let chunkBuildStart {
        profiler.chunkBuildNs += DispatchTime.now().uptimeNanoseconds - chunkBuildStart
    }

    let coreBuildStart = profiler.map { _ in DispatchTime.now().uptimeNanoseconds }
    let core = PreparedCore(
        widths: builder.widths,
        lineEndFitAdvances: builder.lineEndFitAdvances,
        lineEndPaintAdvances: builder.lineEndPaintAdvances,
        kinds: builder.kinds,
        breakAfterFlags: builder.breakAfterFlags,
        simpleLineWalkFastPath: builder.simpleLineWalkFastPath,
        breakableWidths: builder.breakableWidths,
        discretionaryHyphenWidth: hyphenWidth,
        tabStopAdvance: tabStopAdvance,
        chunks: chunks
    )
    if let profiler, let coreBuildStart {
        profiler.coreBuildNs += DispatchTime.now().uptimeNanoseconds - coreBuildStart
    }
    return MeasurementResult(core: core, segments: builder.segments)
}

private func segmentBreaksAfter(text: String, kind: SegmentBreakKind) -> Bool {
    if kind.canBreakAfter { return true }
    guard kind == .text, let last = text.unicodeScalars.last else { return false }
    return last == "-"
}

// MARK: - CJK Grapheme Splitting

/// Splits a CJK-containing segment into individual graphemes, applying kinsoku rules.
///
/// Kinsoku-end characters (opening brackets) stick to the following grapheme.
/// Kinsoku-start characters (closing brackets, periods) stick to the preceding grapheme.
private func splitCJKIntoGraphemes(
    _ text: String,
    font: FontDescriptor,
    measurer: any SegmentMeasuring,
    builder: inout PreparedSegmentBuilder,
    profiler: InternalPrepareProfiler? = nil
) {
    var unitText = ""

    for char in text {
        let grapheme = String(char)

        if unitText.isEmpty {
            unitText = grapheme
            continue
        }

        let graphemeScalar = grapheme.unicodeScalars.first!

        if isKinsokuEndUnit(unitText)
            || kinsokuStartScalars.contains(graphemeScalar)
            || leftStickyPunctuation.contains(graphemeScalar) {
            unitText += grapheme
            continue
        }

        let w = sharedMetricsCache.getOrMeasure(unitText, font: font, measurer: measurer, profiler: profiler).width
        builder.push(text: unitText, width: w, fitAdvance: w, paintAdvance: w, kind: .breakableText)

        unitText = grapheme
    }

    if !unitText.isEmpty {
        let w = sharedMetricsCache.getOrMeasure(unitText, font: font, measurer: measurer, profiler: profiler).width
        builder.push(text: unitText, width: w, fitAdvance: w, paintAdvance: w, kind: .breakableText)
    }
}

/// Whether the text consists only of kinsoku-end (line-end prohibited) characters.
private func isKinsokuEndUnit(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        if !kinsokuEndScalars.contains(scalar) { return false }
    }
    return !text.isEmpty
}

// MARK: - Chunk Remapping

/// Rebuild chunk boundaries from the builder output for pre-wrap mode.
private func remapChunksFromBuilder(_ builder: PreparedSegmentBuilder) -> [PreparedLineChunk] {
    var chunks: [PreparedLineChunk] = []
    var chunkStart = 0

    for i in 0..<builder.kinds.count {
        if builder.kinds[i] == .hardBreak {
            chunks.append(PreparedLineChunk(
                startSegmentIndex: chunkStart,
                endSegmentIndex: i,
                consumedEndSegmentIndex: i + 1
            ))
            chunkStart = i + 1
        }
    }

    if chunkStart < builder.kinds.count {
        chunks.append(PreparedLineChunk(
            startSegmentIndex: chunkStart,
            endSegmentIndex: builder.kinds.count,
            consumedEndSegmentIndex: builder.kinds.count
        ))
    } else if chunks.isEmpty && !builder.kinds.isEmpty {
        chunks.append(PreparedLineChunk(
            startSegmentIndex: 0,
            endSegmentIndex: builder.kinds.count,
            consumedEndSegmentIndex: builder.kinds.count
        ))
    }

    return chunks
}
