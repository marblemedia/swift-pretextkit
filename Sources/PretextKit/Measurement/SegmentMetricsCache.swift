import Foundation
import os

/// Per-segment measurement results.
struct SegmentMetrics: Sendable {
    /// The measured width of the segment text.
    let width: Float
    /// Whether the segment contains CJK characters.
    let containsCJK: Bool
}

/// Thread-safe cache for segment metrics, keyed by font and segment text.
///
/// Structure: `[fontCacheKey: [segmentText: SegmentMetrics]]`
///
/// The cache persists across `prepare()` calls for the same font,
/// avoiding redundant CTLine measurements for repeated segments.
final class SegmentMetricsCache: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String: [String: SegmentMetrics]]())
    private let graphemeLock = OSAllocatedUnfairLock(initialState: [String: [String: ContiguousArray<Float>]]())

    /// Look up cached metrics for a segment in the given font.
    func metrics(for segment: String, font: FontDescriptor) -> SegmentMetrics? {
        lock.withLock { state in
            state[font.cacheKey]?[segment]
        }
    }

    /// Store metrics for a segment in the given font.
    func store(_ metrics: SegmentMetrics, for segment: String, font: FontDescriptor) {
        lock.withLock { state in
            state[font.cacheKey, default: [:]][segment] = metrics
        }
    }

    /// Clear all cached metrics.
    func clear() {
        lock.withLock { state in
            state.removeAll()
        }
        graphemeLock.withLock { state in
            state.removeAll()
        }
    }

    /// Get cached metrics or measure and cache.
    func getOrMeasure(
        _ segment: String,
        font: FontDescriptor,
        measurer: any SegmentMeasuring,
        profiler: InternalPrepareProfiler? = nil
    ) -> SegmentMetrics {
        if let cached = metrics(for: segment, font: font) {
            profiler?.cacheHits += 1
            return cached
        }
        profiler?.cacheMisses += 1
        let measured = SegmentMetrics(
            width: measurer.measureWidth(segment),
            containsCJK: isCJK(segment)
        )
        store(measured, for: segment, font: font)
        return measured
    }

    func graphemeWidths(for segment: String, font: FontDescriptor) -> ContiguousArray<Float>? {
        graphemeLock.withLock { state in
            state[font.cacheKey]?[segment]
        }
    }

    func storeGraphemeWidths(_ widths: ContiguousArray<Float>, for segment: String, font: FontDescriptor) {
        graphemeLock.withLock { state in
            state[font.cacheKey, default: [:]][segment] = widths
        }
    }

    func getOrMeasureGraphemeWidths(
        _ segment: String,
        font: FontDescriptor,
        measurer: any SegmentMeasuring,
        profiler: InternalPrepareProfiler? = nil
    ) -> ContiguousArray<Float>? {
        guard segment.count > 1 else { return nil }
        if let cached = graphemeWidths(for: segment, font: font) {
            profiler?.graphemeCacheHits += 1
            return cached
        }
        profiler?.graphemeCacheMisses += 1
        let measured = measurer.measureGraphemeWidths(segment)
        storeGraphemeWidths(measured, for: segment, font: font)
        return measured
    }
}

/// Singleton shared across all prepare() calls.
let sharedMetricsCache = SegmentMetricsCache()
