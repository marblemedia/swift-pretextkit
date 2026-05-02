#if canImport(UIKit)
import CoreGraphics
import CoreText
import Foundation
import UIKit
import XCTest
@testable import PretextKit

final class FixtureHarnessTests: XCTestCase {

    func testExportSharedFixtures() throws {
        let environment = try HarnessEnvironment()
        let manifest = try environment.loadManifest()
        let encoder = makeEncoder()

        try FileManager.default.createDirectory(
            at: environment.iosResultsURL,
            withIntermediateDirectories: true
        )

        for entry in manifest {
            let fixtureCase = try environment.loadCase(file: entry.file)
            let result = try exportCase(fixtureCase, environment: environment)
            let data = try encoder.encode(result)
            let outputURL = environment.iosResultsURL.appendingPathComponent("\(fixtureCase.caseId).json")
            try data.write(to: outputURL, options: .atomic)
        }
    }

    private func exportCase(
        _ fixtureCase: HarnessCase,
        environment: HarnessEnvironment
    ) throws -> HarnessResultFile {
        let runs = try fixtureCase.effectiveFonts().enumerated().map { index, font in
            try exportRun(
                fixtureCase: fixtureCase,
                font: font,
                fontIndex: index,
                environment: environment
            )
        }

        let fallbackNames = try environment.sharedFallbackDisplayNames()
        var notes = [
            "Loaded from PretextKit package on iOS simulator.",
            "Timings are warmed averages: prepare x10, layout x100, render x40 after 3 warmups.",
            "Applied explicit fallback stack: \(fallbackNames.joined(separator: ", ")).",
        ]
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.model
        let systemVersion = UIDevice.current.systemVersion
        notes.append("Rendered on \(simulatorName) iOS \(systemVersion).")

        return HarnessResultFile(
            caseId: fixtureCase.caseId,
            platform: "ios",
            engineVersion: "pretext-ios-local",
            notes: notes,
            runs: runs
        )
    }

