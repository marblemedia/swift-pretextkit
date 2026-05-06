#if canImport(UIKit)
import CoreGraphics
import CoreText
import Foundation
import UIKit
import XCTest
@testable import PretextKit

private let inkAlphaThreshold: UInt8 = 32
private let sharedEmojiWidthPerPoint: Double = 22.459 / 18.0
private let sharedEmojiReferenceProbe = "👩‍💻"
private let snapshotScale: CGFloat = 2

final class FixtureHarnessTests: XCTestCase {

    func testExportSharedFixtures() throws {
        let environment = try HarnessEnvironment()
        let manifest = try environment.loadManifest()
        let encoder = makeEncoder()

        try FileManager.default.createDirectory(
            at: environment.iosResultsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: environment.iosSnapshotsURL,
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
            "AppleColorEmoji rendering uses Noto-aligned advance normalization for layout measurements.",
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
        let options = PrepareOptions(whiteSpace: fixtureCase.layout.whiteSpace.toWhiteSpaceMode())
        let prepared = prepareWithHarnessFonts(
            fixtureCase.text,
            font: loadedFont,
            options: options
        )
        let resolvedLayout = resolveLayoutForCase(
            prepared: prepared,
            layoutConfig: fixtureCase.layout,
            lineHeight: resolvedLineHeight
        )
        let laidOut = resolvedLayout.lines

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
        let lineTexts = renderedLines.map(\.renderText)
        let lineBreaksUtf16 = lineBreaksUtf16FromMaterializedLines(lineTexts)
        let restoredLineTexts = try? materializePersistedUtf16Lines(
            text: fixtureCase.text,
            lineBreaksUtf16: lineBreaksUtf16
        )
        let lineBreakRoundTripMatches = restoredLineTexts.map { $0 == lineTexts } ?? false

        let rendered = renderSnapshot(
            lines: renderedLines,
            fonts: loadedFont,
            lineHeight: resolvedLineHeight,
            paddingHorizontal: fixtureCase.bubble.paddingHorizontal,
            paddingVertical: fixtureCase.bubble.paddingVertical,
            letterSpacing: font.letterSpacing
        )
        let fontId = font.id ?? "font-\(fontIndex + 1)"
        let snapshotFilename = "\(fixtureCase.caseId)--\(fontId).png"
        let snapshotURL = environment.iosSnapshotsURL.appendingPathComponent(snapshotFilename)
        if let pngData = rendered.pngData {
            try pngData.write(to: snapshotURL, options: .atomic)
        }

        let prepareMs = benchmarkAverageMillis(iterations: 10, warmups: 3) {
            _ = prepareWithHarnessFonts(
                fixtureCase.text,
                font: loadedFont,
                options: options
            )
        }
        let layoutMs = benchmarkAverageMillis(iterations: 100, warmups: 3) {
            _ = resolveLayoutForCase(
                prepared: prepared,
                layoutConfig: fixtureCase.layout,
                lineHeight: resolvedLineHeight
            )
        }
        let fastPathMs = benchmarkAverageMillis(iterations: 1_000, warmups: 10) {
            _ = try? materializePersistedUtf16Lines(
                text: fixtureCase.text,
                lineBreaksUtf16: lineBreaksUtf16
            )
        }
        let renderMs = benchmarkAverageMillis(iterations: 40, warmups: 3) {
            _ = renderSnapshot(
                lines: renderedLines,
                fonts: loadedFont,
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
            ascent: Double(CTFontGetAscent(loadedFont.primaryFont)),
            descent: Double(CTFontGetDescent(loadedFont.primaryFont)),
            leading: Double(CTFontGetLeading(loadedFont.primaryFont)),
            capHeight: Double(CTFontGetCapHeight(loadedFont.primaryFont)),
            xHeight: Double(CTFontGetXHeight(loadedFont.primaryFont))
        )

        let diagnostics = HarnessRunDiagnostics(
            probes: standardProbes().map { probe in
                let width = measureWidth(
                    probe.text,
                    fonts: loadedFont,
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
            fontId: fontId,
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
                fastPathMs: fastPathMs,
                renderMs: renderMs,
                totalMs: prepareMs + layoutMs + fastPathMs + renderMs
            ),
            render: HarnessRenderResult(
                contentWidth: rendered.contentWidth,
                outerWidth: rendered.outerWidth,
                outerHeight: rendered.outerHeight,
                lineHeightPx: resolvedLineHeight,
                lineHeightFactor: fixtureCase.layout.lineHeightFactor,
                layoutWidthPx: resolvedLayout.width,
                fit: resolvedLayout.fit,
                snapshotPath: "snapshots/ios/\(snapshotFilename)",
                contentInkBounds: rendered.contentInkBounds,
                outerInkBounds: rendered.outerInkBounds,
                contentMetricBounds: rendered.contentMetricBounds,
                outerMetricBounds: rendered.outerMetricBounds
            ),
            diagnostics: diagnostics,
            result: HarnessBodyResult(
                resolvedFontFamily: loadedFont.resolvedFamily,
                lineCount: laidOut.lineCount,
                lineBreaksUtf16: lineBreaksUtf16,
                lineBreakRoundTripMatches: lineBreakRoundTripMatches,
                height: laidOut.height,
                lines: lineResults,
                bubble: bubble,
                fontMetrics: fontMetrics,
                prepared: prepared.toHarnessPreparedResult()
            )
        )
    }

    private func resolveLayoutForCase(
        prepared: PreparedTextWithSegments,
        layoutConfig: HarnessLayout,
        lineHeight: Double
    ) -> ResolvedHarnessLayout {
        guard let fit = layoutConfig.fit else {
            return ResolvedHarnessLayout(
                width: layoutConfig.maxWidth,
                lines: layoutWithLines(
                    prepared,
                    maxWidth: layoutConfig.maxWidth,
                    lineHeight: lineHeight
                ),
                fit: HarnessFitResult(
                    mode: "fixed-width",
                    requestedMaxWidth: layoutConfig.maxWidth,
                    minWidth: layoutConfig.maxWidth,
                    resolvedWidth: layoutConfig.maxWidth,
                    targetLineCount: nil,
                    targetHeight: nil,
                    didSatisfyTarget: true
                )
            )
        }

        let minWidth = min(layoutConfig.maxWidth, max(fit.minWidth ?? 1, 0.25))
        let mode = fit.targetLineCount != nil ? "target-line-count" : "target-height"
        let targetLineCount = fit.targetLineCount
        let targetHeight = fit.targetHeight
        func satisfies(_ result: LayoutResult) -> Bool {
            if let targetLineCount {
                return result.lineCount <= targetLineCount
            }
            if let targetHeight {
                return result.height <= targetHeight + 0.001
            }
            return true
        }

        let maxLayout = PretextKit.layout(prepared, maxWidth: layoutConfig.maxWidth, lineHeight: lineHeight)
        let didSatisfyTarget = satisfies(maxLayout)
        let resolvedWidth = didSatisfyTarget
            ? findMinimumSatisfyingWidth(
                minWidth: minWidth,
                maxWidth: layoutConfig.maxWidth,
                satisfies: { width in
                    satisfies(PretextKit.layout(prepared, maxWidth: width, lineHeight: lineHeight))
                }
            )
            : layoutConfig.maxWidth

        return ResolvedHarnessLayout(
            width: resolvedWidth,
            lines: layoutWithLines(
                prepared,
                maxWidth: resolvedWidth,
                lineHeight: lineHeight
            ),
            fit: HarnessFitResult(
                mode: mode,
                requestedMaxWidth: layoutConfig.maxWidth,
                minWidth: minWidth,
                resolvedWidth: resolvedWidth,
                targetLineCount: targetLineCount,
                targetHeight: targetHeight,
                didSatisfyTarget: didSatisfyTarget
            )
        )
    }

    private func findMinimumSatisfyingWidth(
        minWidth: Double,
        maxWidth: Double,
        satisfies: (Double) -> Bool
    ) -> Double {
        if maxWidth <= minWidth {
            return maxWidth
        }

        let resolution = 0.25
        var low = minWidth
        var high = maxWidth

        for _ in 0..<24 {
            if high - low <= resolution { break }
            let mid = (low + high) / 2
            if satisfies(mid) {
                high = mid
            } else {
                low = mid
            }
        }

        var resolved = high
        var candidate = high - resolution
        while candidate >= minWidth {
            if !satisfies(candidate) { break }
            resolved = candidate
            candidate -= resolution
        }
        return resolved
    }

    private func renderSnapshot(
        lines: [HarnessRenderedLine],
        fonts: LoadedFont,
        lineHeight: Double,
        paddingHorizontal: Double,
        paddingVertical: Double,
        letterSpacing: Double
    ) -> RenderSnapshot {
        let contentWidth = lines.map { Double($0.resultLine.width) }.max() ?? 0
        let contentHeight = Double(lines.count) * lineHeight
        let outerWidth = contentWidth + (paddingHorizontal * 2)
        let outerHeight = contentHeight + (paddingVertical * 2)
        let contentMetricBounds = metricEnvelopeBounds(
            lines: lines,
            fonts: fonts,
            lineHeight: lineHeight,
            baselineOffset: metricBaselineOffset(fonts: fonts),
            offsetX: 0,
            offsetY: 0
        )
        let outerMetricBounds = contentMetricBounds?.offsetBy(dx: paddingHorizontal, dy: paddingVertical)

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
        let renderBaselineOffset = metricBaselineOffset(fonts: fonts)

        for (index, line) in lines.enumerated() {
            let baseline = paddingVertical + renderBaselineOffset + (Double(index) * lineHeight)
            drawText(
                line.renderText,
                fonts: fonts,
                letterSpacing: letterSpacing,
                originX: paddingHorizontal,
                baselineY: baseline,
                into: outerScan.context
            )
            drawText(
                line.renderText,
                fonts: fonts,
                letterSpacing: letterSpacing,
                originX: 0,
                baselineY: baseline - paddingVertical,
                into: contentScan.context
            )

            let localBounds = rasterizedBounds(
                text: line.renderText,
                fonts: fonts,
                letterSpacing: letterSpacing,
                width: Double(line.resultLine.width),
                lineHeight: lineHeight,
                baselineOffset: renderBaselineOffset
            )
            lineBounds.append(localBounds.map(HarnessBounds.init))
        }

        let outerInk = outerScan.bounds().map(HarnessBounds.init)
        let contentInk = contentScan.bounds().map(HarnessBounds.init)
        let pngData = displaySnapshotPngData(
            lines: lines,
            fonts: fonts,
            lineHeight: lineHeight,
            outerWidth: outerWidth,
            outerHeight: outerHeight,
            paddingHorizontal: paddingHorizontal,
            paddingVertical: paddingVertical,
            letterSpacing: letterSpacing,
            baselineOffset: renderBaselineOffset
        )

        return RenderSnapshot(
            contentWidth: contentWidth,
            outerWidth: outerWidth,
            outerHeight: outerHeight,
            lineHeight: lineHeight,
            baselineOffset: renderBaselineOffset,
            pngData: pngData,
            contentInkBounds: contentInk,
            outerInkBounds: outerInk,
            contentMetricBounds: contentMetricBounds.map(HarnessBounds.init),
            outerMetricBounds: outerMetricBounds.map(HarnessBounds.init),
            lineInkBounds: lineBounds
        )
    }

    private func metricEnvelopeBounds(
        lines: [HarnessRenderedLine],
        fonts: LoadedFont,
        lineHeight: Double,
        baselineOffset: Double,
        offsetX: Double,
        offsetY: Double
    ) -> CGRect? {
        var union: CGRect?

        for (index, line) in lines.enumerated() {
            let baseline = baselineOffset + (Double(index) * lineHeight)
            guard let lineBounds = metricBoundsForLine(
                text: line.renderText,
                fonts: fonts,
                width: Double(line.resultLine.width),
                baseline: baseline
            ) else {
                continue
            }

            let shifted = lineBounds.offsetBy(dx: offsetX, dy: offsetY)
            union = union?.union(shifted) ?? shifted
        }

        return union?.standardized
    }

    private func metricBoundsForLine(
        text: String,
        fonts: LoadedFont,
        width: Double,
        baseline: Double
    ) -> CGRect? {
        guard !text.isEmpty else { return nil }

        var maxAscent: Double = 0
        var maxDescent: Double = 0
        var emojiAscent: Double = 0
        var emojiDescent: Double = 0
        for span in splitByScript(text, primaryFont: fonts.primaryFont) {
            let metricsScript = span.script == .generic ? nil : span.script
            let metrics = span.script == .generic ? fonts.primaryVerticalMetrics : fonts.verticalMetrics(for: span.script)
            let ascent = metrics?.ascent ?? Double(CTFontGetAscent(fonts.font(for: metricsScript)))
            let descent = metrics?.descent ?? Double(CTFontGetDescent(fonts.font(for: metricsScript)))
            if span.script == .emoji {
                emojiAscent = max(emojiAscent, ascent)
                emojiDescent = max(emojiDescent, descent)
            } else {
                maxAscent = max(maxAscent, ascent)
                maxDescent = max(maxDescent, descent)
            }
        }

        if maxAscent == 0 && maxDescent == 0 {
            maxAscent = emojiAscent
            maxDescent = emojiDescent
        }

        guard maxAscent > 0 || maxDescent > 0 else { return nil }
        let top = floor(baseline - maxAscent)
        let bottom = ceil(baseline + maxDescent)
        return CGRect(
            x: 0,
            y: top,
            width: ceil(width),
            height: max(0, bottom - top)
        )
    }

    private func rasterizedBounds(
        text: String,
        fonts: LoadedFont,
        letterSpacing: Double,
        width: Double,
        lineHeight: Double,
        baselineOffset: Double
    ) -> CGRect? {
        let scan = makeInkScan(
            width: Int(ceil(width)) + 8,
            height: Int(ceil(lineHeight)) + 8
        )
        let baseline = baselineOffset + 4
        drawText(
            text,
            fonts: fonts,
            letterSpacing: letterSpacing,
            originX: 4,
            baselineY: baseline,
            into: scan.context
        )
        return scan.bounds(offsetX: -4, offsetY: -4)
    }

    private func drawText(
        _ text: String,
        fonts: LoadedFont,
        letterSpacing: Double,
        originX: Double,
        baselineY: Double,
        into context: CGContext
    ) {
        let line = makeLine(text: text, fonts: fonts, letterSpacing: letterSpacing)
        context.textPosition = CGPoint(x: originX, y: baselineY)
        context.setFillColor(UIColor.black.cgColor)
        CTLineDraw(line, context)
    }

    private func makeLine(
        text: String,
        fonts: LoadedFont,
        letterSpacing: Double
    ) -> CTLine {
        CTLineCreateWithAttributedString(
            attributedString(
                for: text,
                fonts: fonts,
                letterSpacing: letterSpacing
            )
        )
    }

    private func displaySnapshotPngData(
        lines: [HarnessRenderedLine],
        fonts: LoadedFont,
        lineHeight: Double,
        outerWidth: Double,
        outerHeight: Double,
        paddingHorizontal: Double,
        paddingVertical: Double,
        letterSpacing: Double,
        baselineOffset: Double
    ) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = snapshotScale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: outerWidth, height: outerHeight),
            format: format
        )

        return renderer.pngData { rendererContext in
            let context = rendererContext.cgContext
            configureTextContext(
                context,
                width: Int(ceil(outerWidth)),
                height: Int(ceil(outerHeight))
            )

            for (index, line) in lines.enumerated() {
                let baseline =
                    outerHeight
                    - paddingVertical
                    - baselineOffset
                    - (Double(index) * lineHeight)
                drawText(
                    line.renderText,
                    fonts: fonts,
                    letterSpacing: letterSpacing,
                    originX: paddingHorizontal,
                    baselineY: baseline,
                    into: context
                )
            }
        }
    }

