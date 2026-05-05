import CoreGraphics
import CoreText
import Foundation
@_spi(Benchmarks) import PretextKit

enum PretextKitBenchmarksTool {
    private static let selectedBenchmarks: [BenchmarkSpec] = [
        BenchmarkSpec(file: "mixed-karla-001.json", fontID: nil),
        BenchmarkSpec(file: "latin-inter-static-001.json", fontID: nil),
    ]
    private static let selectedCorpusBenchmarks: [String] = [
        "chat-throughput-001.json",
    ]

    private static let prepareWarmSamples = 25
    private static let prepareWarmBatch = 40
    private static let prepareColdSamples = 20
    private static let prepareColdBatch = 8
    private static let layoutSamples = 30
    private static let layoutBatch = 400
    private static let profiledWarmSamples = 9
    private static let profiledColdSamples = 7

    static func run() throws {
        let configuration = try BenchmarkConfiguration(arguments: CommandLine.arguments)
        let environment = try BenchmarkEnvironment(fixturesRoot: configuration.fixturesRoot)

        let results = try selectedBenchmarks.map { spec in
            try benchmarkCase(spec: spec, environment: environment)
        }
        let corpusResults = try selectedCorpusBenchmarks.flatMap { file in
            try benchmarkCorpus(file: file, environment: environment)
        }

        let output = BenchmarkFile(
            platform: "ios",
            mode: "release",
            notes: [
                "Release executable benchmark built with swift run -c release.",
                "Benchmarks use prepareWithSegments() and layoutWithLines() for the rich rendering path.",
                "Prepare warm batches \(prepareWarmBatch) calls per sample; prepare cold batches \(prepareColdBatch) calls per sample; layout batches \(layoutBatch) calls per sample.",
                "Pinned-font cases only; asset fonts are loaded from the shared Android fixtures directory."
            ],
            cases: results,
            corpusRuns: corpusResults
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)

        if let outputURL = configuration.outputURL {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL)
            FileHandle.standardOutput.write(Data("wrote \(outputURL.path)\n".utf8))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func benchmarkCase(
        spec: BenchmarkSpec,
        environment: BenchmarkEnvironment
    ) throws -> BenchmarkCaseResult {
        let fixture = try environment.loadCase(file: spec.file)
        let font = try environment.resolveFont(in: fixture, expectedFontID: spec.fontID)
        let fontDescriptor = try environment.loadFontDescriptor(font)
        let options = PrepareOptions(whiteSpace: fixture.layout.whiteSpaceMode)
        let lineHeight = fixture.layout.resolveLineHeight(fontSize: font.size)
        let maxWidth = fixture.layout.maxWidth

        clearCache()
        _ = prepareWithSegments(fixture.text, font: fontDescriptor, options: options)

        let prepareWarmMs = medianMillis(samples: prepareWarmSamples, batchSize: prepareWarmBatch) {
            _ = prepareWithSegments(fixture.text, font: fontDescriptor, options: options)
        }

        let warmProfile = medianProfile(samples: profiledWarmSamples) {
            profilePrepareWithSegments(fixture.text, font: fontDescriptor, options: options)
        }

        let prepareColdMs = medianMillis(samples: prepareColdSamples, batchSize: prepareColdBatch) {
            clearCache()
            _ = prepareWithSegments(fixture.text, font: fontDescriptor, options: options)
        }

        let coldProfile = medianProfile(samples: profiledColdSamples) {
            clearCache()
            return profilePrepareWithSegments(fixture.text, font: fontDescriptor, options: options)
        }

        clearCache()
        let prepared = prepareWithSegments(fixture.text, font: fontDescriptor, options: options)
        _ = layoutWithLines(prepared, maxWidth: maxWidth, lineHeight: lineHeight)

        let layoutMs = medianMillis(samples: layoutSamples, batchSize: layoutBatch) {
            _ = layoutWithLines(prepared, maxWidth: maxWidth, lineHeight: lineHeight)
        }

        return BenchmarkCaseResult(
            caseId: fixture.caseID,
            fontId: font.id ?? "font-1",
            fontLabel: font.label ?? font.family,
            fontFamily: font.family,
            prepareWarmMs: prepareWarmMs,
            prepareColdMs: prepareColdMs,
            layoutWithLinesMs: layoutMs,
            warmProfile: warmProfile,
            coldProfile: coldProfile
        )
    }

    private static func benchmarkCorpus(
        file: String,
        environment: BenchmarkEnvironment
    ) throws -> [BenchmarkCorpusResult] {
        let corpus = try environment.loadCorpus(file: file)
        return try corpus.scenarios.map { scenario in
            let fonts = try scenario.fonts.map { try environment.loadFontDescriptor($0) }

            clearCache()
            _ = prepareCorpus(messages: corpus.messages, fonts: fonts)

            let warmMs = medianMillis(samples: 18, batchSize: 1) {
                _ = prepareCorpus(messages: corpus.messages, fonts: fonts)
            }

            let coldMs = medianMillis(samples: 12, batchSize: 1) {
                clearCache()
                _ = prepareCorpus(messages: corpus.messages, fonts: fonts)
            }

            let messageCount = corpus.messages.count
            return BenchmarkCorpusResult(
                corpusId: corpus.corpusId,
                scenarioId: scenario.id,
                scenarioLabel: scenario.label,
                mode: "release",
                fontCount: fonts.count,
                messageCount: messageCount,
                warmTotalMs: warmMs,
                coldTotalMs: coldMs,
                warmPerMessageMs: roundMillis(warmMs / Double(messageCount)),
                coldPerMessageMs: roundMillis(coldMs / Double(messageCount))
            )
        }
    }
}

do {
    try PretextKitBenchmarksTool.run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

private struct BenchmarkConfiguration {
    let fixturesRoot: URL
    let outputURL: URL?

    init(arguments: [String]) throws {
        var fixturesRoot: URL?
        var outputURL: URL?

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--fixtures-root":
                index += 1
                fixturesRoot = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--output":
                index += 1
                outputURL = URL(fileURLWithPath: arguments[index])
            default:
                throw BenchmarkError("Unknown argument: \(arguments[index])")
            }
            index += 1
        }

        let defaultFixtures = URL(fileURLWithPath: "../android/fixtures", isDirectory: true)
        self.fixturesRoot = fixturesRoot ?? defaultFixtures
        self.outputURL = outputURL
    }
}

