import AppKit

/// 类 Bear 风格的实时排版引擎：
/// - 所见即所得模式（.wysiwyg）：使用舒适的正文字体渲染层级、粗斜体、引用缩进、代码块底色与链接色彩，
///   同时将 `#`、`**`、`-`、`[]()` 等语法标记弱化为低对比度辅助色，保证左边缘整齐且光标移动自然不卡顿。
/// - 纯源码模式（.source）：全程使用等宽字体与清晰语法着色。
enum MarkdownStyler {
    struct StyleConfig: Equatable {
        let mode: EditorMode
        let proseFontName: String
        let codeFontName: String
        let fontSize: CGFloat
        let lineSpacing: CGFloat
    }

    static func resolveProseFont(name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if name == "System" || name.isEmpty {
            return .systemFont(ofSize: size, weight: weight)
        }
        if name == "SystemSerif",
           let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif),
           let serif = NSFont(descriptor: descriptor, size: size) {
            return serif
        }
        if let custom = NSFont(name: name, size: size) {
            if weight == .bold || weight == .semibold {
                return NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask)
            }
            return custom
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func resolveCodeFont(name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let custom = NSFont(name: name, size: size) {
            if weight == .bold || weight == .semibold || weight == .medium {
                return NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask)
            }
            return custom
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func apply(to storage: NSTextStorage, config: StyleConfig) {
        let source = storage.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        guard fullRange.length > 0 else { return }

        let baseFont: NSFont = config.mode == .wysiwyg
            ? resolveProseFont(name: config.proseFontName, size: config.fontSize)
            : resolveCodeFont(name: config.codeFontName, size: config.fontSize)
        let monoFont = resolveCodeFont(name: config.codeFontName, size: max(11, config.fontSize * 0.92))
        let syntaxColor = NSColor.tertiaryLabelColor.withAlphaComponent(config.mode == .wysiwyg ? 0.65 : 0.85)
        let accentColor = NSColor.controlAccentColor

        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = config.lineSpacing
        baseParagraph.paragraphSpacing = config.mode == .wysiwyg ? max(4, config.lineSpacing * 0.9) : 0

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: baseParagraph
        ], range: fullRange)

        let lines = source.components(separatedBy: "\n")
        let tableLines = config.mode == .wysiwyg ? detectTables(in: lines) : [:]
        var location = 0
        var insideFence = false