    private func exportRun(
        fixtureCase: HarnessCase,
        font: HarnessFont,
        fontIndex: Int,
        environment: HarnessEnvironment
    ) throws -> HarnessRunResult {
        let resolvedLineHeight = fixtureCase.layout.resolveLineHeight(fontSize: font.size)
        let loadedFont = try environment.loadFont(font)
        let fontDescriptor = FontDescriptor(loadedFont.font)
        let options = PrepareOptions(whiteSpace: fixtureCase.layout.whiteSpace.toWhiteSpaceMode())

        let prepared = prepareWithSegments(
            fixtureCase.text,
            font: fontDescriptor,
            options: options
        )
        let laidOut = layoutWithLines(
            prepared,
            maxWidth: fixtureCase.layout.maxWidth,
            lineHeight: resolvedLineHeight
        )

        let renderedLines = laidOut.lines.map { line in
            HarnessRenderedLine(
                resultLine: line,
                renderText: materializeMeasuredLineText(
                    segments: prepared.segments,
                    kinds: prepared.core.kinds,
                    line: line
                )
            )
        }

        let rendered = renderSnapshot(
            lines: renderedLines,
            font: loadedFont.font,
            lineHeight: resolvedLineHeight,
            paddingHorizontal: fixtureCase.bubble.paddingHorizontal,
            paddingVertical: fixtureCase.bubble.paddingVertical,
            letterSpacing: font.letterSpacing
        )

        let prepareMs = benchmarkAverageMillis(iterations: 10, warmups: 3) {
            _ = prepareWithSegments(
                fixtureCase.text,
                font: fontDescriptor,
                options: options
            )
        }
        let layoutMs = benchmarkAverageMillis(iterations: 100, warmups: 3) {
            _ = layoutWithLines(
                prepared,
                maxWidth: fixtureCase.layout.maxWidth,
                lineHeight: resolvedLineHeight
            )
        }
        let renderMs = benchmarkAverageMillis(iterations: 40, warmups: 3) {
            _ = renderSnapshot(
                lines: renderedLines,
                font: loadedFont.font,
                lineHeight: resolvedLineHeight,
                paddingHorizontal: fixtureCase.bubble.paddingHorizontal,
                paddingVertical: fixtureCase.bubble.paddingVertical,
                letterSpacing: font.letterSpacing
            )
        }

        let bubble = HarnessBubbleResult(
            contentWidth: rendered.contentWidth,
            outerWidth: rendered.outerWidth,
            outerHeight: rendered.outerHeight
        )

        let lineResults = renderedLines.enumerated().map { index, line in
            HarnessLineResult(
                text: line.renderText,
                width: line.resultLine.width,
                baseline: rendered.baseline(for: index),
                inkBounds: rendered.lineInkBounds[index]
            )
        }

        let fontMetrics = HarnessFontMetrics(
            ascent: Double(CTFontGetAscent(loadedFont.font)),
            descent: Double(CTFontGetDescent(loadedFont.font)),
            leading: Double(CTFontGetLeading(loadedFont.font)),
            capHeight: Double(CTFontGetCapHeight(loadedFont.font)),
            xHeight: Double(CTFontGetXHeight(loadedFont.font))
        )

        let diagnostics = HarnessRunDiagnostics(
            probes: standardProbes().map { probe in
                let width = measureWidth(
                    probe.text,
                    font: loadedFont.font,
                    letterSpacing: font.letterSpacing
                )
                return HarnessProbeResult(
                    id: probe.id,
                    text: probe.text,
                    width: width,
                    hasGlyph: nil
                )
            }
        )

        return HarnessRunResult(
            fontId: font.id ?? "font-\(fontIndex + 1)",
            fontLabel: font.label ?? font.family,
            font: HarnessFontDescriptorResult(
                requestedFamily: font.family,
                requestedAssetPath: font.assetPath,
                requestedSize: font.size,
                requestedWeight: font.weight,
                requestedStyle: font.style,
                requestedLetterSpacing: font.letterSpacing,
                resolvedFontFamily: loadedFont.resolvedFamily
            ),
            timings: HarnessTimingResult(
                prepareMs: prepareMs,
                layoutMs: layoutMs,
                renderMs: renderMs,
                totalMs: prepareMs + layoutMs + renderMs
            ),
            render: HarnessRenderResult(
                contentWidth: rendered.contentWidth,
                outerWidth: rendered.outerWidth,
                outerHeight: rendered.outerHeight,
                lineHeightPx: resolvedLineHeight,
                lineHeightFactor: fixtureCase.layout.lineHeightFactor,
                contentInkBounds: rendered.contentInkBounds,
                outerInkBounds: rendered.outerInkBounds
            ),
            diagnostics: diagnostics,
            result: HarnessBodyResult(
                resolvedFontFamily: loadedFont.resolvedFamily,
                lineCount: laidOut.lineCount,
                height: laidOut.height,
                lines: lineResults,
                bubble: bubble,
                fontMetrics: fontMetrics,
                prepared: prepared.toHarnessPreparedResult()
            )
        )
    }

    private func renderSnapshot(
        lines: [HarnessRenderedLine],
        font: CTFont,
        lineHeight: Double,
        paddingHorizontal: Double,
        paddingVertical: Double,
        letterSpacing: Double
    ) -> RenderSnapshot {
        let contentWidth = lines.map { Double($0.resultLine.width) }.max() ?? 0
        let contentHeight = Double(lines.count) * lineHeight
        let outerWidth = contentWidth + (paddingHorizontal * 2)
        let outerHeight = contentHeight + (paddingVertical * 2)

        let outerScan = makeInkScan(
            width: Int(ceil(outerWidth)),
            height: Int(ceil(outerHeight))
        )
        let contentScan = makeInkScan(
            width: Int(ceil(contentWidth)),
            height: Int(ceil(contentHeight))
        )
        var lineBounds: [HarnessBounds?] = []
        lineBounds.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let baseline = paddingVertical + baselineOffset(font: font) + (Double(index) * lineHeight)
            drawText(
                line.renderText,
                font: font,
                letterSpacing: letterSpacing,
                originX: paddingHorizontal,
                baselineY: baseline,
                into: outerScan.context
            )
            drawText(
                line.renderText,
                font: font,
                letterSpacing: letterSpacing,
                originX: 0,
                baselineY: baseline - paddingVertical,
                into: contentScan.context
            )

            let localBounds = rasterizedBounds(
                text: line.renderText,
                font: font,
                letterSpacing: letterSpacing,
                width: Double(line.resultLine.width),
                lineHeight: lineHeight
            )
            lineBounds.append(localBounds.map(HarnessBounds.init))
        }

