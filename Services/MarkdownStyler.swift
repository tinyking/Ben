import AppKit

extension NSAttributedString.Key {
    /// 标记独立分割线行（由 `BenEditorTextView` 渲染居中满宽 1pt 细横线）。
    static let benHorizontalRule = NSAttributedString.Key("ben.horizontalRule")
    /// 标记引用块嵌套层级（`1...N`，由 `BenEditorTextView` 绘制左侧竖线）。
    static let benBlockquoteDepth = NSAttributedString.Key("ben.blockquoteDepth")
    /// 标记围栏代码块行类型（`"fence"` 或 `"body"`，由 `BenEditorTextView` 绘制整宽圆角底板）。
    static let benCodeBlock = NSAttributedString.Key("ben.codeBlock")
    /// 标记该行包含的图片渲染规格（`BenImageLayoutSpec`，由 `NSLayoutManagerDelegate` 撑开行高并由 `BenEditorTextView` 绘制图片）。
    static let benImageAttachment = NSAttributedString.Key("ben.imageAttachment")
    /// 标记在所见即所得非激活行中零宽隐藏的语法定界符。
    static let benHiddenSyntax = NSAttributedString.Key("ben.hiddenSyntax")
    /// 标记无序列表标记字符在非光标行应显示为圆点 `•`（字形替换，不改变文本内容与光标位置）。
    static let benBulletGlyph = NSAttributedString.Key("ben.bulletGlyph")
}

/// 分层实时 Markdown 排版引擎：
/// - Pass 1：扫描多行围栏代码块（支持 3+ 反引号与波浪线配对）与 GFM 表格结构；
/// - Pass 2：按完整段落（含末尾 `\n`）写入唯一 `NSParagraphStyle` 与块级属性，绝不与行内混写；
/// - Pass 3：基于 UTF-16 `NSRange` 先隔离行内代码与链接/图片语法，支持空 alt 图片、带空格/括号路径及 `![[WikiImage]]`，
///   在所见即所得非光标行中零宽折叠语法标记，光标移入该行时自动展开以便直接编辑。
enum MarkdownStyler {
    struct StyleConfig: Equatable {
        let mode: EditorMode
        let proseFontName: String
        let codeFontName: String
        let fontSize: CGFloat
        let lineSpacing: CGFloat
        var noteURL: URL? = nil
        var vaultURL: URL? = nil
    }

    enum CodeLineState: Equatable {
        case none
        case openingFence
        case codeBody
        case closingFence
    }

    private static let hiddenSyntaxFont = NSFont.systemFont(ofSize: 0.01)
    /// 白纸排版低饱和中灰列表标记色（`#6E6E73`）。
    static let listMarkerMutedGray = NSColor(srgbRed: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0, alpha: 1.0)

    // MARK: - 字体解析与字重合成

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
        if name == "System" || name.isEmpty {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        if let custom = NSFont(name: name, size: size) {
            if weight == .bold || weight == .semibold || weight == .medium {
                return NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask)
            }
            return custom
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func isBoldFont(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        if let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
           let weight = traits[.weight] as? CGFloat,
           weight >= NSFont.Weight.semibold.rawValue - 0.05 {
            return true
        }
        let lower = font.fontName.lowercased()
        return lower.contains("bold") || lower.contains("semibold") || lower.contains("heavy")
    }

    /// 供测试或离屏调用的便捷构造方法。
    static func styledStorage(
        for markdown: String,
        config: StyleConfig,
        activeRanges: [NSRange] = []
    ) -> NSTextStorage {
        let storage = NSTextStorage(string: markdown)
        apply(to: storage, config: config, activeRanges: activeRanges)
        return storage
    }

    // MARK: - 多行围栏代码块与分割线判定（供大纲与摘要提取复用）

    /// 遵循 CommonMark 规范识别 3 个及以上 `` ` `` 或 `~` 围栏代码块（例如外层 ```` ````text ```` 可安全包裹内层 ` ``` `）。
    static func computeCodeBlockLineStates(in lines: [String]) -> [CodeLineState] {
        var states = Array(repeating: CodeLineState.none, count: lines.count)
        var openFence: (char: Character, length: Int)?

        for (idx, line) in lines.enumerated() {
            if let current = openFence {
                if let closeLen = matchClosingFence(line, char: current.char), closeLen >= current.length {
                    states[idx] = .closingFence
                    openFence = nil
                } else {
                    states[idx] = .codeBody
                }
            } else if let opened = matchOpeningFence(line) {
                states[idx] = .openingFence
                openFence = opened
            }
        }
        return states
    }

    /// 严格识别独立成行的 CommonMark 水平分割线（`---`、`***`、`___`、`- - -` 等，最多 3 个前导空格）。
    static func isHorizontalRuleLine(_ line: String) -> Bool {
        firstMatch(#"^ {0,3}(?:(-[ \t]*){3,}|(\*[ \t]*){3,}|(_[ \t]*){3,})$"#, in: line) != nil
    }

    private static func matchOpeningFence(_ line: String) -> (char: Character, length: Int)? {
        guard let match = firstMatch(#"^ {0,3}(`{3,}|~{3,})(.*)$"#, in: line) else { return nil }
        let ns = line as NSString
        let fence = ns.substring(with: match.range(at: 1))
        let info = ns.substring(with: match.range(at: 2))
        guard let ch = fence.first else { return nil }
        // CommonMark 规则：反引号围栏的 info string 内不能再出现反引号（否则如 ```code``` 是单行行内代码）
        if ch == "`" && info.contains("`") {
            return nil
        }
        return (ch, fence.count)
    }

    private static func matchClosingFence(_ line: String, char: Character) -> Int? {
        let pattern = char == "`" ? #"^ {0,3}(`{3,})[ \t]*$"# : #"^ {0,3}(~{3,})[ \t]*$"#
        guard let match = firstMatch(pattern, in: line) else { return nil }
        return match.range(at: 1).length
    }

    // MARK: - 主入口

    static func apply(
        to storage: NSTextStorage,
        config: StyleConfig,
        activeRanges: [NSRange] = []
    ) {
        let source = storage.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        guard fullRange.length > 0 else { return }

        let baseFont: NSFont = config.mode == .wysiwyg
            ? resolveProseFont(name: config.proseFontName, size: config.fontSize)
            : resolveCodeFont(name: config.codeFontName, size: config.fontSize)
        let monoFont = resolveCodeFont(name: config.codeFontName, size: max(11, round(config.fontSize * 0.90)))
        let syntaxColor = NSColor.tertiaryLabelColor.withAlphaComponent(config.mode == .wysiwyg ? 0.68 : 0.85)
        let accentColor = NSColor.controlAccentColor

        let baseParagraph = makeBaseParagraphStyle(config: config)

        storage.beginEditing()
        // 清空全部旧自定义属性（如分割线、隐藏标记、删除线、背景色），建立干净基准段落样式
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: baseParagraph
        ], range: fullRange)

        let lines = source.components(separatedBy: "\n")
        let codeStates = computeCodeBlockLineStates(in: lines)
        let tableLines = config.mode == .wysiwyg ? detectTables(in: lines, codeStates: codeStates) : [:]

        var location = 0
        for (lineIndex, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            let hasNewline = lineIndex < lines.count - 1
            let lineRange = NSRange(location: location, length: lineLen)
            let paragraphRange = NSRange(location: location, length: lineLen + (hasNewline ? 1 : 0))
            let isLineActive = isLineSelectedOrFocused(lineRange: lineRange, activeRanges: activeRanges)

            switch codeStates[lineIndex] {
            case .openingFence, .closingFence:
                let fenceParagraph = NSMutableParagraphStyle()
                fenceParagraph.lineSpacing = max(2, config.lineSpacing * 0.75)
                fenceParagraph.paragraphSpacing = codeStates[lineIndex] == .closingFence ? max(6, config.lineSpacing) : 0
                fenceParagraph.paragraphSpacingBefore = codeStates[lineIndex] == .openingFence ? 4 : 0
                storage.addAttribute(.paragraphStyle, value: fenceParagraph, range: paragraphRange)
                storage.addAttributes([
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: monoFont,
                    .benCodeBlock: "fence"
                ], range: lineRange)

            case .codeBody:
                let codeParagraph = NSMutableParagraphStyle()
                codeParagraph.lineSpacing = max(2, config.lineSpacing * 0.75)
                codeParagraph.paragraphSpacing = 0
                storage.addAttribute(.paragraphStyle, value: codeParagraph, range: paragraphRange)
                storage.addAttributes([
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.92),
                    .font: monoFont,
                    .benCodeBlock: "body"
                ], range: lineRange.length > 0 ? lineRange : paragraphRange)

            case .none:
                if let tableStyle = tableLines[lineIndex] {
                    styleTableLine(
                        line,
                        at: location,
                        lineRange: lineRange,
                        paragraphRange: paragraphRange,
                        isLineActive: isLineActive,
                        style: tableStyle,
                        config: config,
                        monoFont: monoFont,
                        syntaxColor: syntaxColor,
                        accentColor: accentColor,
                        storage: storage
                    )
                } else {
                    styleBlockAndInline(
                        line,
                        at: location,
                        lineRange: lineRange,
                        paragraphRange: paragraphRange,
                        isLineActive: isLineActive,
                        config: config,
                        baseFont: baseFont,
                        monoFont: monoFont,
                        syntaxColor: syntaxColor,
                        accentColor: accentColor,
                        storage: storage
                    )
                }
            }

            location += lineLen + 1
        }

        storage.endEditing()
    }