    private func measureWidth(
        _ text: String,
        fonts: LoadedFont,
        letterSpacing: Double
    ) -> Double {
        let line = makeLine(text: text, fonts: fonts, letterSpacing: letterSpacing)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func attributedString(
        for text: String,
        fonts: LoadedFont,
        letterSpacing: Double
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for span in splitByScript(text, primaryFont: fonts.primaryFont) {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): fonts.font(for: span.script),
                .foregroundColor: UIColor.black,
            ]
            if letterSpacing != 0 {
                attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing
            }
            attributed.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return attributed
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

    private func metricBaselineOffset(fonts: LoadedFont) -> Double {
        if let metrics = fonts.primaryVerticalMetrics {
            return metrics.ascent
        }
        return baselineOffset(font: fonts.primaryFont)
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
            ("latin-spaces", "font fixtures help"),
            ("latin-line", "Shared font fixtures help"),
            ("arabic", "مرحبا"),
            ("cjk", "你好"),
            ("emoji", "👩‍💻"),
            ("emoji-family", "👨‍👩‍👧‍👦"),
            ("dash", "—"),
            ("mixed", "👩‍💻 你好 مرحبا"),
            ("mixed-family", "👨‍👩‍👧‍👦 你好 مرحبا"),
        ]
    }

    private func prepareWithHarnessFonts(
        _ text: String,
        font: LoadedFont,
        options: PrepareOptions
    ) -> PreparedTextWithSegments {
        let analysis = analyzeText(text, whiteSpace: options.whiteSpace)
        let measurer = FallbackAwareSegmentMeasurer(fonts: font)
        let result = measureAnalysis(analysis, font: font.fontDescriptor, measurer: measurer)
        return PreparedTextWithSegments(core: result.core, segments: result.segments)
    }