private struct BenchmarkEnvironment {
    let fixturesRoot: URL
    let casesRoot: URL
    private let fontRegistry = FontRegistry()

    init(fixturesRoot: URL) throws {
        self.fixturesRoot = fixturesRoot
        self.casesRoot = fixturesRoot.appendingPathComponent("cases", isDirectory: true)
        guard FileManager.default.fileExists(atPath: self.casesRoot.path) else {
            throw BenchmarkError("Fixtures root does not contain cases/: \(fixturesRoot.path)")
        }
    }

    func loadCase(file: String) throws -> FixtureCase {
        let data = try Data(contentsOf: casesRoot.appendingPathComponent(file))
        return try JSONDecoder().decode(FixtureCase.self, from: data)
    }

    func loadCorpus(file: String) throws -> BenchmarkCorpus {
        let url = fixturesRoot.appendingPathComponent("benchmarks", isDirectory: true).appendingPathComponent(file)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BenchmarkCorpus.self, from: data)
    }

    func resolveFont(in fixture: FixtureCase, expectedFontID: String?) throws -> FixtureFont {
        let fonts = fixture.effectiveFonts()
        guard !fonts.isEmpty else {
            throw BenchmarkError("Fixture \(fixture.caseID) has no fonts.")
        }
        if let expectedFontID {
            guard let match = fonts.first(where: { $0.id == expectedFontID }) else {
                throw BenchmarkError("Fixture \(fixture.caseID) is missing font id \(expectedFontID).")
            }
            return match
        }
        return fonts[0]
    }

    func loadFontDescriptor(_ font: FixtureFont) throws -> FontDescriptor {
        guard let assetPath = font.assetPath else {
            throw BenchmarkError("Release benchmark only supports pinned asset fonts for now: \(font.family)")
        }
        let url = fixturesRoot.appendingPathComponent(assetPath)
        let registered = try fontRegistry.registerFont(at: url)
        return FontDescriptor(registered.font(size: font.size))
    }
}

private struct BenchmarkSpec {
    let file: String
    let fontID: String?
}

private struct BenchmarkFile: Encodable {
    let platform: String
    let mode: String
    let notes: [String]
    let cases: [BenchmarkCaseResult]
    let corpusRuns: [BenchmarkCorpusResult]
}