        let outerInk = outerScan.bounds().map(HarnessBounds.init)
        let contentInk = contentScan.bounds().map(HarnessBounds.init)

        return RenderSnapshot(
            contentWidth: contentWidth,
            outerWidth: outerWidth,
            outerHeight: outerHeight,
            lineHeight: lineHeight,
            baselineOffset: baselineOffset(font: font),
            contentInkBounds: contentInk,
            outerInkBounds: outerInk,
            lineInkBounds: lineBounds
        )
    }

    private func rasterizedBounds(
        text: String,
        font: CTFont,
        letterSpacing: Double,
        width: Double,
        lineHeight: Double
    ) -> CGRect? {
        let scan = makeInkScan(
            width: Int(ceil(width)) + 8,
            height: Int(ceil(lineHeight)) + 8
        )
        let baseline = baselineOffset(font: font) + 4
        drawText(
            text,
            font: font,
            letterSpacing: letterSpacing,
            originX: 4,
            baselineY: baseline,
            into: scan.context
        )
        return scan.bounds(offsetX: -4, offsetY: -4)
    }

    private func drawText(
        _ text: String,
        font: CTFont,
        letterSpacing: Double,
        originX: Double,
        baselineY: Double,
        into context: CGContext
    ) {
        let line = makeLine(text: text, font: font, letterSpacing: letterSpacing)
        context.textPosition = CGPoint(x: originX, y: baselineY)
        context.setFillColor(UIColor.black.cgColor)
        CTLineDraw(line, context)
    }

    private func makeLine(
        text: String,
        font: CTFont,
        letterSpacing: Double
    ) -> CTLine {
        let attributes = attributedStringAttributes(font: font, letterSpacing: letterSpacing)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }

    private func measureWidth(
        _ text: String,
        font: CTFont,
        letterSpacing: Double
    ) -> Double {
        let line = makeLine(text: text, font: font, letterSpacing: letterSpacing)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func attributedStringAttributes(
        font: CTFont,
        letterSpacing: Double
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            .foregroundColor: UIColor.black,
        ]
        if letterSpacing != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing
        }
        return attributes
    }

    private func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: max(width, 1),
            height: max(height, 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func makeInkScan(width: Int, height: Int) -> InkScan {
        let clampedWidth = max(width, 1)
        let clampedHeight = max(height, 1)
        let context = makeBitmapContext(width: clampedWidth, height: clampedHeight)!
        configureTextContext(context, width: clampedWidth, height: clampedHeight)
        return InkScan(width: clampedWidth, height: clampedHeight, context: context)
    }

    private func configureTextContext(_ context: CGContext, width: Int, height: Int) {
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
    }

    private func baselineOffset(font: CTFont) -> Double {
        Double(CTFontGetAscent(font))
    }

    private func benchmarkAverageMillis(
        iterations: Int,
        warmups: Int,
        block: () -> Void
    ) -> Double {
        for _ in 0..<warmups {
            block()
        }

        var total: CFTimeInterval = 0
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            block()
            total += CFAbsoluteTimeGetCurrent() - start
        }
        return (total * 1000) / Double(iterations)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func standardProbes() -> [(id: String, text: String)] {
        [
            ("latin", "metrics"),
            ("arabic", "مرحبا"),
            ("cjk", "你好"),
            ("emoji", "👩‍💻"),
            ("emoji-family", "👨‍👩‍👧‍👦"),
            ("dash", "—"),
            ("mixed", "👩‍💻 你好 مرحبا"),
            ("mixed-family", "👨‍👩‍👧‍👦 你好 مرحبا"),
        ]
    }

    private func materializeMeasuredLineText(
        segments: [String],
        kinds: [SegmentBreakKind],
        line: LayoutLine
    ) -> String {
        var text = ""
        let startSegment = line.start.segmentIndex
        let endSegment = line.end.segmentIndex

        for index in startSegment..<endSegment {
            let segmentText = segments[index]
            let kind = kinds[index]

            if index == startSegment && line.start.graphemeIndex > 0 {
                let graphemes = Array(segmentText)
                text += graphemes[line.start.graphemeIndex...].map(String.init).joined()
                continue
            }

            if index == endSegment - 1 && line.end.graphemeIndex > 0 {
                let graphemes = Array(segmentText)
                let endIndex = min(line.end.graphemeIndex, graphemes.count)
                text += graphemes[..<endIndex].map(String.init).joined()
                continue
            }

            if kind == .softHyphen && index == endSegment - 1 {
                text += "-"
            } else {
                text += segmentText
            }
        }

        return text
    }
}