    private func materializeMeasuredLineText(
        segments: [String],
        kinds: [SegmentBreakKind],
        line: LayoutLine
    ) -> String {
        var text = ""
        let startSegment = line.start.segmentIndex
        let endSegment = line.end.segmentIndex

        if startSegment == endSegment, line.end.graphemeIndex > 0 {
            guard segments.indices.contains(startSegment) else { return "" }
            let graphemes = Array(segments[startSegment])
            let startIndex = min(line.start.graphemeIndex, graphemes.count)
            let endIndex = min(line.end.graphemeIndex, graphemes.count)
            guard startIndex < endIndex else { return "" }
            return graphemes[startIndex..<endIndex].map(String.init).joined()
        }

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

        if line.end.graphemeIndex > 0, segments.indices.contains(endSegment) {
            let graphemes = Array(segments[endSegment])
            let endIndex = min(line.end.graphemeIndex, graphemes.count)
            if endIndex > 0 {
                text += graphemes[..<endIndex].map(String.init).joined()
            }
        }

        return text
    }
}

private struct HarnessEnvironment {
    let iosRepoRoot: URL
    let fixturesURL: URL
    let casesURL: URL
    let manifestURL: URL
    let resultsURL: URL
    let iosResultsURL: URL
    let snapshotsURL: URL
    let iosSnapshotsURL: URL
    private let fontRegistry = FontRegistry()
    private let fontMetricsManifest: [String: FontMetricsManifestEntry]

