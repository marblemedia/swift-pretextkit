import CoreText
import Foundation

public protocol SegmentMeasuring {
    func measureWidth(_ text: String) -> Float
    func measureHyphenWidth() -> Float
    func measureSpaceWidth() -> Float
    func measureGraphemeWidths(_ text: String) -> ContiguousArray<Float>
    func measureSegmentAndGraphemeWidths(_ text: String) -> (width: Float, graphemeWidths: ContiguousArray<Float>)
}

/// Measures text segment widths using CoreText's CTLine.
///
/// Reuses a mutable attributed string to reduce allocation overhead
/// during the measurement phase. Each measurer is bound to a single font.
///
/// Thread safety: Each measurer instance should be used from a single thread.
/// The shared `SegmentMetricsCache` handles cross-thread coordination.
final class SegmentMeasurer: SegmentMeasuring {
    private let font: CTFont
    private let mutableAttrString: CFMutableAttributedString
    private let profiler: InternalPrepareProfiler?

    init(font: CTFont, profiler: InternalPrepareProfiler? = nil) {
        self.font = font
        self.profiler = profiler
        self.mutableAttrString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)
        CFAttributedStringReplaceString(mutableAttrString, CFRangeMake(0, 0), " " as CFString)
        CFAttributedStringSetAttribute(mutableAttrString, CFRangeMake(0, 1), kCTFontAttributeName, font)
    }

    /// Measures the width of a text segment using CTLine.
    func measureWidth(_ text: String) -> Float {
        guard let profiler else {
            let line = makeLine(for: text)
            return Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let line = makeLine(for: text)
        let boundsStart = DispatchTime.now().uptimeNanoseconds
        let width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        profiler.typographicBoundsNs += DispatchTime.now().uptimeNanoseconds - boundsStart
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        profiler.widthMeasureCalls += 1
        profiler.widthMeasureNs += elapsed
        return width
    }

    /// Measures the width of a visible hyphen character in this font.
    func measureHyphenWidth() -> Float {
        measureWidth("-")
    }

    /// Measures the width of a space character in this font.
    func measureSpaceWidth() -> Float {
        measureWidth(" ")
    }

    /// Measures per-grapheme widths for a segment (for overflow-wrap breaking).
    ///
    /// Pre-allocates the result array to avoid incremental growth.
    func measureGraphemeWidths(_ text: String) -> ContiguousArray<Float> {
        let count = text.count
        profiler?.graphemeBatchCalls += 1
        profiler?.graphemeCharactersMeasured += count

        guard let profiler else {
            return measureLineAndGraphemeWidths(for: text).graphemeWidths
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let result = measureLineAndGraphemeWidths(for: text)

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        profiler.widthMeasureCalls += 1
        profiler.widthMeasureNs += elapsed
        return result.graphemeWidths
    }

    func measureSegmentAndGraphemeWidths(_ text: String) -> (width: Float, graphemeWidths: ContiguousArray<Float>) {
        let count = text.count
        profiler?.graphemeBatchCalls += 1
        profiler?.graphemeCharactersMeasured += count

        guard let profiler else {
            return measureLineAndGraphemeWidths(for: text)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let result = measureLineAndGraphemeWidths(for: text)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        profiler.widthMeasureCalls += 1
        profiler.widthMeasureNs += elapsed
        return result
    }

    private func makeLine(for text: String) -> CTLine {
        let cfStr = text as CFString
        let len = CFStringGetLength(cfStr)
        let currentLen = CFAttributedStringGetLength(mutableAttrString)
        if let profiler {
            let updateStart = DispatchTime.now().uptimeNanoseconds
            CFAttributedStringReplaceString(mutableAttrString, CFRangeMake(0, currentLen), cfStr)
            CFAttributedStringSetAttribute(mutableAttrString, CFRangeMake(0, len), kCTFontAttributeName, font)
            profiler.attributedStringUpdateNs += DispatchTime.now().uptimeNanoseconds - updateStart

            let lineStart = DispatchTime.now().uptimeNanoseconds
            let line = CTLineCreateWithAttributedString(mutableAttrString)
            profiler.lineCreateNs += DispatchTime.now().uptimeNanoseconds - lineStart
            return line
        }

        CFAttributedStringReplaceString(mutableAttrString, CFRangeMake(0, currentLen), cfStr)
        CFAttributedStringSetAttribute(mutableAttrString, CFRangeMake(0, len), kCTFontAttributeName, font)
        return CTLineCreateWithAttributedString(mutableAttrString)
    }

    private func graphemeUTF16Boundaries(for text: String) -> [Int] {
        var boundaries: [Int] = [0]
        boundaries.reserveCapacity(text.count + 1)

        var index = text.startIndex
        while index < text.endIndex {
            index = text.index(after: index)
            boundaries.append(text.utf16.distance(from: text.startIndex, to: index))
        }

        return boundaries
    }

    private func measureLineAndGraphemeWidths(for text: String) -> (width: Float, graphemeWidths: ContiguousArray<Float>) {
        let line = makeLine(for: text)
        let boundaryStart = profiler.map { _ in DispatchTime.now().uptimeNanoseconds }
        let boundaries = graphemeUTF16Boundaries(for: text)
        if let profiler, let boundaryStart {
            profiler.graphemeBoundaryNs += DispatchTime.now().uptimeNanoseconds - boundaryStart
        }

        var widths = ContiguousArray<Float>()
        widths.reserveCapacity(text.count)
        let offsetStart = profiler.map { _ in DispatchTime.now().uptimeNanoseconds }
        var previousOffset = CTLineGetOffsetForStringIndex(line, boundaries[0], nil)
        for boundary in boundaries.dropFirst() {
            let nextOffset = CTLineGetOffsetForStringIndex(line, boundary, nil)
            widths.append(Float(nextOffset - previousOffset))
            previousOffset = nextOffset
        }
        if let profiler, let offsetStart {
            profiler.offsetMeasureNs += DispatchTime.now().uptimeNanoseconds - offsetStart
        }

        let boundsStart = profiler.map { _ in DispatchTime.now().uptimeNanoseconds }
        let width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        if let profiler, let boundsStart {
            profiler.typographicBoundsNs += DispatchTime.now().uptimeNanoseconds - boundsStart
        }
        return (width, widths)
    }
}