    static func makeBaseParagraphStyle(config: StyleConfig) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = config.lineSpacing
        paragraph.paragraphSpacing = config.mode == .wysiwyg ? max(4, config.lineSpacing * 0.9) : 0
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 0
        return paragraph
    }

    private static func isLineSelectedOrFocused(lineRange: NSRange, activeRanges: [NSRange]) -> Bool {
        guard !activeRanges.isEmpty else { return false }
        let start = lineRange.location
        let end = lineRange.location + lineRange.length
        for sel in activeRanges {
            if sel.length == 0 {
                if sel.location >= start && sel.location <= end {
                    return true
                }
            } else {
                let selEnd = sel.location + sel.length
                if sel.location <= end && selEnd >= start {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Pass 2：块级样式（段落样式仅写入含 `\n` 的 `paragraphRange`）

    private static func styleBlockAndInline(
        _ line: String,
        at location: Int,
        lineRange: NSRange,
        paragraphRange: NSRange,
        isLineActive: Bool,
        config: StyleConfig,
        baseFont: NSFont,
        monoFont: NSFont,
        syntaxColor: NSColor,
        accentColor: NSColor,
        storage: NSTextStorage
    ) {
        guard lineRange.length > 0 else { return }

        // 1. 独立水平分割线（--- / *** / ___）
        if isHorizontalRuleLine(line) {
            let hrPara = NSMutableParagraphStyle()
            hrPara.lineSpacing = config.lineSpacing
            hrPara.paragraphSpacingBefore = 6
            hrPara.paragraphSpacing = max(6, config.lineSpacing)
            storage.addAttribute(.paragraphStyle, value: hrPara, range: paragraphRange)
            storage.addAttribute(.benHorizontalRule, value: true, range: lineRange)

            if config.mode == .wysiwyg && !isLineActive {
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                storage.addAttribute(.benHiddenSyntax, value: true, range: lineRange)
            } else {
                storage.addAttributes([
                    .font: monoFont,
                    .foregroundColor: syntaxColor
                ], range: lineRange)
            }
            return
        }

        // 2. ATX 标题（# ~ ######，支持可选闭合 #）
        if let heading = firstMatch(#"^( {0,3})(#{1,6})([ \t]+)(.*?)(?:([ \t]+#+)[ \t]*)?$"#, in: line) {
            let leadSpacesRange = heading.range(at: 1)
            let hashesInLine = heading.range(at: 2)
            let spaceAfterHash = heading.range(at: 3)
            let contentInLine = heading.range(at: 4)
            let closingHashesInLine = heading.range(at: 5)
            let level = hashesInLine.length

            let prefixGlobal = NSRange(
                location: location + leadSpacesRange.location,
                length: leadSpacesRange.length + hashesInLine.length + spaceAfterHash.length
            )
            let titleGlobal = NSRange(location: location + contentInLine.location, length: contentInLine.length)

            let blockFontSize: CGFloat
            if config.mode == .wysiwyg {
                let scale: CGFloat
                switch level {
                case 1: scale = 1.68
                case 2: scale = 1.40
                case 3: scale = 1.20
                case 4: scale = 1.08
                default: scale = 1.02
                }
                blockFontSize = round(config.fontSize * scale)
                let headingFont = resolveProseFont(
                    name: config.proseFontName,
                    size: blockFontSize,
                    weight: level <= 2 ? .bold : .semibold
                )

                let headingPara = NSMutableParagraphStyle()
                headingPara.lineSpacing = config.lineSpacing
                headingPara.paragraphSpacingBefore = level <= 2 ? 10 : 6
                headingPara.paragraphSpacing = max(6, config.lineSpacing)
                headingPara.firstLineHeadIndent = 0
                headingPara.headIndent = 0
                storage.addAttribute(.paragraphStyle, value: headingPara, range: paragraphRange)

                storage.addAttributes([
                    .font: headingFont,
                    .foregroundColor: NSColor.labelColor
                ], range: lineRange)

                if !isLineActive && contentInLine.length > 0 {
                    hideSyntax(prefixGlobal, in: storage)
                    if closingHashesInLine.location != NSNotFound && closingHashesInLine.length > 0 {
                        let closeGlobal = NSRange(location: location + closingHashesInLine.location, length: closingHashesInLine.length)
                        hideSyntax(closeGlobal, in: storage)
                    }
                } else {
                    storage.addAttribute(.foregroundColor, value: syntaxColor, range: prefixGlobal)
                    if closingHashesInLine.location != NSNotFound && closingHashesInLine.length > 0 {
                        let closeGlobal = NSRange(location: location + closingHashesInLine.location, length: closingHashesInLine.length)
                        storage.addAttribute(.foregroundColor, value: syntaxColor, range: closeGlobal)
                    }
                }
            } else {
                let scale = CGFloat(max(1.04, 1.45 - Double(level - 1) * 0.08))
                blockFontSize = round(config.fontSize * scale)
                let headingFont = resolveCodeFont(name: config.codeFontName, size: blockFontSize, weight: .bold)
                storage.addAttribute(.foregroundColor, value: accentColor.withAlphaComponent(0.75), range: prefixGlobal)
                if titleGlobal.length > 0 {
                    storage.addAttribute(.font, value: headingFont, range: titleGlobal)
                }
            }

            if contentInLine.length > 0 {
                styleInlineElements(
                    in: line,
                    subRangeInLine: contentInLine,
                    lineGlobalLocation: location,
                    isLineActive: isLineActive,
                    blockFontSize: blockFontSize,
                    config: config,
                    syntaxColor: syntaxColor,
                    accentColor: accentColor,
                    storage: storage
                )
            }
            return
        }

        // 3. 引用块（> / >> ...）
        if let quote = firstMatch(#"^( {0,3}(?:>[ \t]?)+)(.*)$"#, in: line) {
            let prefixInLine = quote.range(at: 1)
            let contentInLine = quote.range(at: 2)
            let nsLine = line as NSString
            let prefixStr = nsLine.substring(with: prefixInLine)
            let depth = max(1, prefixStr.filter { $0 == ">" }.count)
            let markerGlobal = NSRange(location: location + prefixInLine.location, length: prefixInLine.length)

            if config.mode == .wysiwyg {
                let indent = CGFloat(depth) * 16
                let quotePara = NSMutableParagraphStyle()
                quotePara.lineSpacing = config.lineSpacing
                quotePara.paragraphSpacing = max(4, config.lineSpacing * 0.8)
                quotePara.firstLineHeadIndent = indent
                quotePara.headIndent = indent

                storage.addAttribute(.paragraphStyle, value: quotePara, range: paragraphRange)
                storage.addAttribute(.benBlockquoteDepth, value: depth, range: paragraphRange)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)

                let contentTrimmed = nsLine.substring(with: contentInLine).trimmingCharacters(in: .whitespaces)
                if !isLineActive && !contentTrimmed.isEmpty {
                    hideSyntax(markerGlobal, in: storage)
                } else {
                    storage.addAttributes([
                        .foregroundColor: accentColor.withAlphaComponent(0.78),
                        .font: resolveCodeFont(name: config.codeFontName, size: config.fontSize, weight: .bold)
                    ], range: markerGlobal)
                }
            } else {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
                storage.addAttributes([
                    .foregroundColor: accentColor.withAlphaComponent(0.85),
                    .font: resolveCodeFont(name: config.codeFontName, size: config.fontSize, weight: .bold)
                ], range: markerGlobal)
            }

            if contentInLine.length > 0 {
                styleInlineElements(
                    in: line,
                    subRangeInLine: contentInLine,
                    lineGlobalLocation: location,
                    isLineActive: isLineActive,
                    blockFontSize: config.fontSize,
                    config: config,
                    syntaxColor: syntaxColor,
                    accentColor: accentColor,
                    storage: storage
                )
            }
            return
        }

        // 4. 待办清单（严格要求单个 - / * / + 后紧跟空白符）
        if let todo = firstMatch(#"^([ \t]*)([-*+])([ \t]+)(\[([ xX])\])([ \t]+)(.*)$"#, in: line) {
            let nsLine = line as NSString
            let indentInLine = todo.range(at: 1)
            let bulletInLine = todo.range(at: 2)
            let space1InLine = todo.range(at: 3)
            let boxInLine = todo.range(at: 4)
            let stateChar = nsLine.substring(with: todo.range(at: 5))
            let contentInLine = todo.range(at: 7)
            let isChecked = stateChar.lowercased() == "x"

            let bulletAndSpaceGlobal = NSRange(
                location: location + bulletInLine.location,
                length: bulletInLine.length + space1InLine.length
            )
            let boxGlobal = NSRange(location: location + boxInLine.location, length: boxInLine.length)
            let contentGlobal = NSRange(location: location + contentInLine.location, length: contentInLine.length)

            if config.mode == .wysiwyg {
                let indentCols = Self.visualIndentColumns(nsLine.substring(with: indentInLine))
                let baseIndent = CGFloat(indentCols / 2) * 18
                let listPara = NSMutableParagraphStyle()
                listPara.lineSpacing = config.lineSpacing
                listPara.paragraphSpacing = max(4, config.lineSpacing * 0.85)
                listPara.firstLineHeadIndent = baseIndent
                listPara.headIndent = baseIndent + round(config.fontSize * 2.1)
                storage.addAttribute(.paragraphStyle, value: listPara, range: paragraphRange)
            }

            storage.addAttribute(.foregroundColor, value: syntaxColor, range: bulletAndSpaceGlobal)
            storage.addAttributes([
                .font: monoFont,
                .foregroundColor: isChecked ? NSColor.tertiaryLabelColor : accentColor
            ], range: boxGlobal)

            if isChecked && contentGlobal.length > 0 {
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.tertiaryLabelColor
                ], range: contentGlobal)
            }

            if contentInLine.length > 0 {
                styleInlineElements(
                    in: line,
                    subRangeInLine: contentInLine,
                    lineGlobalLocation: location,
                    isLineActive: isLineActive,
                    blockFontSize: config.fontSize,
                    config: config,
                    syntaxColor: syntaxColor,
                    accentColor: accentColor,
                    storage: storage
                )
            }
            return
        }

        // 5. 无序列表与有序列表（严格要求 - / * / + 或 1. / 1) 后必须紧跟至少一个空白字符，绝不误匹配 **加粗** 或 *斜体*）
        if let list = firstMatch(#"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(.*)$"#, in: line) {
            let nsLine = line as NSString
            let indentInLine = list.range(at: 1)
            let markerInLine = list.range(at: 2)
            let spaceInLine = list.range(at: 3)
            let contentInLine = list.range(at: 4)
            let markerGlobal = NSRange(location: location + markerInLine.location, length: markerInLine.length)
            let markerText = (line as NSString).substring(with: markerInLine)
            let isUnorderedMarker = markerText == "-" || markerText == "*" || markerText == "+"

            let markerAndSpaceGlobal = NSRange(
                location: location + markerInLine.location,
                length: markerInLine.length + spaceInLine.length
            )
            let markerFont = config.mode == .wysiwyg
                ? resolveProseFont(name: config.proseFontName, size: config.fontSize, weight: .semibold)
                : resolveCodeFont(name: config.codeFontName, size: config.fontSize, weight: .semibold)

            if config.mode == .wysiwyg {
                let indentCols = Self.visualIndentColumns(nsLine.substring(with: indentInLine))
                let baseIndent = CGFloat(indentCols / 2) * 18
                let markerSample = nsLine.substring(with: NSRange(
                    location: markerInLine.location,
                    length: markerInLine.length + spaceInLine.length
                ))
                let markerWidth = ceil((markerSample as NSString).size(withAttributes: [.font: markerFont]).width)
                let listPara = NSMutableParagraphStyle()
                listPara.lineSpacing = config.lineSpacing
                listPara.paragraphSpacing = max(4, config.lineSpacing * 0.85)
                listPara.firstLineHeadIndent = baseIndent
                listPara.headIndent = baseIndent + max(16, markerWidth)
                storage.addAttribute(.paragraphStyle, value: listPara, range: paragraphRange)
            }

            storage.addAttributes([
                .foregroundColor: config.mode == .wysiwyg ? listMarkerMutedGray : accentColor,
                .font: markerFont
            ], range: markerAndSpaceGlobal)

            // 非光标行的无序列表标记改为圆点 •（仅字形替换，文本仍是 -，光标位置不变）。
            // 光标进入该行时标记为 false 分支不写入属性，自动恢复横杠以便直接编辑。
            if config.mode == .wysiwyg && !isLineActive && isUnorderedMarker {
                storage.addAttribute(.benBulletGlyph, value: true, range: markerGlobal)
            }

            // 仅对列表标记之后的内容区间做行内扫描，列表符号 `*` 绝不会参与斜体配对
            if contentInLine.length > 0 {
                styleInlineElements(
                    in: line,
                    subRangeInLine: contentInLine,
                    lineGlobalLocation: location,
                    isLineActive: isLineActive,
                    blockFontSize: config.fontSize,
                    config: config,
                    syntaxColor: syntaxColor,
                    accentColor: accentColor,
                    storage: storage
                )
            }
            return
        }

        // 6. 普通段落（保留 baseParagraph：firstLineHeadIndent = 0, headIndent = 0）
        styleInlineElements(
            in: line,
            subRangeInLine: NSRange(location: 0, length: lineRange.length),
            lineGlobalLocation: location,
            isLineActive: isLineActive,
            blockFontSize: config.fontSize,
            config: config,
            syntaxColor: syntaxColor,
            accentColor: accentColor,
            storage: storage
        )
    }

    private static func visualIndentColumns(_ whitespace: String) -> Int {
        whitespace.reduce(0) { acc, ch in
            acc + (ch == "\t" ? 4 : 1)
        }
    }

    // MARK: - Pass 3：行内语法样式（绝不修改 `.paragraphStyle`，全程精确 UTF-16 `NSRange`）

    private static func styleInlineElements(
        in line: String,
        subRangeInLine: NSRange,
        lineGlobalLocation: Int,
        isLineActive: Bool,
        blockFontSize: CGFloat,
        config: StyleConfig,
        syntaxColor: NSColor,
        accentColor: NSColor,
        storage: NSTextStorage
    ) {
        guard subRangeInLine.length > 0 else { return }
        let nsLine = line as NSString
        let sub = nsLine.substring(with: subRangeInLine)
        let nsSub = sub as NSString
        let baseLoc = lineGlobalLocation + subRangeInLine.location
        let shouldHideMarkers = config.mode == .wysiwyg && !isLineActive

        // Step 1：最先扫描并锁定行内代码区间（支持单反引号 `a` 与多反引号 `` `a` ``），防止内部符号泄漏或跨代码区间误匹配
        var occupiedCodeRanges: [NSRange] = []
        let inlineCodeFont = resolveCodeFont(name: config.codeFontName, size: max(11, round(blockFontSize * 0.88)))

        for match in matches(#"(`+)(.+?)(?<!`)\1(?!`)"#, in: sub) where match.numberOfRanges == 3 {
            let fullLocal = match.range(at: 0)
            let openTicksLocal = match.range(at: 1)
            let bodyLocal = match.range(at: 2)
            let closeTicksLocal = NSRange(
                location: fullLocal.location + fullLocal.length - openTicksLocal.length,
                length: openTicksLocal.length
            )

            occupiedCodeRanges.append(fullLocal)

            let openGlobal = NSRange(location: baseLoc + openTicksLocal.location, length: openTicksLocal.length)
            let bodyGlobal = NSRange(location: baseLoc + bodyLocal.location, length: bodyLocal.length)
            let closeGlobal = NSRange(location: baseLoc + closeTicksLocal.location, length: closeTicksLocal.length)

            storage.addAttributes([
                .font: inlineCodeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
            ], range: bodyGlobal)

            if shouldHideMarkers {
                hideSyntax(openGlobal, in: storage)
                hideSyntax(closeGlobal, in: storage)
            } else {
                storage.addAttributes([
                    .font: inlineCodeFont,
                    .foregroundColor: syntaxColor,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
                ], range: openGlobal)
                storage.addAttributes([
                    .font: inlineCodeFont,
                    .foregroundColor: syntaxColor,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
                ], range: closeGlobal)
            }
        }

        func isFreeOfCode(_ localRange: NSRange) -> Bool {
            !occupiedCodeRanges.contains { NSIntersectionRange($0, localRange).length > 0 }
        }

        // Step 2：扫描图片与链接（支持空 alt `![](...)`、带空格/括号本地路径、`![](<path>)`、`"title"` 以及 Obsidian `![[img.png|400]]`）
        var occupiedURLRanges: [NSRange] = []
        var renderedImages: [BenRenderedImageItem] = []
        var imageFullRangesInSub: [NSRange] = []

        // 2a. WikiLink 图片语法 `![[path/to/image.png]]` 或 `![[image.png|400]]` / `![[image.png|图注]]`
        for wikiMatch in matches(#"(!\[\[)([^\[\]\n]+)(\]\])"#, in: sub) where wikiMatch.numberOfRanges == 4 {
            let fullLocal = wikiMatch.range(at: 0)
            guard isFreeOfCode(fullLocal) else { continue }
            let openLocal = wikiMatch.range(at: 1)
            let innerLocal = wikiMatch.range(at: 2)
            let closeLocal = wikiMatch.range(at: 3)
            let innerStr = nsSub.substring(with: innerLocal)

            let parts = innerStr.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let targetPath = parts[0].trimmingCharacters(in: .whitespaces)
            guard !targetPath.isEmpty else { continue }

            var customWidth: CGFloat?
            var altCaption = ""
            if parts.count > 1 {
                let param = parts[1].trimmingCharacters(in: .whitespaces)
                if let w = Double(param), w > 16 {
                    customWidth = CGFloat(w)
                } else {
                    altCaption = param
                }
            }

            occupiedURLRanges.append(fullLocal)
            imageFullRangesInSub.append(fullLocal)

            let fullGlobal = NSRange(location: baseLoc + fullLocal.location, length: fullLocal.length)
            let openGlobal = NSRange(location: baseLoc + openLocal.location, length: openLocal.length)
            let innerGlobal = NSRange(location: baseLoc + innerLocal.location, length: innerLocal.length)
            let closeGlobal = NSRange(location: baseLoc + closeLocal.location, length: closeLocal.length)

            if config.mode == .wysiwyg {
                let loadState = MarkdownImageLoader.shared.resolveImage(
                    source: targetPath,
                    noteURL: config.noteURL,
                    vaultURL: config.vaultURL
                )
                renderedImages.append(BenRenderedImageItem(
                    alt: altCaption,
                    source: targetPath,
                    title: nil,
                    preferredMaxWidth: customWidth,
                    state: loadState
                ))
            }

            if shouldHideMarkers {
                hideSyntax(fullGlobal, in: storage)
            } else {
                let smallURLFont = resolveCodeFont(name: config.codeFontName, size: max(11, round(blockFontSize * 0.86)))
                storage.addAttribute(.foregroundColor, value: syntaxColor, range: openGlobal)
                storage.addAttributes([
                    .foregroundColor: accentColor,
                    .font: smallURLFont
                ], range: innerGlobal)
                storage.addAttribute(.foregroundColor, value: syntaxColor, range: closeGlobal)
            }
        }

        // 2b. 标准 Markdown 图片 `![alt](destination "title")` 与链接 `[label](destination "title")`
        for token in scanMarkdownLinksAndImages(in: nsSub) {
            guard isFreeOfCode(token.fullRange),
                  !occupiedURLRanges.contains(where: { NSIntersectionRange($0, token.fullRange).length > 0 }) else {
                continue
            }

            let openGlobal = NSRange(location: baseLoc + token.openRange.location, length: token.openRange.length)
            let labelGlobal = NSRange(location: baseLoc + token.labelRange.location, length: token.labelRange.length)
            let midGlobal = NSRange(location: baseLoc + token.midRange.location, length: token.midRange.length)
            let destGlobal = NSRange(location: baseLoc + token.destRange.location, length: token.destRange.length)
            let closeGlobal = NSRange(location: baseLoc + token.closeRange.location, length: token.closeRange.length)
            let fullGlobal = NSRange(location: baseLoc + token.fullRange.location, length: token.fullRange.length)

            if token.isImage {
                occupiedURLRanges.append(token.fullRange)
                imageFullRangesInSub.append(token.fullRange)

                let parsedDest = Self.parseDestinationAndTitle(nsSub.substring(with: token.destRange))
                let altText = nsSub.substring(with: token.labelRange)

                if config.mode == .wysiwyg {
                    let loadState = MarkdownImageLoader.shared.resolveImage(
                        source: parsedDest.source,
                        noteURL: config.noteURL,
                        vaultURL: config.vaultURL
                    )
                    renderedImages.append(BenRenderedImageItem(
                        alt: altText,
                        source: parsedDest.source,
                        title: parsedDest.title,
                        preferredMaxWidth: nil,
                        state: loadState
                    ))
                }

                if shouldHideMarkers {
                    hideSyntax(fullGlobal, in: storage)
                } else {
                    let smallURLFont = resolveCodeFont(name: config.codeFontName, size: max(11, round(blockFontSize * 0.85)))
                    storage.addAttribute(.foregroundColor, value: syntaxColor, range: openGlobal)
                    if labelGlobal.length > 0 {
                        storage.addAttribute(.foregroundColor, value: accentColor, range: labelGlobal)
                    }
                    storage.addAttribute(.foregroundColor, value: syntaxColor, range: midGlobal)
                    if destGlobal.length > 0 {
                        storage.addAttributes([
                            .foregroundColor: syntaxColor,
                            .font: smallURLFont
                        ], range: destGlobal)
                    }
                    storage.addAttribute(.foregroundColor, value: syntaxColor, range: closeGlobal)
                }
            } else {
                // 普通链接 `[label](url)`（要求 label 非空）
                guard token.labelRange.length > 0 else { continue }
                let tailLocal = NSRange(
                    location: token.midRange.location,
                    length: token.closeRange.location + token.closeRange.length - token.midRange.location
                )
                occupiedURLRanges.append(tailLocal)

                storage.addAttributes([
                    .foregroundColor: accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: accentColor.withAlphaComponent(0.45)
                ], range: labelGlobal)

                if shouldHideMarkers {
                    hideSyntax(openGlobal, in: storage)
                    hideSyntax(midGlobal, in: storage)
                    hideSyntax(destGlobal, in: storage)
                    hideSyntax(closeGlobal, in: storage)
                } else {
                    let smallURLFont = resolveCodeFont(name: config.codeFontName, size: max(11, round(blockFontSize * 0.85)))
                    storage.addAttribute(.foregroundColor, value: syntaxColor, range: openGlobal)
                    storage.addAttribute(.foregroundColor, value: syntaxColor, range: midGlobal)
                    if destGlobal.length > 0 {
                        storage.addAttributes([
                            .foregroundColor: syntaxColor,
                            .font: smallURLFont
                        ], range: destGlobal)
                    }
                    storage.addAttribute(.foregroundColor, value: syntaxColor, range: closeGlobal)
                }
            }
        }

        // 若当前行含图片且处于所见即所得模式，挂载 `BenImageLayoutSpec` 供 `NSLayoutManagerDelegate` 撑开真实图片高度并绘制
        if config.mode == .wysiwyg, !renderedImages.isEmpty {
            let lineFullGlobal = NSRange(location: lineGlobalLocation, length: nsLine.length)
            let isStandalone = Self.isStandaloneImageSubline(nsSub, imageRanges: imageFullRangesInSub) && subRangeInLine.location == 0
            if !isStandalone && shouldHideMarkers {
                // 行内图文混排时，展示轻量图片标签文字（如 `[🖼 alt]`），并在行末下方渲染图片预览
                for (idx, imgRangeLocal) in imageFullRangesInSub.enumerated() where idx < renderedImages.count {
                    let item = renderedImages[idx]
                    let globalRange = NSRange(location: baseLoc + imgRangeLocal.location, length: imgRangeLocal.length)
                    // 保留前导 `!` 或简短提示，避免行内图文混排处完全无锚点
                    if globalRange.length >= 1 {
                        storage.removeAttribute(.benHiddenSyntax, range: NSRange(location: globalRange.location, length: 1))
                        storage.addAttributes([
                            .font: resolveProseFont(name: config.proseFontName, size: blockFontSize, weight: .medium),
                            .foregroundColor: accentColor
                        ], range: NSRange(location: globalRange.location, length: 1))
                    }
                    _ = item
                }
            }
            let spec = BenImageLayoutSpec(
                items: renderedImages,
                isStandaloneLine: isStandalone,
                isLineActive: isLineActive
            )
            storage.addAttribute(.benImageAttachment, value: spec, range: lineFullGlobal)
        }

        func isFreeForInlineFormatting(_ localRange: NSRange) -> Bool {
            isFreeOfCode(localRange) && !occupiedURLRanges.contains { NSIntersectionRange($0, localRange).length > 0 }
        }

        // Step 3：强调语法（按 *** / ___ -> ** / __ -> * / _ 优先级消费定界符，支持紧贴中文汉字与全角标点）
        var consumedDelimiters: [NSRange] = []

        func isDelimiterUnconsumed(_ r: NSRange) -> Bool {
            !consumedDelimiters.contains { NSIntersectionRange($0, r).length > 0 }
        }

        func styleDelimiter(_ localRange: NSRange) {
            let global = NSRange(location: baseLoc + localRange.location, length: localRange.length)
            if shouldHideMarkers {
                hideSyntax(global, in: storage)
            } else {
                storage.addAttribute(.foregroundColor, value: syntaxColor, range: global)
            }
        }

        // 3a. 粗斜体 ***text*** 与 ___text___
        let boldItalicPatterns = [
            #"(?<!\*)(\*{3})(?=\S)(.+?)(?<=\S)(\*{3})(?!\*)"#,
            #"(?<![\p{L}\p{N}_])(_{3})(?=\S)(.+?)(?<=\S)(_{3})(?![\p{L}\p{N}_])"#
        ]
        for pattern in boldItalicPatterns {
            for match in matches(pattern, in: sub) where match.numberOfRanges == 4 {
                let fullLocal = match.range(at: 0)
                let openLocal = match.range(at: 1)
                let bodyLocal = match.range(at: 2)
                let closeLocal = match.range(at: 3)
                guard isFreeForInlineFormatting(fullLocal),
                      isDelimiterUnconsumed(openLocal),
                      isDelimiterUnconsumed(closeLocal) else { continue }
                let bodyStr = nsSub.substring(with: bodyLocal)
                guard !bodyStr.allSatisfy({ $0 == "*" || $0 == "_" }) else { continue }

                consumedDelimiters.append(openLocal)
                consumedDelimiters.append(closeLocal)
                styleDelimiter(openLocal)
                styleDelimiter(closeLocal)

                let bodyGlobal = NSRange(location: baseLoc + bodyLocal.location, length: bodyLocal.length)
                applyInlineFontTraits(bold: true, italic: true, in: bodyGlobal, config: config, storage: storage)
            }
        }

        // 3b. 加粗 **text** 与 __text__（`*` 不设词边界限制，完美兼容 **关键词**：、**「AI」**、中文**加粗**中文）
        let boldPatterns = [
            #"(?<!\*)(\*{2})(?=\S)(.+?)(?<=\S)(\*{2})(?!\*)"#,
            #"(?<![\p{L}\p{N}_])(_{2})(?=\S)(.+?)(?<=\S)(_{2})(?![\p{L}\p{N}_])"#
        ]
        for pattern in boldPatterns {
            for match in matches(pattern, in: sub) where match.numberOfRanges == 4 {
                let fullLocal = match.range(at: 0)
                let openLocal = match.range(at: 1)
                let bodyLocal = match.range(at: 2)
                let closeLocal = match.range(at: 3)
                guard isFreeForInlineFormatting(fullLocal),
                      isDelimiterUnconsumed(openLocal),
                      isDelimiterUnconsumed(closeLocal) else { continue }
                let bodyStr = nsSub.substring(with: bodyLocal)
                guard !bodyStr.allSatisfy({ $0 == "*" || $0 == "_" }) else { continue }

                consumedDelimiters.append(openLocal)
                consumedDelimiters.append(closeLocal)
                styleDelimiter(openLocal)
                styleDelimiter(closeLocal)

                let bodyGlobal = NSRange(location: baseLoc + bodyLocal.location, length: bodyLocal.length)
                applyInlineFontTraits(bold: true, italic: false, in: bodyGlobal, config: config, storage: storage)
            }
        }

        // 3c. 斜体 *text* 与 _text_（`_` 严格要求词边界保护 snake_case；排除未消费相邻同符号）
        let italicSpecs: [(pattern: String, charCode: unichar)] = [
            (#"(\*)(?=[^\s*])(.+?)(?<=[^\s*])(\*)"#, 42),
            (#"(?<![\p{L}\p{N}_])(_)(?=[^\s_])(.+?)(?<=[^\s_])(_)(?![\p{L}\p{N}_])"#, 95)
        ]
        for spec in italicSpecs {
            for match in matches(spec.pattern, in: sub) where match.numberOfRanges == 4 {
                let fullLocal = match.range(at: 0)
                let openLocal = match.range(at: 1)
                let bodyLocal = match.range(at: 2)
                let closeLocal = match.range(at: 3)
                guard isFreeForInlineFormatting(fullLocal),
                      isDelimiterUnconsumed(openLocal),
                      isDelimiterUnconsumed(closeLocal),
                      !hasAdjacentUnconsumedChar(spec.charCode, around: openLocal, in: nsSub, consumed: consumedDelimiters),
                      !hasAdjacentUnconsumedChar(spec.charCode, around: closeLocal, in: nsSub, consumed: consumedDelimiters) else {
                    continue
                }

                consumedDelimiters.append(openLocal)
                consumedDelimiters.append(closeLocal)
                styleDelimiter(openLocal)
                styleDelimiter(closeLocal)

                let bodyGlobal = NSRange(location: baseLoc + bodyLocal.location, length: bodyLocal.length)
                applyInlineFontTraits(bold: false, italic: true, in: bodyGlobal, config: config, storage: storage)
            }
        }

        // Step 4：删除线 ~~text~~
        for match in matches(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#, in: sub) where match.numberOfRanges == 4 {
            let fullLocal = match.range(at: 0)
            guard isFreeForInlineFormatting(fullLocal) else { continue }
            let openLocal = match.range(at: 1)
            let bodyLocal = match.range(at: 2)
            let closeLocal = match.range(at: 3)

            styleDelimiter(openLocal)
            styleDelimiter(closeLocal)

            let bodyGlobal = NSRange(location: baseLoc + bodyLocal.location, length: bodyLocal.length)
            storage.enumerateAttribute(.benHiddenSyntax, in: bodyGlobal, options: []) { hidden, subRange, _ in
                guard hidden == nil else { return }
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor
                ], range: subRange)
            }
        }

        // Step 5：高亮 ==text==
        for match in matches(#"(==)(?=\S)(.+?)(?<=\S)(==)"#, in: sub) where match.numberOfRanges == 4 {
            let fullLocal = match.range(at: 0)
            guard isFreeForInlineFormatting(fullLocal) else { continue }
            let openLocal = match.range(at: 1)
            let bodyLocal = match.range(at: 2)
            let closeLocal = match.range(at: 3)

            styleDelimiter(openLocal)
            styleDelimiter(closeLocal)

            let bodyGlobal = NSRange(location: baseLoc + bodyLocal.location, length: bodyLocal.length)
            storage.enumerateAttribute(.benHiddenSyntax, in: bodyGlobal, options: []) { hidden, subRange, _ in
                guard hidden == nil else { return }
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: subRange)
            }
        }
    }

    private static func hasAdjacentUnconsumedChar(
        _ charCode: unichar,
        around range: NSRange,
        in ns: NSString,
        consumed: [NSRange]
    ) -> Bool {
        if range.location > 0 {
            let leftIdx = range.location - 1
            if ns.character(at: leftIdx) == charCode,
               !consumed.contains(where: { NSLocationInRange(leftIdx, $0) }) {
                return true
            }
        }
        let rightIdx = range.location + range.length
        if rightIdx < ns.length {
            if ns.character(at: rightIdx) == charCode,
               !consumed.contains(where: { NSLocationInRange(rightIdx, $0) }) {
                return true
            }
        }
        return false
    }

    private static func hideSyntax(_ range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: hiddenSyntaxFont,
            .foregroundColor: NSColor.clear,
            .benHiddenSyntax: true
        ], range: range)
    }

    /// 精确叠加加粗与斜体（跳过已隐藏的内部定界符，完美支持中文苹方/宋楷加粗与中文仿斜体）。
    private static func applyInlineFontTraits(
        bold: Bool,
        italic: Bool,
        in range: NSRange,
        config: StyleConfig,
        storage: NSTextStorage
    ) {
        guard range.length > 0 else { return }
        let nsStorage = storage.string as NSString

        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            guard attrs[.benHiddenSyntax] == nil,
                  let currentFont = attrs[.font] as? NSFont else { return }

            let size = currentFont.pointSize
            let targetBold = bold || isBoldFont(currentFont)
            let existingItalic = currentFont.fontDescriptor.symbolicTraits.contains(.italic)
                || ((attrs[.obliqueness] as? CGFloat) ?? 0) > 0
            let targetItalic = italic || existingItalic

            var resolvedFont: NSFont
            if config.mode == .wysiwyg {
                resolvedFont = resolveProseFont(
                    name: config.proseFontName,
                    size: size,
                    weight: targetBold ? .bold : .regular
                )
            } else {
                resolvedFont = resolveCodeFont(
                    name: config.codeFontName,
                    size: size,
                    weight: targetBold ? .bold : .regular
                )
            }

            if targetBold && !isBoldFont(resolvedFont) {
                resolvedFont = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .boldFontMask)
            }

            if targetItalic {
                let substring = nsStorage.substring(with: subrange)
                let containsNonASCII = substring.unicodeScalars.contains { $0.value >= 0x2E80 }
                if !containsNonASCII {
                    let italicCandidate = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .italicFontMask)
                    if italicCandidate.fontDescriptor.symbolicTraits.contains(.italic) {
                        resolvedFont = italicCandidate
                        storage.addAttribute(.font, value: resolvedFont, range: subrange)
                        return
                    }
                }
                // 中文字体或无原生 Italic 字重的字体使用轻量倾斜度，保证中文斜体清晰生效
                storage.addAttributes([
                    .font: resolvedFont,
                    .obliqueness: CGFloat(0.16)
                ], range: subrange)
            } else {
                storage.addAttribute(.font, value: resolvedFont, range: subrange)
            }
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
        paragraphRange: NSRange,
        isLineActive: Bool,
        style: TableLineStyle,
        config: StyleConfig,
        monoFont: NSFont,
        syntaxColor: NSColor,
        accentColor: NSColor,
        storage: NSTextStorage
    ) {
        let tablePara = NSMutableParagraphStyle()
        tablePara.lineSpacing = max(3, config.lineSpacing * 0.8)
        tablePara.paragraphSpacing = 2
        storage.addAttribute(.paragraphStyle, value: tablePara, range: paragraphRange)

        if style.isHeader {
            let boldMono = resolveCodeFont(name: config.codeFontName, size: monoFont.pointSize, weight: .bold)
            storage.addAttributes([
                .font: boldMono,
                .backgroundColor: accentColor.withAlphaComponent(0.08)
            ], range: lineRange)
        } else if style.isSeparator {
            storage.addAttributes([
                .font: monoFont,
                .foregroundColor: syntaxColor,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.05)
            ], range: lineRange)
            return
        } else {
            storage.addAttributes([
                .font: monoFont,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.05)
            ], range: lineRange)
        }

        let nsLine = line as NSString
        for idx in 0..<nsLine.length where nsLine.character(at: idx) == 124 {
            storage.addAttribute(.foregroundColor, value: syntaxColor, range: NSRange(location: location + idx, length: 1))
        }

        styleInlineElements(
            in: line,
            subRangeInLine: NSRange(location: 0, length: lineRange.length),
            lineGlobalLocation: location,
            isLineActive: isLineActive,
            blockFontSize: monoFont.pointSize,
            config: config,
            syntaxColor: syntaxColor,
            accentColor: accentColor,
            storage: storage
        )
    }

    private static func detectTables(in lines: [String], codeStates: [CodeLineState]) -> [Int: TableLineStyle] {
        var result: [Int: TableLineStyle] = [:]
        guard lines.count >= 2 else { return result }
        var index = 0
        while index < lines.count - 1 {
            guard codeStates[index] == .none, codeStates[index + 1] == .none,
                  isTableHeader(lines[index], separator: lines[index + 1]) else {
                index += 1
                continue
            }
            result[index] = TableLineStyle(isHeader: true, isSeparator: false)
            result[index + 1] = TableLineStyle(isHeader: false, isSeparator: true)
            var row = index + 2
            while row < lines.count,
                  codeStates[row] == .none,
                  !lines[row].trimmingCharacters(in: .whitespaces).isEmpty,
                  lines[row].contains("|") {
                result[row] = TableLineStyle(isHeader: false, isSeparator: false)
                row += 1
            }
            index = row
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

    // MARK: - 精确括号深度图片/链接扫描器（完美支持 `![](...)` 空 alt、带空格本地路径、括号平衡与 `<...>` 包裹路径）

    private struct LinkOrImageToken {
        let isImage: Bool
        let fullRange: NSRange
        let openRange: NSRange
        let labelRange: NSRange
        let midRange: NSRange
        let destRange: NSRange
        let closeRange: NSRange
    }

    private static func scanMarkdownLinksAndImages(in ns: NSString) -> [LinkOrImageToken] {
        var tokens: [LinkOrImageToken] = []
        let length = ns.length
        var idx = 0

        while idx < length {
            let ch = ns.character(at: idx)
            let isImage: Bool
            let openStart: Int
            let bracketStart: Int

            if ch == 33, idx + 1 < length, ns.character(at: idx + 1) == 91 { // `![`
                // 排除 `![[`（已由 WikiLink 分支处理）
                if idx + 2 < length, ns.character(at: idx + 2) == 91 {
                    idx += 3
                    continue
                }
                isImage = true
                openStart = idx
                bracketStart = idx + 1
            } else if ch == 91 { // `[`
                isImage = false
                openStart = idx
                bracketStart = idx
            } else {
                idx += 1
                continue
            }

            // 扫描匹配的 `]`（允许内部转义 `\]`，不允许未配对嵌套 `[`）
            var scan = bracketStart + 1
            var closeBracket: Int?
            var bracketDepth = 1
            while scan < length {
                let c = ns.character(at: scan)
                if c == 92 { // `\` 转义
                    scan += 2
                    continue
                }
                if c == 91 {
                    bracketDepth += 1
                } else if c == 93 {
                    bracketDepth -= 1
                    if bracketDepth == 0 {
                        closeBracket = scan
                        break
                    }
                }
                scan += 1
            }

            guard let labelClose = closeBracket,
                  labelClose + 1 < length,
                  ns.character(at: labelClose + 1) == 40 else { // 紧跟 `(`
                idx = bracketStart + 1
                continue
            }

            let destStart = labelClose + 2
            var destScan = destStart
            var closeParen: Int?

            // 跳过前导空格后若以 `<` 开头，按 CommonMark `<...>` 目标扫描（内部允许空格与未配对括号）
            var trimmedDestStart = destStart
            while trimmedDestStart < length && (ns.character(at: trimmedDestStart) == 32 || ns.character(at: trimmedDestStart) == 9) {
                trimmedDestStart += 1
            }

            if trimmedDestStart < length && ns.character(at: trimmedDestStart) == 60 { // `<`
                var angleScan = trimmedDestStart + 1
                var foundCloseAngle: Int?
                while angleScan < length {
                    let c = ns.character(at: angleScan)
                    if c == 92 {
                        angleScan += 2
                        continue
                    }
                    if c == 62 { // `>`
                        foundCloseAngle = angleScan
                        break
                    }
                    angleScan += 1
                }
                if let closeAngle = foundCloseAngle {
                    var afterAngle = closeAngle + 1
                    while afterAngle < length && ns.character(at: afterAngle) != 41 {
                        if ns.character(at: afterAngle) == 92 {
                            afterAngle += 2
                            continue
                        }
                        afterAngle += 1
                    }
                    if afterAngle < length && ns.character(at: afterAngle) == 41 {
                        closeParen = afterAngle
                    }
                }
            } else {
                var parenDepth = 1
                var inQuotes: unichar = 0
                while destScan < length {
                    let c = ns.character(at: destScan)
                    if c == 92 {
                        destScan += 2
                        continue
                    }
                    if inQuotes != 0 {
                        if c == inQuotes { inQuotes = 0 }
                        destScan += 1
                        continue
                    }
                    if c == 34 || c == 39 { // `"` or `'`
                        inQuotes = c
                        destScan += 1
                        continue
                    }
                    if c == 40 { // `(`
                        parenDepth += 1
                    } else if c == 41 { // `)`
                        parenDepth -= 1
                        if parenDepth == 0 {
                            closeParen = destScan
                            break
                        }
                    } else if !isImage && (c == 32 || c == 9) && parenDepth == 1 {
                        // 普通链接 URL 后若出现空格，仅当后面是 `"title"` / `'title'` 或直接跟 `)` 时合法
                        var peek = destScan + 1
                        while peek < length && (ns.character(at: peek) == 32 || ns.character(at: peek) == 9) {
                            peek += 1
                        }
                        if peek < length {
                            let nextC = ns.character(at: peek)
                            if nextC != 34 && nextC != 39 && nextC != 41 {
                                break
                            }
                        }
                    }
                    destScan += 1
                }
            }

            guard let finalCloseParen = closeParen, finalCloseParen > destStart || isImage else {
                idx = bracketStart + 1
                continue
            }

            let destRange = NSRange(location: destStart, length: finalCloseParen - destStart)
            // 目标地址不能为空
            guard !ns.substring(with: destRange).trimmingCharacters(in: .whitespaces).isEmpty else {
                idx = finalCloseParen + 1
                continue
            }

            let token = LinkOrImageToken(
                isImage: isImage,
                fullRange: NSRange(location: openStart, length: finalCloseParen - openStart + 1),
                openRange: NSRange(location: openStart, length: isImage ? 2 : 1),
                labelRange: NSRange(location: bracketStart + 1, length: labelClose - bracketStart - 1),
                midRange: NSRange(location: labelClose, length: 2),
                destRange: destRange,
                closeRange: NSRange(location: finalCloseParen, length: 1)
            )
            tokens.append(token)
            idx = finalCloseParen + 1
        }

        return tokens
    }

    private static func parseDestinationAndTitle(_ rawDest: String) -> (source: String, title: String?) {
        let trimmed = rawDest.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<"), let closeAngle = trimmed.firstIndex(of: ">") {
            let src = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeAngle])
            let rest = String(trimmed[trimmed.index(after: closeAngle)...]).trimmingCharacters(in: .whitespaces)
            return (src, stripQuotes(rest))
        }

        // 检查末尾可选 `"title"` 或 `'title'`
        if let quoteMatch = firstMatch(#"^(.*?)[ \t]+("([^"]*)"|'([^']*)')$"#, in: trimmed) {
            let ns = trimmed as NSString
            let src = ns.substring(with: quoteMatch.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let titleRange = quoteMatch.range(at: 3).location != NSNotFound ? quoteMatch.range(at: 3) : quoteMatch.range(at: 4)
            let title = titleRange.location != NSNotFound ? ns.substring(with: titleRange) : nil
            if !src.isEmpty {
                return (src, title)
            }
        }
        return (trimmed, nil)
    }

    private static func stripQuotes(_ text: String) -> String? {
        guard text.count >= 2 else { return nil }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return nil
    }

    private static func isStandaloneImageSubline(_ nsSub: NSString, imageRanges: [NSRange]) -> Bool {
        guard !imageRanges.isEmpty else { return false }
        let mutable = NSMutableString(string: nsSub as String)
        for range in imageRanges.sorted(by: { $0.location > $1.location }) {
            if range.location + range.length <= mutable.length {
                mutable.deleteCharacters(in: range)
            }
        }
        return (mutable as String).trimmingCharacters(in: .whitespaces).isEmpty
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