    init() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        self.iosRepoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        self.fixturesURL = try HarnessEnvironment.resolveFixturesURL(iosRepoRoot: iosRepoRoot)
        self.casesURL = fixturesURL.appendingPathComponent("cases")
        self.manifestURL = casesURL.appendingPathComponent("index.json")
        self.resultsURL = fixturesURL.appendingPathComponent("results")
        self.iosResultsURL = resultsURL.appendingPathComponent("ios")
        self.snapshotsURL = resultsURL.appendingPathComponent("snapshots")
        self.iosSnapshotsURL = snapshotsURL.appendingPathComponent("ios")
        self.fontMetricsManifest = try HarnessEnvironment.loadFontMetricsManifest(from: fixturesURL)
        _ = try sharedFallbackDisplayNames()
    }

    private static func resolveFixturesURL(iosRepoRoot: URL) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PRETEXT_FIXTURES_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let workspaceRoot = iosRepoRoot.deletingLastPathComponent()
        let fileManager = FileManager.default
        let candidates = try fileManager.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for candidate in candidates {
            let fixturesURL = candidate.appendingPathComponent("fixtures")
            let manifestURL = fixturesURL
                .appendingPathComponent("cases")
                .appendingPathComponent("index.json")
            if fileManager.fileExists(atPath: manifestURL.path) {
                return fixturesURL
            }
        }

        throw NSError(
            domain: "FixtureHarness",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not find shared fixtures. Set PRETEXT_FIXTURES_ROOT to the fixtures directory."
            ]
        )
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
        let primaryFont: CTFont
        let fallbackFonts = try sharedFallbackFonts(size: font.size)
        let fallbackVerticalMetrics = sharedFallbackVerticalMetrics(size: font.size)
        let sourceKey: String
        let primaryVerticalMetrics: CanonicalVerticalMetrics?

        if let assetPath = font.assetPath {
            let url = fixturesURL.appendingPathComponent(assetPath)
            let registered = try fontRegistry.registerFont(at: url)
            primaryFont = registered.font(size: font.size)
            sourceKey = "asset:\(assetPath)"
            primaryVerticalMetrics = scaledVerticalMetrics(for: assetPath, size: font.size)
        } else {
            primaryFont = resolveSystemOrNamedFont(font)
            sourceKey = "family:\(font.family)|weight:\(font.weight ?? 400)|style:\(font.style)"
            primaryVerticalMetrics = nil
        }

        return LoadedFont(
            primaryFont: primaryFont,
            resolvedFamily: font.family == "system" || font.family == "system-ui" || font.family == "sans-serif"
                ? "system-ui"
                : font.family,
            fallbackFonts: fallbackFonts,
            primaryVerticalMetrics: primaryVerticalMetrics,
            fallbackVerticalMetrics: fallbackVerticalMetrics,
            sourceKey: sourceKey,
            emojiAdvanceScale: emojiAdvanceScale(size: font.size, emojiFont: fallbackFonts[.emoji])
        )
    }

    func sharedFallbackDisplayNames() throws -> [String] {
        let fonts = try sharedFallbackFonts(size: 16)
        return ScriptClass.allCases.compactMap { script in
            guard let font = fonts[script] else { return nil }
            return CTFontCopyPostScriptName(font) as String
        }
    }

    private func sharedFallbackFonts(size: Double) throws -> [ScriptClass: CTFont] {
        var fonts: [ScriptClass: CTFont] = [:]
        fonts[.emoji] = try systemFont(named: ["AppleColorEmoji", "Apple Color Emoji"], size: size)

        for (script, assetPath) in sharedFallbackAssetMap() {
            let url = fixturesURL.appendingPathComponent(assetPath)
            let registered = try fontRegistry.registerFont(at: url)
            fonts[script] = registered.font(size: size)
        }
        return fonts
    }

    private func sharedFallbackVerticalMetrics(size: Double) -> [ScriptClass: CanonicalVerticalMetrics] {
        Dictionary(uniqueKeysWithValues: sharedFallbackAssetMap().compactMap { script, assetPath in
            scaledVerticalMetrics(for: assetPath, size: size).map { metrics in
                (script, metrics)
            }
        })
    }

    private func scaledVerticalMetrics(for assetPath: String, size: Double) -> CanonicalVerticalMetrics? {
        guard let entry = fontMetricsManifest[assetPath] else { return nil }
        let scale = size / Double(entry.unitsPerEm)
        return CanonicalVerticalMetrics(
            ascent: Double(entry.ascent) * scale,
            descent: Double(entry.descent) * scale,
            lineGap: Double(entry.lineGap) * scale
        )
    }

    private func sharedFallbackAssetMap() -> [(ScriptClass, String)] {
        [
            (.generic, "fonts/fallback/NotoSans-Regular.ttf"),
            (.arabic, "fonts/fallback/NotoSansArabic.ttf"),
            (.cjk, "fonts/fallback/NotoSansSC.ttf"),
        ]
    }

    private static func loadFontMetricsManifest(from fixturesURL: URL) throws -> [String: FontMetricsManifestEntry] {
        let url = fixturesURL.appendingPathComponent("fonts/metrics.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: FontMetricsManifestEntry].self, from: data)
    }

    private func systemFont(named candidates: [String], size: Double) throws -> CTFont {
        for candidate in candidates {
            if let font = UIFont(name: candidate, size: 16) {
                return CTFontCreateWithName(font.fontName as CFString, size, nil)
            }
        }
        throw NSError(domain: "FixtureHarness", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Unable to resolve system fallback font from candidates: \(candidates.joined(separator: ", ")).",
        ])
    }

    private func resolveSystemOrNamedFont(_ font: HarnessFont) -> CTFont {
        switch font.family {
        case "system", "system-ui", "sans-serif":
            return applyRequestedTraits(
                UIFont.systemFont(ofSize: font.size),
                requestedWeight: font.weight,
                requestedStyle: font.style
            ) as CTFont
        case "serif":
            let base = UIFont(name: "TimesNewRomanPSMT", size: font.size) ?? UIFont.systemFont(ofSize: font.size)
            return applyRequestedTraits(base, requestedWeight: font.weight, requestedStyle: font.style) as CTFont
        case "monospace":
            let base = UIFont.monospacedSystemFont(ofSize: font.size, weight: cssWeightToUIFont(font.weight))
            return applyRequestedTraits(base, requestedWeight: font.weight, requestedStyle: font.style) as CTFont
        default:
            let base = UIFont(name: font.family, size: font.size) ?? UIFont.systemFont(ofSize: font.size)
            return applyRequestedTraits(base, requestedWeight: font.weight, requestedStyle: font.style) as CTFont
        }
    }

    private func applyRequestedTraits(
        _ base: UIFont,
        requestedWeight: Int?,
        requestedStyle: String
    ) -> UIFont {
        var descriptor = base.fontDescriptor
        var traits = (descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]) ?? [:]
        if let requestedWeight {
            traits[.weight] = cssWeightToUIFont(requestedWeight)
        }
        if !traits.isEmpty {
            descriptor = descriptor.addingAttributes([.traits: traits])
        }
        if requestedStyle == "italic",
           let italicDescriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = italicDescriptor
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private func cssWeightToUIFont(_ value: Int?) -> UIFont.Weight {
        guard let value else { return .regular }
        let clamped = min(max(value, 100), 900)
        let normalized = (CGFloat(clamped) - 400) / 500
        return UIFont.Weight(normalized)
    }

    private func emojiAdvanceScale(size: Double, emojiFont: CTFont?) -> Float {
        guard let emojiFont else { return 1 }
        let rawWidth = rawEmojiWidth(sharedEmojiReferenceProbe, font: emojiFont)
        guard rawWidth > 0 else { return 1 }
        let targetWidth = size * sharedEmojiWidthPerPoint
        return Float(targetWidth / rawWidth)
    }

    private func rawEmojiWidth(_ text: String, font: CTFont) -> Double {
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
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

    func font(size: Double) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: postScriptName,
            kCTFontSizeAttribute: size,
        ] as CFDictionary)
        return CTFontCreateWithGraphicsFont(cgFont, size, nil, descriptor)
    }
}