private struct HarnessEnvironment {
    let iosRepoRoot: URL
    let androidRepoRoot: URL
    let fixturesURL: URL
    let casesURL: URL
    let manifestURL: URL
    let resultsURL: URL
    let iosResultsURL: URL
    private let fontRegistry = FontRegistry()

    init() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        self.iosRepoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        self.androidRepoRoot = iosRepoRoot.deletingLastPathComponent().appendingPathComponent("android")
        self.fixturesURL = androidRepoRoot.appendingPathComponent("fixtures")
        self.casesURL = fixturesURL.appendingPathComponent("cases")
        self.manifestURL = casesURL.appendingPathComponent("index.json")
        self.resultsURL = fixturesURL.appendingPathComponent("results")
        self.iosResultsURL = resultsURL.appendingPathComponent("ios")
        _ = try sharedFallbackDescriptors()
    }

    func loadManifest() throws -> [HarnessManifestEntry] {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([HarnessManifestEntry].self, from: data)
    }

    func loadCase(file: String) throws -> HarnessCase {
        let data = try Data(contentsOf: casesURL.appendingPathComponent(file))
        return try JSONDecoder().decode(HarnessCase.self, from: data)
    }

    func loadFont(_ font: HarnessFont) throws -> LoadedFont {
        let fallbackDescriptors = try sharedFallbackDescriptors()

        if let assetPath = font.assetPath {
            let url = fixturesURL.appendingPathComponent(assetPath)
            let registered = try fontRegistry.registerFont(at: url)
            let cascade = try registered.fontWithCascade(size: font.size, cascadeDescriptors: fallbackDescriptors)
            return LoadedFont(font: cascade, resolvedFamily: font.family)
        }

        switch font.family {
        case "system", "system-ui", "sans-serif":
            let baseFont = CTFontCreateUIFontForLanguage(.system, font.size, nil) ?? UIFont.systemFont(ofSize: font.size) as CTFont
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(baseFont),
                [kCTFontCascadeListAttribute: fallbackDescriptors] as CFDictionary
            )
            let ctFont = CTFontCreateWithFontDescriptor(descriptor, font.size, nil)
            return LoadedFont(font: ctFont, resolvedFamily: "system-ui")
        case "serif":
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontNameAttribute: "TimesNewRomanPSMT",
                kCTFontSizeAttribute: font.size,
                kCTFontCascadeListAttribute: fallbackDescriptors,
            ] as CFDictionary)
            let ctFont = CTFontCreateWithFontDescriptor(descriptor, font.size, nil)
            return LoadedFont(font: ctFont, resolvedFamily: "serif")
        case "monospace":
            let baseFont = CTFontCreateUIFontForLanguage(.kCTFontUserFixedPitchFontType, font.size, nil) ?? UIFont.monospacedSystemFont(ofSize: font.size, weight: .regular) as CTFont
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(baseFont),
                [kCTFontCascadeListAttribute: fallbackDescriptors] as CFDictionary
            )
            let ctFont = CTFontCreateWithFontDescriptor(descriptor, font.size, nil)
            return LoadedFont(font: ctFont, resolvedFamily: "monospace")
        default:
            let namedFont = UIFont(name: font.family, size: font.size) ?? UIFont.systemFont(ofSize: font.size)
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontNameAttribute: namedFont.fontName,
                kCTFontSizeAttribute: font.size,
                kCTFontCascadeListAttribute: fallbackDescriptors,
            ] as CFDictionary)
            let ctFont = CTFontCreateWithFontDescriptor(descriptor, font.size, nil)
            return LoadedFont(font: ctFont, resolvedFamily: font.family)
        }
    }

    func sharedFallbackDisplayNames() throws -> [String] {
        try sharedFallbackDescriptors().map {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String ?? "unknown"
        }
    }

    private func sharedFallbackDescriptors() throws -> [CTFontDescriptor] {
        var descriptors: [CTFontDescriptor] = [
            try systemFontDescriptor(named: ["AppleColorEmoji", "Apple Color Emoji"]),
        ]
        let assets = [
            "fonts/fallback/NotoSansArabic.ttf",
            "fonts/fallback/NotoSansSC.ttf",
        ]
        descriptors += try assets.map { assetPath in
            let url = fixturesURL.appendingPathComponent(assetPath)
            let registered = try fontRegistry.registerFont(at: url)
            return registered.descriptor
        }
        return descriptors
    }

    private func systemFontDescriptor(named candidates: [String]) throws -> CTFontDescriptor {
        for candidate in candidates {
            if let font = UIFont(name: candidate, size: 16) {
                return CTFontDescriptorCreateWithAttributes([
                    kCTFontNameAttribute: font.fontName,
                ] as CFDictionary)
            }
        }
        throw NSError(domain: "FixtureHarness", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Unable to resolve system fallback font from candidates: \(candidates.joined(separator: ", ")).",
        ])
    }
}

