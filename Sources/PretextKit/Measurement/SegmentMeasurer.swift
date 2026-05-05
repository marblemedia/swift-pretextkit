import CoreText
import Foundation

protocol SegmentMeasuring {
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
        let start = DispatchTime.now().uptimeNanoseconds
        let line = makeLine(for: text)
        let width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        profiler?.widthMeasureCalls += 1
        profiler?.widthMeasureNs += elapsed
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

        let start = DispatchTime.now().uptimeNanoseconds
        let result = measureLineAndGraphemeWidths(for: text)

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        profiler?.widthMeasureCalls += 1
        profiler?.widthMeasureNs += elapsed
        return result.graphemeWidths
    }

    func measureSegmentAndGraphemeWidths(_ text: String) -> (width: Float, graphemeWidths: ContiguousArray<Float>) {
        let count = text.count
        profiler?.graphemeBatchCalls += 1
        profiler?.graphemeCharactersMeasured += count

        let start = DispatchTime.now().uptimeNanoseconds
        let result = measureLineAndGraphemeWidths(for: text)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        profiler?.widthMeasureCalls += 1
        profiler?.widthMeasureNs += elapsed
        return result
    }

    private func makeLine(for text: String) -> CTLine {
        let cfStr = text as CFString
        let len = CFStringGetLength(cfStr)
        let currentLen = CFAttributedStringGetLength(mutableAttrString)
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
        let boundaries = graphemeUTF16Boundaries(for: text)
        var widths = ContiguousArray<Float>()
        widths.reserveCapacity(text.count)
        for index in 0..<text.count {
            let startOffset = CTLineGetOffsetForStringIndex(line, boundaries[index], nil)
            let endOffset = CTLineGetOffsetForStringIndex(line, boundaries[index + 1], nil)
            widths.append(Float(endOffset - startOffset))
        }
        let width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        return (width, widths)
    }
}