private struct FontMetricsManifestEntry: Codable {
    let unitsPerEm: Int
    let ascent: Int
    let descent: Int
    let lineGap: Int
}

private struct LoadedFont {
    let primaryFont: CTFont
    let resolvedFamily: String
    let fallbackFonts: [ScriptClass: CTFont]
    let primaryVerticalMetrics: CanonicalVerticalMetrics?
    let fallbackVerticalMetrics: [ScriptClass: CanonicalVerticalMetrics]
    let sourceKey: String
    let emojiAdvanceScale: Float

    var fontDescriptor: FontDescriptor {
        FontDescriptor(primaryFont, cacheKey: cacheKey)
    }

    var cacheKey: String {
        let primaryName = CTFontCopyPostScriptName(primaryFont) as String
        let primarySize = CTFontGetSize(primaryFont)
        let fallbackKey = ScriptClass.allCases.compactMap { script in
            fallbackFonts[script].map { "\(script.rawValue)=\(CTFontCopyPostScriptName($0) as String)" }
        }.joined(separator: "|")
        return "\(sourceKey)|\(primaryName)|\(primarySize)|explicit-fallback|\(fallbackKey)|emoji-scale=\(emojiAdvanceScale)"
    }

    func font(for script: ScriptClass?) -> CTFont {
        guard let script else { return primaryFont }
        return fallbackFonts[script] ?? primaryFont
    }

