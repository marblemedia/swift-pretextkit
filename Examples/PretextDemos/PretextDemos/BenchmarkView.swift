import SwiftUI
import UIKit
import CoreText
import QuartzCore
import PretextKit

private struct BenchmarkEnvironment: Codable {
    let platform: String
    let device: String
    let osVersion: String
    let buildMode: String
    let timestamp: String
}

private struct BenchmarkCaseResult: Identifiable, Codable {
    let id = UUID()
    let name: String
    let fontName: String
    let fontSize: Double
    let width: Double
    let lineHeight: Double
    let textLength: Int
    let lineCount: Int
    let prepareColdMs: Double
    let prepareWarmMs: Double
    let layoutMs: Double
    let layoutWithLinesMs: Double

    enum CodingKeys: String, CodingKey {
        case name
        case fontName
        case fontSize
        case width
        case lineHeight
        case textLength
        case lineCount
        case prepareColdMs
        case prepareWarmMs
        case layoutMs
        case layoutWithLinesMs
    }
}

private struct BenchmarkCorpusResult: Identifiable, Codable {
    let id = UUID()
    let name: String
    let strategy: String
    let workerCount: Int
    let messageCount: Int
    let styleCount: Int
    let warmTotalMs: Double
    let coldTotalMs: Double
    let warmPerMessageMs: Double
    let coldPerMessageMs: Double
    let warmSpeedupVsSequential: Double
    let coldSpeedupVsSequential: Double

    enum CodingKeys: String, CodingKey {
        case name
        case strategy
        case workerCount
        case messageCount
        case styleCount
        case warmTotalMs
        case coldTotalMs
        case warmPerMessageMs
        case coldPerMessageMs
        case warmSpeedupVsSequential
        case coldSpeedupVsSequential
    }
}

private struct BenchmarkReport: Codable {
    let environment: BenchmarkEnvironment
    let config: BenchmarkConfig
    let cases: [BenchmarkCaseResult]
    let corpora: [BenchmarkCorpusResult]
}

private struct BenchmarkConfig: Codable {
    let caseWarmSamples: Int
    let caseColdSamples: Int
    let layoutSamples: Int
    let corpusWarmSamples: Int
    let corpusColdSamples: Int
}

private struct BenchmarkSpec: Identifiable {
    let id: String
    let name: String
    let text: String
    let width: CGFloat
    let lineHeight: CGFloat
    let font: UIFont
}

private struct CorpusMessage {
    let text: String
    let font: UIFont
}

struct BenchmarkView: View {
    @State private var report: BenchmarkReport?
    @State private var isRunning = false
    @State private var copiedJSON = false
    @State private var lastRunError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()

