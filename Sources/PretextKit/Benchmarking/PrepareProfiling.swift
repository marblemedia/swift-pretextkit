import CoreText
import Foundation

final class InternalPrepareProfiler {
    var analysisNs: UInt64 = 0
    var analysisCacheHits: Int = 0
    var analysisCacheMisses: Int = 0
    var measurerInitNs: UInt64 = 0
    var staticMetricsNs: UInt64 = 0
    var segmentLoopNs: UInt64 = 0
    var chunkBuildNs: UInt64 = 0
    var coreBuildNs: UInt64 = 0
    var cacheHits: Int = 0
    var cacheMisses: Int = 0
    var widthMeasureCalls: Int = 0
    var widthMeasureNs: UInt64 = 0
    var graphemeCacheHits: Int = 0
    var graphemeCacheMisses: Int = 0
    var graphemeBatchCalls: Int = 0
    var graphemeCharactersMeasured: Int = 0
    var cjkSplitSegments: Int = 0
}

@_spi(Benchmarks) public struct PreparePhaseProfile: Codable, Sendable {
    public let totalPrepareMs: Double
    public let analysisMs: Double
    public let analysisCacheHits: Int
    public let analysisCacheMisses: Int
    public let measurerInitMs: Double
    public let staticMetricsMs: Double
    public let segmentLoopMs: Double
    public let chunkBuildMs: Double
    public let coreBuildMs: Double
    public let widthMeasureMs: Double
    public let analysisSegmentCount: Int
    public let preparedSegmentCount: Int
    public let cacheHits: Int
    public let cacheMisses: Int
    public let widthMeasureCalls: Int
    public let graphemeCacheHits: Int
    public let graphemeCacheMisses: Int
    public let graphemeBatchCalls: Int
    public let graphemeCharactersMeasured: Int
    public let cjkSplitSegments: Int
}

@_spi(Benchmarks) public func profilePrepareWithSegments(
    _ text: String,
    font: FontDescriptor,
    options: PrepareOptions = PrepareOptions()
) -> PreparePhaseProfile {
    let profiler = InternalPrepareProfiler()
    let totalStart = DispatchTime.now().uptimeNanoseconds

    let analysis = analyzeText(text, whiteSpace: options.whiteSpace, profiler: profiler)

    let measurerStart = DispatchTime.now().uptimeNanoseconds
    let measurer = SegmentMeasurer(font: font.font, profiler: profiler)
    profiler.measurerInitNs = DispatchTime.now().uptimeNanoseconds - measurerStart

    let result = measureAnalysis(analysis, font: font, measurer: measurer, profiler: profiler)
    let totalNs = DispatchTime.now().uptimeNanoseconds - totalStart

    return PreparePhaseProfile(
        totalPrepareMs: nsToMs(totalNs),
        analysisMs: nsToMs(profiler.analysisNs),
        analysisCacheHits: profiler.analysisCacheHits,
        analysisCacheMisses: profiler.analysisCacheMisses,
        measurerInitMs: nsToMs(profiler.measurerInitNs),
        staticMetricsMs: nsToMs(profiler.staticMetricsNs),
        segmentLoopMs: nsToMs(profiler.segmentLoopNs),
        chunkBuildMs: nsToMs(profiler.chunkBuildNs),
        coreBuildMs: nsToMs(profiler.coreBuildNs),
        widthMeasureMs: nsToMs(profiler.widthMeasureNs),
        analysisSegmentCount: analysis.segmentation.count,
        preparedSegmentCount: result.segments.count,
        cacheHits: profiler.cacheHits,
        cacheMisses: profiler.cacheMisses,
        widthMeasureCalls: profiler.widthMeasureCalls,
        graphemeCacheHits: profiler.graphemeCacheHits,
        graphemeCacheMisses: profiler.graphemeCacheMisses,
        graphemeBatchCalls: profiler.graphemeBatchCalls,
        graphemeCharactersMeasured: profiler.graphemeCharactersMeasured,
        cjkSplitSegments: profiler.cjkSplitSegments
    )
}

private func nsToMs(_ value: UInt64) -> Double {
    (Double(value) / 1_000_000 * 1_000).rounded() / 1_000
}