    func verticalMetrics(for script: ScriptClass?) -> CanonicalVerticalMetrics? {
        guard let script else { return primaryVerticalMetrics }
        return fallbackVerticalMetrics[script] ?? primaryVerticalMetrics
    }
}

private struct CanonicalVerticalMetrics {
    let ascent: Double
    let descent: Double
    let lineGap: Double
}

private enum ScriptClass: String, CaseIterable {
    case generic
    case emoji
    case arabic
    case cjk
}

private struct ScriptSpan {
    let script: ScriptClass?
    let text: String
}

private func splitByScript(_ text: String, primaryFont: CTFont) -> [ScriptSpan] {
    if text.isEmpty { return [] }

    var spans: [ScriptSpan] = []
    var builder = ""
    var currentScript: ScriptClass?
    var hasScript = false
    var index = text.startIndex

    while index < text.endIndex {
        let nextIndex = text.index(after: index)
        let cluster = String(text[index..<nextIndex])
        let scalar = cluster.unicodeScalars.first!
        let script = classifyScript(scalar, cluster: cluster, primaryFont: primaryFont)

        if !hasScript {
            currentScript = script
            hasScript = true
        } else if script != currentScript {
            spans.append(ScriptSpan(script: currentScript, text: builder))
            builder.removeAll(keepingCapacity: true)
            currentScript = script
        }

        builder.append(contentsOf: text[index..<nextIndex])
        index = nextIndex
    }

    if !builder.isEmpty {
        spans.append(ScriptSpan(script: currentScript, text: builder))
    }

    return spans
}