                if isRunning {
                    VStack(spacing: 16) {
                        ProgressView("Running benchmarks...")
                        Text("Prepare is measured in both cold and warm modes, plus corpus throughput for single-style and multi-style chat batches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let report {
                    List {
                        environmentSection(report.environment)
                        caseSection(report.cases)
                        corpusSection(report.corpora)
                        notesSection(report.config)
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView(
                        "No Benchmarks Yet",
                        systemImage: "speedometer",
                        description: Text("Run the benchmark sweep to measure prepare and layout performance inside the demo app.")
                    )
                }
            }
            .navigationTitle("Benchmarks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if report != nil {
                        Button(copiedJSON ? "Copied" : "Copy JSON") {
                            copyJSON()
                        }
                    }

                    Button(isRunning ? "Running..." : "Run") {
                        runBenchmarks()
                    }
                    .disabled(isRunning)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Release builds on device are the numbers to trust most. This screen is mainly for relative prepare/layout cost and quick iteration.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let lastRunError {
                Text(lastRunError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func environmentSection(_ environment: BenchmarkEnvironment) -> some View {
        Section("Environment") {
            metricRow("Platform", environment.platform)
            metricRow("Device", environment.device)
            metricRow("OS", environment.osVersion)
            metricRow("Build", environment.buildMode)
            metricRow("Timestamp", environment.timestamp)
        }
    }

    private func caseSection(_ cases: [BenchmarkCaseResult]) -> some View {
        Section("Single Text Cases") {
            ForEach(cases) { result in
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.name)
                        .font(.headline)

                    Text("\(result.fontName) \(formatNumber(result.fontSize))pt • \(result.textLength) chars • \(Int(result.lineCount)) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    metricRow("Cold prepare", formatMs(result.prepareColdMs))
                    metricRow("Warm prepare", formatMs(result.prepareWarmMs))
                    metricRow("Layout", formatMs(result.layoutMs))
                    metricRow("Layout + lines", formatMs(result.layoutWithLinesMs))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func corpusSection(_ corpora: [BenchmarkCorpusResult]) -> some View {
        Section("Corpus Throughput") {
            ForEach(corpora) { result in
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.name)
                        .font(.headline)

                    Text("\(result.strategy) • \(result.workerCount) workers • \(result.messageCount) messages • \(result.styleCount) styles")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    metricRow("Cold total", formatMs(result.coldTotalMs))
                    metricRow("Cold / message", formatMs(result.coldPerMessageMs))
                    metricRow("Cold speedup", formatSpeedup(result.coldSpeedupVsSequential))
                    metricRow("Warm total", formatMs(result.warmTotalMs))
                    metricRow("Warm / message", formatMs(result.warmPerMessageMs))
                    metricRow("Warm speedup", formatSpeedup(result.warmSpeedupVsSequential))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func notesSection(_ config: BenchmarkConfig) -> some View {
        Section("Config") {
            metricRow("Case cold samples", "\(config.caseColdSamples)")
            metricRow("Case warm samples", "\(config.caseWarmSamples)")
            metricRow("Layout samples", "\(config.layoutSamples)")
            metricRow("Corpus cold samples", "\(config.corpusColdSamples)")
            metricRow("Corpus warm samples", "\(config.corpusWarmSamples)")
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private func copyJSON() {
        guard let report else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
            copiedJSON = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copiedJSON = false
            }
        } catch {
            lastRunError = "Could not encode benchmark JSON: \(error.localizedDescription)"
        }
    }

    private func runBenchmarks() {
        isRunning = true
        copiedJSON = false
        lastRunError = nil

        let environment = BenchmarkEnvironment(
            platform: "iOS",
            device: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion,
            buildMode: buildMode,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        Task.detached(priority: .userInitiated) {
            let result = makeReport(environment: environment)
            await MainActor.run {
                self.report = result
                self.isRunning = false
            }
        }
    }
}

#Preview {
    BenchmarkView()
}

private nonisolated func makeReport(environment: BenchmarkEnvironment) -> BenchmarkReport {
    let config = BenchmarkConfig(
        caseWarmSamples: 200,
        caseColdSamples: 24,
        layoutSamples: 1000,
        corpusWarmSamples: 40,
        corpusColdSamples: 12
    )

    let cases = benchmarkCases(config: config)
    let corpora = benchmarkCorpora(config: config)

    return BenchmarkReport(
        environment: environment,
        config: config,
        cases: cases,
        corpora: corpora
    )
}

private var buildMode: String {
    #if DEBUG
    "Debug"
    #else
    "Release"
    #endif
}

private nonisolated func benchmarkCases(config: BenchmarkConfig) -> [BenchmarkCaseResult] {
    caseSpecs.map { spec in
        let descriptor = FontDescriptor(spec.font)

        clearCache()
        let coldPrepare = averageMs(samples: config.caseColdSamples) {
            clearCache()
            _ = prepare(spec.text, font: descriptor)
        }

        _ = prepare(spec.text, font: descriptor)
        let warmPrepare = averageMs(samples: config.caseWarmSamples) {
            _ = prepare(spec.text, font: descriptor)
        }

        let prepared = prepare(spec.text, font: descriptor)
        let layoutMs = averageMs(samples: config.layoutSamples) {
            _ = layout(prepared, maxWidth: spec.width, lineHeight: spec.lineHeight)
        }

        let preparedRich = prepareWithSegments(spec.text, font: descriptor)
        let layoutWithLinesMs = averageMs(samples: max(250, config.layoutSamples / 2)) {
            _ = layoutWithLines(preparedRich, maxWidth: spec.width, lineHeight: spec.lineHeight)
        }
        let lineResult = layoutWithLines(preparedRich, maxWidth: spec.width, lineHeight: spec.lineHeight)

        return BenchmarkCaseResult(
            name: spec.name,
            fontName: spec.font.fontName,
            fontSize: spec.font.pointSize,
            width: spec.width,
            lineHeight: spec.lineHeight,
            textLength: spec.text.count,
            lineCount: lineResult.lineCount,
            prepareColdMs: coldPrepare,
            prepareWarmMs: warmPrepare,
            layoutMs: layoutMs,
            layoutWithLinesMs: layoutWithLinesMs
        )
    }
}

private nonisolated func benchmarkCorpora(config: BenchmarkConfig) -> [BenchmarkCorpusResult] {
    let singleFont = safeFont(name: "Helvetica", size: 16)
    let fonts = [
        safeFont(name: "Helvetica", size: 16),
        safeFont(name: "Georgia", size: 16),
        safeFont(name: "Menlo-Regular", size: 15),
        safeFont(name: "AvenirNext-Regular", size: 16),
    ]
    var results: [BenchmarkCorpusResult] = []

    for corpusSize in corpusSizes {
        let repeatedTexts = makeCorpusTexts(count: corpusSize)
        let uniqueTexts = makeUniqueCorpusTexts(count: corpusSize)

        let workerCounts = [1, 2, 4, 8].filter { $0 <= max(1, min(ProcessInfo.processInfo.activeProcessorCount, corpusSize)) }

        results.append(contentsOf: benchmarkCorpusFamily(
            name: "Single-style corpus",
            messages: repeatedTexts.map { CorpusMessage(text: $0, font: singleFont) },
            workerCounts: workerCounts,
            config: config
        ))
        results.append(contentsOf: benchmarkCorpusFamily(
            name: "Multi-style corpus",
            messages: repeatedTexts.enumerated().map { index, text in
                CorpusMessage(text: text, font: fonts[index % fonts.count])
            },
            workerCounts: workerCounts,
            config: config
        ))
        results.append(contentsOf: benchmarkCorpusFamily(
            name: "Single-style unique corpus",
            messages: uniqueTexts.map { CorpusMessage(text: $0, font: singleFont) },
            workerCounts: workerCounts,
            config: config
        ))
        results.append(contentsOf: benchmarkCorpusFamily(
            name: "Multi-style unique corpus",
            messages: uniqueTexts.enumerated().map { index, text in
                CorpusMessage(text: text, font: fonts[index % fonts.count])
            },
            workerCounts: workerCounts,
            config: config
        ))
    }

    return results
}

private nonisolated func benchmarkCorpusFamily(
    name: String,
    messages: [CorpusMessage],
    workerCounts: [Int],
    config: BenchmarkConfig
) -> [BenchmarkCorpusResult] {
    let sequential = benchmarkCorpus(
        name: name,
        messages: messages,
        workerCount: 1,
        config: config
    )

    return workerCounts.map { workerCount in
        if workerCount == 1 {
            return sequential.withSpeedups(warm: 1, cold: 1)
        }

        let result = benchmarkCorpus(
            name: name,
            messages: messages,
            workerCount: workerCount,
            config: config
        )
        return result.withSpeedups(
            warm: sequential.warmTotalMs / max(result.warmTotalMs, 0.000_001),
            cold: sequential.coldTotalMs / max(result.coldTotalMs, 0.000_001)
        )
    }
}

private nonisolated func benchmarkCorpus(
    name: String,
    messages: [CorpusMessage],
    workerCount: Int,
    config: BenchmarkConfig
) -> BenchmarkCorpusResult {
    let coldTotal = averageMs(samples: config.corpusColdSamples) {
        clearCache()
        prepareCorpus(messages, workerCount: workerCount)
    }

    clearCache()
    prepareCorpus(messages, workerCount: workerCount)

    let warmTotal = averageMs(samples: config.corpusWarmSamples) {
        prepareCorpus(messages, workerCount: workerCount)
    }

    return BenchmarkCorpusResult(
        name: "\(name) (\(messages.count) msgs)",
        strategy: workerCount == 1 ? "Sequential" : "Parallel",
        workerCount: workerCount,
        messageCount: messages.count,
        styleCount: Set(messages.map(\.font.fontName)).count,
        warmTotalMs: warmTotal,
        coldTotalMs: coldTotal,
        warmPerMessageMs: warmTotal / Double(messages.count),
        coldPerMessageMs: coldTotal / Double(messages.count),
        warmSpeedupVsSequential: 1,
        coldSpeedupVsSequential: 1
    )
}

private nonisolated func prepareCorpus(_ messages: [CorpusMessage], workerCount: Int) {
    let actualWorkers = max(1, min(workerCount, messages.count))
    guard actualWorkers > 1 else {
        for message in messages {
            let descriptor = FontDescriptor(message.font)
            _ = prepare(message.text, font: descriptor)
        }
        return
    }

    let chunkSize = Int(ceil(Double(messages.count) / Double(actualWorkers)))
    let chunks: [ArraySlice<CorpusMessage>] = stride(from: 0, to: messages.count, by: chunkSize).map { start in
        let end = min(start + chunkSize, messages.count)
        return messages[start..<end]
    }

    DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
        autoreleasepool {
            for message in chunks[index] {
                let descriptor = FontDescriptor(message.font)
                _ = prepare(message.text, font: descriptor)
            }
        }
    }
}

private nonisolated func averageMs(samples: Int, _ work: () -> Void) -> Double {
    guard samples > 0 else { return 0 }
    var total = 0.0

    for _ in 0..<samples {
        autoreleasepool {
            let start = CACurrentMediaTime()
            work()
            total += CACurrentMediaTime() - start
        }
    }

    return (total / Double(samples)) * 1000
}

private let caseSpecs: [BenchmarkSpec] = [
    BenchmarkSpec(
        id: "english",
        name: "English paragraph",
        text: TestData.englishMedium[0],
        width: 250,
        lineHeight: 20,
        font: safeFont(name: "Helvetica", size: 16)
    ),
    BenchmarkSpec(
        id: "mixed",
        name: "Mixed script",
        text: TestData.mixed[0],
        width: 240,
        lineHeight: 20,
        font: safeFont(name: "Helvetica", size: 16)
    ),
    BenchmarkSpec(
        id: "emoji",
        name: "Emoji and ZWJ",
        text: TestData.emoji[0],
        width: 240,
        lineHeight: 20,
        font: safeFont(name: "Helvetica", size: 16)
    ),
    BenchmarkSpec(
        id: "url",
        name: "URL and punctuation",
        text: TestData.mixed[3],
        width: 240,
        lineHeight: 20,
        font: safeFont(name: "Helvetica", size: 16)
    ),
]

private let corpusSeedTexts: [String] = TestData.fullCorpus + TestData.stressCases
private let corpusSizes = [16, 64, 256]

private nonisolated func makeCorpusTexts(count: Int) -> [String] {
    guard count > 0 else { return [] }
    return (0..<count).map { corpusSeedTexts[$0 % corpusSeedTexts.count] }
}

private nonisolated func makeUniqueCorpusTexts(count: Int) -> [String] {
    guard count > 0 else { return [] }
    return (0..<count).map { index in
        let seed = corpusSeedTexts[index % corpusSeedTexts.count]
        return "\(seed) [msg \(index)]"
    }
}

private nonisolated func safeFont(name: String, size: CGFloat) -> UIFont {
    UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
}

private nonisolated func formatNumber(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private nonisolated func formatMs(_ value: Double) -> String {
    String(format: "%.3f ms", value)
}

private nonisolated func formatSpeedup(_ value: Double) -> String {
    String(format: "%.2fx", value)
}

private extension BenchmarkCorpusResult {
    func withSpeedups(warm: Double, cold: Double) -> BenchmarkCorpusResult {
        BenchmarkCorpusResult(
            name: name,
            strategy: strategy,
            workerCount: workerCount,
            messageCount: messageCount,
            styleCount: styleCount,
            warmTotalMs: warmTotalMs,
            coldTotalMs: coldTotalMs,
            warmPerMessageMs: warmPerMessageMs,
            coldPerMessageMs: coldPerMessageMs,
            warmSpeedupVsSequential: warm,
            coldSpeedupVsSequential: cold
        )
    }
}