private final class FontRegistry {
    private var registered: [URL: RegisteredFont] = [:]

    func registerFont(at url: URL) throws -> RegisteredFont {
        if let cached = registered[url] {
            return cached
        }

        guard
            let provider = CGDataProvider(url: url as CFURL),
            let cgFont = CGFont(provider)
        else {
            throw NSError(domain: "FixtureHarness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to load font at \(url.path).",
            ])
        }

        guard let postScriptName = cgFont.postScriptName as String? else {
            throw NSError(domain: "FixtureHarness", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Unable to resolve PostScript name for \(url.lastPathComponent).",
            ])
        }

        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: postScriptName,
        ] as CFDictionary)
        let registered = RegisteredFont(postScriptName: postScriptName, cgFont: cgFont, descriptor: descriptor)
        self.registered[url] = registered
        return registered
    }
}

private struct RegisteredFont {
    let postScriptName: String
    let cgFont: CGFont
    let descriptor: CTFontDescriptor

    func fontWithCascade(
        size: Double,
        cascadeDescriptors: [CTFontDescriptor]
    ) throws -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: postScriptName,
            kCTFontSizeAttribute: size,
            kCTFontCascadeListAttribute: cascadeDescriptors,
        ] as CFDictionary)
        return CTFontCreateWithGraphicsFont(cgFont, size, nil, descriptor)
    }
}

private struct LoadedFont {
    let font: CTFont
    let resolvedFamily: String
}

private struct RenderSnapshot {
    let contentWidth: Double
    let outerWidth: Double
    let outerHeight: Double
    let lineHeight: Double
    let baselineOffset: Double
    let contentInkBounds: HarnessBounds?
    let outerInkBounds: HarnessBounds?
    let lineInkBounds: [HarnessBounds?]

    func baseline(for lineIndex: Int) -> Double {
        baselineOffset + (Double(lineIndex) * lineHeight)
    }
}

private struct HarnessRenderedLine {
    let resultLine: LayoutLine
    let renderText: String
}

private struct InkScan {
    let width: Int
    let height: Int
    let context: CGContext

    func bounds(offsetX: Double = 0, offsetY: Double = 0) -> CGRect? {
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * context.bytesPerRow) + (x * 4) + 3
                if bytes[index] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        let top = height - (maxY + 1)
        let bottom = height - minY
        return CGRect(
            x: Double(minX) + offsetX,
            y: Double(top) + offsetY,
            width: Double(maxX - minX + 1),
            height: Double(bottom - top)
        ).standardized
    }
}

private struct HarnessManifestEntry: Decodable {
    let file: String
}

private struct HarnessCase: Decodable {
    let caseId: String
    let tags: [String]
    let text: String
    let font: HarnessFont?
    let fonts: [HarnessFont]?
    let layout: HarnessLayout
    let bubble: HarnessBubble

    func effectiveFonts() -> [HarnessFont] {
        if let fonts, !fonts.isEmpty { return fonts }
        if let font { return [font] }
        return []
    }
}

private struct HarnessFont: Decodable {
    let id: String?
    let label: String?
    let family: String
    let assetPath: String?
    let size: Double
    let weight: Int?
    let style: String
    let letterSpacing: Double

    init(
        id: String? = nil,
        label: String? = nil,
        family: String,
        assetPath: String? = nil,
        size: Double,
        weight: Int? = nil,
        style: String = "normal",
        letterSpacing: Double = 0
    ) {
        self.id = id
        self.label = label
        self.family = family
        self.assetPath = assetPath
        self.size = size
        self.weight = weight
        self.style = style
        self.letterSpacing = letterSpacing
    }
}