private func classifyScript(
    _ scalar: Unicode.Scalar,
    cluster: String,
    primaryFont: CTFont
) -> ScriptClass? {
    if isEmojiScalar(scalar) { return .emoji }
    if isArabicScript(scalar) { return .arabic }
    if isCJKScalar(scalar) { return .cjk }
    if !cluster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fontSupportsText(primaryFont, cluster) {
        return .generic
    }
    return nil
}

private func fontSupportsText(_ font: CTFont, _ text: String) -> Bool {
    let utf16 = Array(text.utf16)
    if utf16.isEmpty { return true }
    var chars = utf16
    var glyphs = Array(repeating: CGGlyph(), count: chars.count)
    return CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) && glyphs.allSatisfy { $0 != 0 }
}

private func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
    let codePoint = scalar.value
    return codePoint == 0x200D
        || codePoint == 0xFE0E
        || codePoint == 0xFE0F
        || (codePoint >= 0x1F3FB && codePoint <= 0x1F3FF)
        || (codePoint >= 0x1F1E6 && codePoint <= 0x1F1FF)
        || (codePoint >= 0x1F300 && codePoint <= 0x1FAFF)
        || (codePoint >= 0x2600 && codePoint <= 0x27BF)
        || codePoint == 0x2640
        || codePoint == 0x2642
        || codePoint == 0x2695
}

private final class FallbackAwareSegmentMeasurer: SegmentMeasuring {
    private let fonts: LoadedFont

    init(fonts: LoadedFont) {
        self.fonts = fonts
    }

    func measureWidth(_ text: String) -> Float {
        measuredWidth(text)
    }

    func measureHyphenWidth() -> Float {
        measureWidth("-")
    }

    func measureSpaceWidth() -> Float {
        measureWidth(" ")
    }

    func measureGraphemeWidths(_ text: String) -> ContiguousArray<Float> {
        var widths = ContiguousArray<Float>()
        widths.reserveCapacity(text.count)
        for grapheme in text {
            widths.append(measuredWidth(String(grapheme)))
        }
        return widths
    }

