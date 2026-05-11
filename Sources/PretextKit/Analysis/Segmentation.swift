import Foundation

// MARK: - Word Segmentation

/// A single piece from word segmentation + break-kind classification.
struct SegmentationPiece {
    var text: String
    var isWordLike: Bool
    var kind: SegmentBreakKind
    var start: Int // UTF-16 offset into normalized string
}

/// Segments text into words using CFStringTokenizer, then classifies
/// each character within segments by break kind.
func segmentWords(
    _ text: String,
    locale: Locale?
) -> [(text: String, isWordLike: Bool, utf16Start: Int)] {
    if locale == nil {
        return segmentWordsByUnicodeProperties(text)
    }

    let cfStr = text as CFString
    let length = CFStringGetLength(cfStr)
    guard length > 0 else { return [] }

    let cfLocale = locale.map { $0 as CFLocale }
    let tokenizer = CFStringTokenizerCreate(
        kCFAllocatorDefault,
        cfStr,
        CFRangeMake(0, length),
        kCFStringTokenizerUnitWord,
        cfLocale
    )

    var results: [(text: String, isWordLike: Bool, utf16Start: Int)] = []
    var lastEnd = 0

    while true {
        let tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        if tokenType == [] { break }

        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)

        // Gap before this token = non-word segment
        if range.location > lastEnd {
            let gapRange = CFRange(location: lastEnd, length: range.location - lastEnd)
            let gapStr = CFStringCreateWithSubstring(kCFAllocatorDefault, cfStr, gapRange) as String
            results.append((text: gapStr, isWordLike: false, utf16Start: lastEnd))
        }

        // The token itself = word-like segment
        let tokenStr = CFStringCreateWithSubstring(kCFAllocatorDefault, cfStr, range) as String
        results.append((text: tokenStr, isWordLike: true, utf16Start: range.location))
        lastEnd = range.location + range.length
    }

    // Trailing non-word content
    if lastEnd < length {
        let gapRange = CFRange(location: lastEnd, length: length - lastEnd)
        let gapStr = CFStringCreateWithSubstring(kCFAllocatorDefault, cfStr, gapRange) as String
        results.append((text: gapStr, isWordLike: false, utf16Start: lastEnd))
    }

    return results
}

private func segmentWordsByUnicodeProperties(
    _ text: String
) -> [(text: String, isWordLike: Bool, utf16Start: Int)] {
    var results: [(text: String, isWordLike: Bool, utf16Start: Int)] = []
    results.reserveCapacity(max(4, text.unicodeScalars.count / 2))

    var current = ""
    var currentStart = 0
    var offset = 0

    func flush() {
        guard !current.isEmpty else { return }
        results.append((text: current, isWordLike: true, utf16Start: currentStart))
        current.removeAll(keepingCapacity: true)
    }

    for character in text {
        let wordLike = isWordLikeCharacter(character)
        if wordLike {
            if current.isEmpty {
                currentStart = offset
            }
            current.append(character)
        } else {
            flush()
            results.append((text: String(character), isWordLike: false, utf16Start: offset))
        }
        offset += character.utf16.count
    }
    flush()

    return results
}

private func isWordLikeCharacter(_ character: Character) -> Bool {
    var sawWordLikeScalar = false
    for scalar in character.unicodeScalars {
        if isWordLikeScalar(scalar) {
            sawWordLikeScalar = true
            continue
        }
        return false
    }
    return sawWordLikeScalar
}

private func isWordLikeScalar(_ scalar: Unicode.Scalar) -> Bool {
    if isCombiningMark(scalar) { return true }
    if scalar == "_" { return true }
    if scalar.properties.isAlphabetic { return true }
    return scalar.properties.numericType == .decimal
}

// MARK: - Break Kind Classification

/// Splits a single word segment into sub-pieces based on per-character break kind.
/// E.g., "hello\u{00AD}world" splits into ["hello", SHY, "world"].
func splitSegmentByBreakKind(
    _ segment: String,
    isWordLike: Bool,
    start: Int,
    whiteSpace: WhiteSpaceMode
) -> [SegmentationPiece] {
    var pieces: [SegmentationPiece] = []
    pieces.reserveCapacity(segment.unicodeScalars.count)
    forEachSegmentPiece(segment, isWordLike: isWordLike, start: start, whiteSpace: whiteSpace) { piece in
        pieces.append(piece)
    }
    return pieces
}

func forEachSegmentPiece(
    _ segment: String,
    isWordLike: Bool,
    start: Int,
    whiteSpace: WhiteSpaceMode,
    _ body: (SegmentationPiece) -> Void
) {
    var currentKind: SegmentBreakKind?
    var currentText = ""
    var currentStart = start
    var currentWordLike = false
    var offset = 0

    for scalar in segment.unicodeScalars {
        let kind = classifyBreakKindForMode(scalar, whiteSpace: whiteSpace)
        let wordLike = kind == .text && isWordLike

        if let prevKind = currentKind, kind == prevKind, wordLike == currentWordLike {
            currentText.unicodeScalars.append(scalar)
            offset += Int(scalar.utf16.count)
            continue
        }

        if currentKind != nil {
            body(SegmentationPiece(
                text: currentText,
                isWordLike: currentWordLike,
                kind: currentKind!,
                start: currentStart
            ))
        }

        currentKind = kind
        currentText = String(scalar)
        currentStart = start + offset
        currentWordLike = wordLike
        offset += Int(scalar.utf16.count)
    }

    if let kind = currentKind {
        body(SegmentationPiece(
            text: currentText,
            isWordLike: currentWordLike,
            kind: kind,
            start: currentStart
        ))
    }
}

/// Classify a scalar's break kind, respecting white-space mode.
private func classifyBreakKindForMode(_ scalar: Unicode.Scalar, whiteSpace: WhiteSpaceMode) -> SegmentBreakKind {
    if whiteSpace == .preWrap {
        switch scalar {
        case " ": return .preservedSpace
        case "\t": return .tab
        case "\n": return .hardBreak
        default: break
        }
    }
    return classifyBreakKind(scalar)
}