        for (lineIndex, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            let lineRange = NSRange(location: location, length: lineLen)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                storage.addAttributes([
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: monoFont,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.14)
                ], range: lineRange)
            } else if insideFence {
                let codeParagraph = NSMutableParagraphStyle()
                codeParagraph.lineSpacing = max(2, config.lineSpacing * 0.75)
                storage.addAttributes([
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.9),
                    .font: monoFont,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.14),
                    .paragraphStyle: codeParagraph
                ], range: lineRange)
            } else if let tableStyle = tableLines[lineIndex] {
                styleTableLine(
                    line,
                    at: location,
                    lineRange: lineRange,
                    style: tableStyle,
                    monoFont: monoFont,
                    syntaxColor: syntaxColor,
                    accentColor: accentColor,
                    storage: storage
                )
                styleInlineElements(
                    in: line,
                    at: location,
                    config: config,
                    monoFont: monoFont,
                    syntaxColor: syntaxColor,
                    accentColor: accentColor,
                    storage: storage
                )
            } else {
                styleBlockLine(
                    line,
                    trimmed: trimmed,
                    at: location,
                    lineRange: lineRange,
                    config: config,
                    baseFont: baseFont,
                    monoFont: monoFont,
                    syntaxColor: syntaxColor,
                    accentColor: accentColor,
                    storage: storage
                )
            }

            location += lineLen + 1
        }

        storage.endEditing()
    }

    // MARK: - 行级块样式

    private static func styleBlockLine(
        _ line: String,
        trimmed: String,
        at location: Int,
        lineRange: NSRange,
        config: StyleConfig,
        baseFont: NSFont,
        monoFont: NSFont,
        syntaxColor: NSColor,
        accentColor: NSColor,
        storage: NSTextStorage
    ) {
        // 1. 分割线
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            let ruleColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.55)
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: ruleColor,
                .kern: 5.0
            ], range: lineRange)
            return
        }

        // 2. 标题 (# ~ ######)
        if let heading = firstMatch(#"^(\s{0,3})(#{1,6})(\s+)(.+)$"#, in: line) {
            let hashesRange = NSRange(location: location + heading.range(at: 2).location, length: heading.range(at: 2).length)
            let titleRange = NSRange(location: location + heading.range(at: 4).location, length: heading.range(at: 4).length)
            let level = heading.range(at: 2).length

            if config.mode == .wysiwyg {
                let scale: CGFloat
                switch level {
                case 1: scale = 1.68
                case 2: scale = 1.40
                case 3: scale = 1.20
                case 4: scale = 1.08
                default: scale = 1.02
                }
                let headingSize = round(config.fontSize * scale)
                let headingFont = resolveProseFont(
                    name: config.proseFontName,
                    size: headingSize,
                    weight: level <= 2 ? .bold : .semibold
                )
                let headingPara = NSMutableParagraphStyle()
                headingPara.lineSpacing = config.lineSpacing
                headingPara.paragraphSpacingBefore = level <= 2 ? 10 : 6
                headingPara.paragraphSpacing = max(6, config.lineSpacing)

                storage.addAttribute(.paragraphStyle, value: headingPara, range: lineRange)
                // Keep the Markdown source intact, but collapse the visible heading
                // prefix so the first title glyph aligns with body text below it.
                let syntaxPrefix = NSRange(
                    location: hashesRange.location,
                    length: titleRange.location - hashesRange.location
                )
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 1),
                    .foregroundColor: NSColor.clear,
                    .kern: -0.5
                ], range: syntaxPrefix)
                storage.addAttributes([
                    .font: headingFont,
                    .foregroundColor: NSColor.labelColor
                ], range: titleRange)
            } else {
                let scale = CGFloat(max(1.04, 1.45 - Double(level - 1) * 0.08))
                let headingFont = resolveCodeFont(name: config.codeFontName, size: round(config.fontSize * scale), weight: .bold)
                storage.addAttribute(.foregroundColor, value: accentColor.withAlphaComponent(0.75), range: hashesRange)
                storage.addAttribute(.font, value: headingFont, range: titleRange)
            }

            styleInlineElements(
                in: line,
                at: location,
                config: config,
                monoFont: monoFont,
                syntaxColor: syntaxColor,
                accentColor: accentColor,
                storage: storage
            )
            return
        }

        // 3. 引用块 (> ...)
        if let quote = firstMatch(#"^(\s*>+\s?)"#, in: line) {
            let markerRange = NSRange(location: location + quote.range(at: 1).location, length: quote.range(at: 1).length)
            if config.mode == .wysiwyg {
                let quotePara = NSMutableParagraphStyle()
                quotePara.lineSpacing = config.lineSpacing
                quotePara.paragraphSpacing = max(4, config.lineSpacing * 0.8)
                quotePara.firstLineHeadIndent = 6
                quotePara.headIndent = 18
                storage.addAttributes([
                    .paragraphStyle: quotePara,
                    .foregroundColor: NSColor.secondaryLabelColor
                ], range: lineRange)
            } else {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
            }
            storage.addAttributes([
                .foregroundColor: accentColor.withAlphaComponent(0.85),
                .font: resolveCodeFont(name: config.codeFontName, size: config.fontSize, weight: .bold)
            ], range: markerRange)
        }

        // 4. 待办清单与无序/有序列表
        if let todo = firstMatch(#"^(\s*(?:[-*+])\s+)(\[([ xX])\])(\s+)(.*)$"#, in: line) {
            let bulletRange = NSRange(location: location + todo.range(at: 1).location, length: todo.range(at: 1).length)
            let boxRange = NSRange(location: location + todo.range(at: 2).location, length: todo.range(at: 2).length)
            let stateChar = (line as NSString).substring(with: todo.range(at: 3))
            let contentRange = NSRange(location: location + todo.range(at: 5).location, length: todo.range(at: 5).length)
            let isChecked = stateChar.lowercased() == "x"

            storage.addAttribute(.foregroundColor, value: syntaxColor, range: bulletRange)
            storage.addAttributes([
                .font: monoFont,
                .foregroundColor: isChecked ? NSColor.tertiaryLabelColor : accentColor
            ], range: boxRange)

            if isChecked && contentRange.length > 0 {
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.tertiaryLabelColor
                ], range: contentRange)
            }
        } else if let list = firstMatch(#"^(\s*(?:[-*+]|\d+[.)])\s+)"#, in: line) {
            let markerRange = NSRange(location: location + list.range(at: 1).location, length: list.range(at: 1).length)
            storage.addAttributes([
                .foregroundColor: accentColor,
                .font: config.mode == .wysiwyg
                    ? resolveProseFont(name: config.proseFontName, size: config.fontSize, weight: .semibold)
                    : resolveCodeFont(name: config.codeFontName, size: config.fontSize, weight: .semibold)
            ], range: markerRange)
        }

        // 5. 行内语法样式
        styleInlineElements(
            in: line,
            at: location,
            config: config,
            monoFont: monoFont,
            syntaxColor: syntaxColor,
            accentColor: accentColor,
            storage: storage
        )
    }

    // MARK: - 行内语法样式（类 Bear 低对比度标记 + 真实字重样式）

    private static func styleInlineElements(
        in line: String,
        at location: Int,
        config: StyleConfig,
        monoFont: NSFont,
        syntaxColor: NSColor,
        accentColor: NSColor,
        storage: NSTextStorage
    ) {
        // 加粗 **text**
        for match in matches(#"(\*\*)(.+?)(\*\*)"#, in: line) where match.numberOfRanges == 4 {
            let open = NSRange(location: location + match.range(at: 1).location, length: match.range(at: 1).length)
            let body = NSRange(location: location + match.range(at: 2).location, length: match.range(at: 2).length)
            let close = NSRange(location: location + match.range(at: 3).location, length: match.range(at: 3).length)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: open)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: close)
            applyFontTrait(.boldFontMask, in: body, storage: storage)
        }

        // 斜体 *text*
        for match in matches(#"(?<!\*)(\*)([^*]+)(\*)(?!\*)"#, in: line) where match.numberOfRanges == 4 {
            let open = NSRange(location: location + match.range(at: 1).location, length: match.range(at: 1).length)
            let body = NSRange(location: location + match.range(at: 2).location, length: match.range(at: 2).length)
            let close = NSRange(location: location + match.range(at: 3).location, length: match.range(at: 3).length)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: open)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: close)
            applyFontTrait(.italicFontMask, in: body, storage: storage)
        }

        // 删除线 ~~text~~
        for match in matches(#"(~~)(.+?)(~~)"#, in: line) where match.numberOfRanges == 4 {
            let open = NSRange(location: location + match.range(at: 1).location, length: match.range(at: 1).length)
            let body = NSRange(location: location + match.range(at: 2).location, length: match.range(at: 2).length)
            let close = NSRange(location: location + match.range(at: 3).location, length: match.range(at: 3).length)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: open)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: close)
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor
            ], range: body)
        }

        // 高亮 ==text==
        for match in matches(#"(==)(.+?)(==)"#, in: line) where match.numberOfRanges == 4 {
            let open = NSRange(location: location + match.range(at: 1).location, length: match.range(at: 1).length)
            let body = NSRange(location: location + match.range(at: 2).location, length: match.range(at: 2).length)
            let close = NSRange(location: location + match.range(at: 3).location, length: match.range(at: 3).length)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: open)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: close)
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.24), range: body)
        }

        // 链接 [title](url)
        for match in matches(#"(!?\[)([^\]]+)(\]\()([^)]+)(\))"#, in: line) where match.numberOfRanges == 6 {
            let openBracket = NSRange(location: location + match.range(at: 1).location, length: match.range(at: 1).length)
            let labelRange = NSRange(location: location + match.range(at: 2).location, length: match.range(at: 2).length)
            let midRange = NSRange(location: location + match.range(at: 3).location, length: match.range(at: 3).length)
            let urlRange = NSRange(location: location + match.range(at: 4).location, length: match.range(at: 4).length)
            let closeParen = NSRange(location: location + match.range(at: 5).location, length: match.range(at: 5).length)

            storage.addAttribute(.foregroundColor, value: syntaxColor, range: openBracket)
            storage.addAttributes([
                .foregroundColor: accentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: accentColor.withAlphaComponent(0.45)
            ], range: labelRange)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: midRange)
            let smallURLFont = resolveCodeFont(name: config.codeFontName, size: max(11, round(config.fontSize * 0.85)))
            storage.addAttributes([
                .foregroundColor: syntaxColor,
                .font: smallURLFont
            ], range: urlRange)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: closeParen)
        }

        // 行内代码 `code`（放在最后，避免内部星号被误识别）
        for match in matches(#"(?<!`)(`)([^`]+)(`)(?!`)"#, in: line) where match.numberOfRanges == 4 {
            let full = NSRange(location: location + match.range(at: 0).location, length: match.range(at: 0).length)
            let open = NSRange(location: location + match.range(at: 1).location, length: match.range(at: 1).length)
            let body = NSRange(location: location + match.range(at: 2).location, length: match.range(at: 2).length)
            let close = NSRange(location: location + match.range(at: 3).location, length: match.range(at: 3).length)

            storage.addAttributes([
                .font: monoFont,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
            ], range: full)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: open)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: body)
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: close)
        }
    }

    private static func applyFontTrait(_ trait: NSFontTraitMask, in range: NSRange, storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            guard let current = value as? NSFont else { return }
            let converted = NSFontManager.shared.convert(current, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
    }

    // MARK: - 表格识别与样式

    private struct TableLineStyle {
        let isHeader: Bool
        let isSeparator: Bool
    }

    private static func styleTableLine(
        _ line: String,
        at location: Int,
        lineRange: NSRange,
        style: TableLineStyle,
        monoFont: NSFont,
        syntaxColor: NSColor,
        accentColor: NSColor,
        storage: NSTextStorage
    ) {
        if style.isHeader {
            let boldMono = NSFontManager.shared.convert(monoFont, toHaveTrait: .boldFontMask)
            storage.addAttributes([
                .font: boldMono,
                .backgroundColor: accentColor.withAlphaComponent(0.09)
            ], range: lineRange)
        } else if style.isSeparator {
            storage.addAttributes([
                .font: monoFont,
                .foregroundColor: syntaxColor,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
            ], range: lineRange)
            return
        } else {
            storage.addAttributes([
                .font: monoFont,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
            ], range: lineRange)
        }

        let nsLine = line as NSString
        for idx in 0..<nsLine.length where nsLine.character(at: idx) == 124 {
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: NSRange(location: location + idx, length: 1))
        }
    }

    private static func detectTables(in lines: [String]) -> [Int: TableLineStyle] {
        var result: [Int: TableLineStyle] = [:]
        guard lines.count >= 2 else { return result }
        for index in 0..<(lines.count - 1) where isTableHeader(lines[index], separator: lines[index + 1]) {
            result[index] = TableLineStyle(isHeader: true, isSeparator: false)
            result[index + 1] = TableLineStyle(isHeader: false, isSeparator: true)
            var row = index + 2
            while row < lines.count,
                  !lines[row].trimmingCharacters(in: .whitespaces).isEmpty,
                  lines[row].contains("|") {
                result[row] = TableLineStyle(isHeader: false, isSeparator: false)
                row += 1
            }
        }
        return result
    }

    private static func isTableHeader(_ header: String, separator: String) -> Bool {
        guard header.contains("|"), separator.contains("|") else { return false }
        let cells = separator.split(separator: "|", omittingEmptySubsequences: true)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            cell.trimmingCharacters(in: .whitespaces)
                .range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    // MARK: - 正则缓存

    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func firstMatch(_ pattern: String, in string: String) -> NSTextCheckingResult? {
        matches(pattern, in: string).first
    }

    private static func matches(_ pattern: String, in string: String) -> [NSTextCheckingResult] {
        let regex: NSRegularExpression
        if let cached = regexCache[pattern] {
            regex = cached
        } else if let compiled = try? NSRegularExpression(pattern: pattern) {
            regexCache[pattern] = compiled
            regex = compiled
        } else {
            return []
        }
        return regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }
}