    func measureSegmentAndGraphemeWidths(_ text: String) -> (width: Float, graphemeWidths: ContiguousArray<Float>) {
        let graphemeWidths = measureGraphemeWidths(text)
        return (measureWidth(text), graphemeWidths)
    }

    private func makeLine(_ text: String) -> CTLine {
        let attributed = NSMutableAttributedString()
        for span in splitByScript(text, primaryFont: fonts.primaryFont) {
            attributed.append(NSAttributedString(
                string: span.text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): fonts.font(for: span.script),
                ]
            ))
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    private func measuredWidth(_ text: String) -> Float {
        var total: Float = 0
        for span in splitByScript(text, primaryFont: fonts.primaryFont) {
            let attributed = NSAttributedString(
                string: span.text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): fonts.font(for: span.script),
                ]
            )
            let width = Float(CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(attributed),
                nil,
                nil,
                nil
            ))
            total += normalizedWidth(width, script: span.script)
        }
        return total
    }

    private func normalizedWidth(_ width: Float, script: ScriptClass?) -> Float {
        guard script == .emoji else { return width }
        return width * fonts.emojiAdvanceScale
    }
}

private struct RenderSnapshot {
    let contentWidth: Double
    let outerWidth: Double
    let outerHeight: Double
    let lineHeight: Double
    let baselineOffset: Double
    let pngData: Data?
    let contentInkBounds: HarnessBounds?
    let outerInkBounds: HarnessBounds?
    let contentMetricBounds: HarnessBounds?
    let outerMetricBounds: HarnessBounds?
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
                if bytes[index] > inkAlphaThreshold {
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
    let fit: HarnessLayoutFit?

    func resolveLineHeight(fontSize: Double) -> Double {
        lineHeight ?? ((lineHeightFactor ?? 1) * fontSize)
    }
}

private struct HarnessLayoutFit: Decodable {
    let minWidth: Double?
    let targetLineCount: Int?
    let targetHeight: Double?
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
    let fastPathMs: Double
    let renderMs: Double
    let totalMs: Double
}

private struct HarnessRenderResult: Encodable {
    let contentWidth: Double
    let outerWidth: Double
    let outerHeight: Double
    let lineHeightPx: Double
    let lineHeightFactor: Double?
    let layoutWidthPx: Double?
    let fit: HarnessFitResult?
    let snapshotPath: String?
    let contentInkBounds: HarnessBounds?
    let outerInkBounds: HarnessBounds?
    let contentMetricBounds: HarnessBounds?
    let outerMetricBounds: HarnessBounds?
}

private struct HarnessFitResult: Encodable {
    let mode: String
    let requestedMaxWidth: Double
    let minWidth: Double
    let resolvedWidth: Double
    let targetLineCount: Int?
    let targetHeight: Double?
    let didSatisfyTarget: Bool
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
    let lineBreaksUtf16: [Int]
    let lineBreakRoundTripMatches: Bool
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

private struct ResolvedHarnessLayout {
    let width: Double
    let lines: LayoutLinesResult
    let fit: HarnessFitResult?
}

private func materializePersistedUtf16Lines(
    text: String,
    lineBreaksUtf16: [Int]
) throws -> [String] {
    guard !lineBreaksUtf16.isEmpty else { return [text] }
    let starts = [0] + lineBreaksUtf16
    return try starts.enumerated().map { index, start in
        let end = starts.indices.contains(index + 1) ? starts[index + 1] : text.utf16.count
        return try substringByUTF16Range(text, start: start, end: end)
    }
}

private func lineBreaksUtf16FromMaterializedLines(_ lines: [String]) -> [Int] {
    guard lines.count > 1 else { return [] }
    return lines
        .map { $0.utf16.count }
        .reduce(into: [Int]()) { offsets, length in
            offsets.append((offsets.last ?? 0) + length)
        }
        .dropLast()
        .map { $0 }
}

private func substringByUTF16Range(_ text: String, start: Int, end: Int) throws -> String {
    guard
        let startIndex = String.Index(utf16Offset: start, in: text),
        let endIndex = String.Index(utf16Offset: end, in: text)
    else {
        throw NSError(domain: "FixtureHarness", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Invalid UTF-16 line break range \(start)..<\(end)",
        ])
    }
    return String(text[startIndex..<endIndex])
}

private extension String {
    func toWhiteSpaceMode() -> WhiteSpaceMode {
        self == "pre-wrap" ? .preWrap : .normal
    }
}

private extension String.Index {
    init?(utf16Offset: Int, in text: String) {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        guard let index = String.Index(utf16Index, within: text) else { return nil }
        self = index
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
        case .breakableText: return "breakable-text"
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