private struct BenchmarkCaseResult: Encodable {
    let caseId: String
    let fontId: String
    let fontLabel: String
    let fontFamily: String
    let prepareWarmMs: Double
    let prepareColdMs: Double
    let layoutWithLinesMs: Double
    let warmProfile: PreparePhaseProfile
    let coldProfile: PreparePhaseProfile
}

private struct BenchmarkCorpusResult: Encodable {
    let corpusId: String
    let scenarioId: String
    let scenarioLabel: String
    let mode: String
    let fontCount: Int
    let messageCount: Int
    let warmTotalMs: Double
    let coldTotalMs: Double
    let warmPerMessageMs: Double
    let coldPerMessageMs: Double
}

private struct FixtureCase: Decodable {
    let caseID: String
    let text: String
    let font: FixtureFont?
    let fonts: [FixtureFont]?
    let layout: FixtureLayout

    enum CodingKeys: String, CodingKey {
        case caseID = "caseId"
        case text
        case font
        case fonts
        case layout
    }

    func effectiveFonts() -> [FixtureFont] {
        if let fonts, !fonts.isEmpty { return fonts }
        if let font { return [font] }
        return []
    }
}

private struct FixtureFont: Decodable {
    let id: String?
    let label: String?
    let family: String
    let assetPath: String?
    let size: Double
    let style: String
    let letterSpacing: Double
}

private struct FixtureLayout: Decodable {
    let maxWidth: CGFloat
    let lineHeight: CGFloat?
    let lineHeightFactor: CGFloat?
    let whiteSpace: String

    enum CodingKeys: String, CodingKey {
        case maxWidth
        case lineHeight
        case lineHeightFactor
        case whiteSpace
    }

    var whiteSpaceMode: WhiteSpaceMode {
        whiteSpace == "pre-wrap" ? .preWrap : .normal
    }

    func resolveLineHeight(fontSize: Double) -> CGFloat {
        lineHeight ?? CGFloat(fontSize) * (lineHeightFactor ?? 1)
    }
}

private struct BenchmarkCorpus: Decodable {
    let corpusId: String
    let messages: [String]
    let scenarios: [BenchmarkCorpusScenario]
}

private struct BenchmarkCorpusScenario: Decodable {
    let id: String
    let label: String
    let fonts: [FixtureFont]
}

private final class FontRegistry {
    private var registered: [URL: RegisteredFont] = [:]

    func registerFont(at url: URL) throws -> RegisteredFont {
        if let cached = registered[url] {
            return cached
        }

        guard
            let provider = CGDataProvider(url: url as CFURL),
            let cgFont = CGFont(provider),
            let postScriptName = cgFont.postScriptName as String?
        else {
            throw BenchmarkError("Unable to load font at \(url.path)")
        }

        let registered = RegisteredFont(postScriptName: postScriptName, cgFont: cgFont)
        self.registered[url] = registered
        return registered
    }
}

private struct RegisteredFont {
    let postScriptName: String
    let cgFont: CGFont

    func font(size: Double) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: postScriptName,
            kCTFontSizeAttribute: size,
        ] as CFDictionary)
        return CTFontCreateWithGraphicsFont(cgFont, size, nil, descriptor)
    }
}

private struct BenchmarkError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private func medianMillis(
    samples: Int,
    batchSize: Int,
    block: () -> Void
) -> Double {
    var values: [Double] = []
    values.reserveCapacity(samples)

    for _ in 0..<samples {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<batchSize {
            block()
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        values.append(Double(elapsed) / 1_000_000 / Double(batchSize))
    }

    values.sort()
    let middle = values.count / 2
    if values.count.isMultiple(of: 2) {
        return roundMillis((values[middle - 1] + values[middle]) / 2)
    }
    return roundMillis(values[middle])
}

private func roundMillis(_ value: Double) -> Double {
    (value * 1_000).rounded() / 1_000
}

private func prepareCorpus(
    messages: [String],
    fonts: [FontDescriptor]
) -> Int {
    var preparedCount = 0
    for (index, message) in messages.enumerated() {
        let font = fonts[index % fonts.count]
        _ = prepareWithSegments(message, font: font)
        preparedCount += 1
    }
    return preparedCount
}

private func medianProfile(
    samples: Int,
    block: () -> PreparePhaseProfile
) -> PreparePhaseProfile {
    var values: [PreparePhaseProfile] = []
    values.reserveCapacity(samples)
    for _ in 0..<samples {
        values.append(block())
    }
    values.sort { $0.totalPrepareMs < $1.totalPrepareMs }
    return values[values.count / 2]
}