private struct HarnessLayout: Decodable {
    let maxWidth: Double
    let lineHeight: Double?
    let lineHeightFactor: Double?
    let whiteSpace: String

    func resolveLineHeight(fontSize: Double) -> Double {
        lineHeight ?? ((lineHeightFactor ?? 1) * fontSize)
    }
}

private struct HarnessBubble: Decodable {
    let paddingHorizontal: Double
    let paddingVertical: Double
    let maxWidthRatio: Double
}

private struct HarnessResultFile: Encodable {
    let caseId: String
    let platform: String
    let engineVersion: String
    let notes: [String]
    let runs: [HarnessRunResult]
}

private struct HarnessRunResult: Encodable {
    let fontId: String
    let fontLabel: String
    let font: HarnessFontDescriptorResult
    let timings: HarnessTimingResult
    let render: HarnessRenderResult
    let diagnostics: HarnessRunDiagnostics
    let result: HarnessBodyResult
}

private struct HarnessFontDescriptorResult: Encodable {
    let requestedFamily: String
    let requestedAssetPath: String?
    let requestedSize: Double
    let requestedWeight: Int?
    let requestedStyle: String
    let requestedLetterSpacing: Double
    let resolvedFontFamily: String
}

private struct HarnessTimingResult: Encodable {
    let prepareMs: Double
    let layoutMs: Double
    let renderMs: Double
    let totalMs: Double
}

private struct HarnessRenderResult: Encodable {
    let contentWidth: Double
    let outerWidth: Double
    let outerHeight: Double
    let lineHeightPx: Double
    let lineHeightFactor: Double?
    let contentInkBounds: HarnessBounds?
    let outerInkBounds: HarnessBounds?
}

private struct HarnessRunDiagnostics: Encodable {
    let probes: [HarnessProbeResult]
}

private struct HarnessProbeResult: Encodable {
    let id: String
    let text: String
    let width: Double
    let hasGlyph: Bool?
}

private struct HarnessBodyResult: Encodable {
    let resolvedFontFamily: String
    let lineCount: Int
    let height: Double
    let lines: [HarnessLineResult]
    let bubble: HarnessBubbleResult
    let fontMetrics: HarnessFontMetrics
    let prepared: HarnessPreparedResult
}

private struct HarnessLineResult: Encodable {
    let text: String
    let width: Double
    let baseline: Double
    let inkBounds: HarnessBounds?
}

private struct HarnessBubbleResult: Encodable {
    let contentWidth: Double
    let outerWidth: Double
    let outerHeight: Double
}

private struct HarnessFontMetrics: Encodable {
    let ascent: Double
    let descent: Double
    let leading: Double
    let capHeight: Double?
    let xHeight: Double?
}

private struct HarnessBounds: Encodable {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.left = Double(rect.minX)
        self.top = Double(rect.minY)
        self.right = Double(rect.maxX)
        self.bottom = Double(rect.maxY)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }
}

private struct HarnessPreparedResult: Encodable {
    let segments: [String]
    let kinds: [String]
    let widths: [Double]
    let lineEndFitAdvances: [Double]
    let lineEndPaintAdvances: [Double]
    let breakableWidths: [[Double]?]
}

private extension String {
    func toWhiteSpaceMode() -> WhiteSpaceMode {
        self == "pre-wrap" ? .preWrap : .normal
    }
}

private extension PreparedTextWithSegments {
    func toHarnessPreparedResult() -> HarnessPreparedResult {
        HarnessPreparedResult(
            segments: segments,
            kinds: core.kinds.map(\.fixtureKindName),
            widths: core.widths.map(Double.init),
            lineEndFitAdvances: core.lineEndFitAdvances.map(Double.init),
            lineEndPaintAdvances: core.lineEndPaintAdvances.map(Double.init),
            breakableWidths: core.breakableWidths.map { widths in
                widths?.map(Double.init)
            }
        )
    }
}

private extension SegmentBreakKind {
    var fixtureKindName: String {
        switch self {
        case .text: return "text"
        case .space: return "space"
        case .preservedSpace: return "preserved-space"
        case .tab: return "tab"
        case .glue: return "glue"
        case .zeroWidthBreak: return "zero-width-break"
        case .softHyphen: return "soft-hyphen"
        case .hardBreak: return "hard-break"
        }
    }
}
#endif
