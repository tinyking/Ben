import SwiftUI
import AppKit
import CoreText

/// 统一承载「所见即所得」与「纯源码」两种模式的编辑器视图。
struct MarkdownEditorView: View {
    @Environment(AppState.self) private var app
    @AppStorage("proseFontName") private var proseFontName = "System"
    @AppStorage("editorFontName") private var codeFontName = "SFMono-Regular"
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("editorLineSpacing") private var lineSpacing = 5.0
    @AppStorage("comfortableLineWidth") private var comfortableLineWidth = true

    var body: some View {
        VStack(spacing: 0) {
            if app.editor.mode == .wysiwyg {
                formattingToolbar
            }

            MarkdownCanvasRepresentable(
                app: app,
                text: Binding(
                    get: { app.editor.text },
                    set: { app.editor.updateTextFromUser($0) }
                ),
                frontmatter: app.editor.frontmatter,
                isFrontmatterExpanded: app.editor.isFrontmatterExpanded,
                styleConfig: MarkdownStyler.StyleConfig(
                    mode: app.editor.mode,
                    proseFontName: proseFontName,
                    codeFontName: codeFontName,
                    fontSize: CGFloat(fontSize),
                    lineSpacing: CGFloat(lineSpacing),
                    noteURL: app.editor.currentNote,
                    vaultURL: app.vaultStore.vaultURL
                ),
                comfortableLineWidth: comfortableLineWidth,
                scrollRequest: app.editor.scrollRequest,
                formatCommand: app.editor.formatCommand,
                onCursorPosition: { line, column in
                    app.editor.cursorLine = line
                    app.editor.cursorColumn = column
                }
            )
            .padding(.top, 12)
            .background(Color.white)
            .overlay(alignment: .top) {
                if let line = app.editor.highlightedLine, !app.editor.highlightedQuery.isEmpty {
                    matchBanner(line: line)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .onDisappear {
            app.editor.highlightedLine = nil
            app.editor.highlightedQuery = ""
        }
    }

    // MARK: - 顶部轻量格式栏

    private var formattingToolbar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("一级标题 (⌘⌥1)") { app.editor.applyFormat(.heading(1)) }
                Button("二级标题 (⌘⌥2)") { app.editor.applyFormat(.heading(2)) }
                Button("三级标题 (⌘⌥3)") { app.editor.applyFormat(.heading(3)) }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "number")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("标题层级")

            Divider().frame(height: 15).padding(.horizontal, 4)

            FormatToolbarButton(symbol: "bold", help: "加粗 (⌘B)") {
                app.editor.applyFormat(.bold)
            }
            FormatToolbarButton(symbol: "italic", help: "斜体 (⌘I)") {
                app.editor.applyFormat(.italic)
            }
            FormatToolbarButton(symbol: "strikethrough", help: "删除线 (⌘⇧U)") {
                app.editor.applyFormat(.strikethrough)
            }
            FormatToolbarButton(symbol: "highlighter", help: "高亮标记 (⌘⇧H)") {
                app.editor.applyFormat(.highlight)
            }
            FormatToolbarButton(symbol: "chevron.left.forwardslash.chevron.right", help: "行内代码 (⌘⇧K)") {
                app.editor.applyFormat(.inlineCode)
            }
            FormatToolbarButton(symbol: "link", help: "插入链接 (⌘K)") {
                app.editor.applyFormat(.link)
            }

            Divider().frame(height: 15).padding(.horizontal, 4)

            FormatToolbarButton(symbol: "list.bullet", help: "无序列表 (⌘⇧L)") {
                app.editor.applyFormat(.bulletList)
            }
            FormatToolbarButton(symbol: "list.number", help: "有序列表") {
                app.editor.applyFormat(.numberedList)
            }
            FormatToolbarButton(symbol: "checklist", help: "待办清单 (⌘⇧T)") {
                app.editor.applyFormat(.todoList)
            }
            FormatToolbarButton(symbol: "text.quote", help: "引用") {
                app.editor.applyFormat(.blockquote)
            }
            FormatToolbarButton(symbol: "minus", help: "分割线") {
                app.editor.applyFormat(.divider)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1)
        }
    }

    // MARK: - 搜索跳转提示横幅

    private func matchBanner(line: Int) -> some View {
        let lines = app.editor.text.components(separatedBy: "\n")
        let lineText = lines.indices.contains(line - 1) ? lines[line - 1] : ""
        let query = app.editor.highlightedQuery
        let physicalLine = line + app.editor.frontmatterLineOffset

        return HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .foregroundStyle(Color.accentColor)
            Text("第 \(physicalLine) 行")
                .fontWeight(.semibold)
            highlighted(lineText.trimmingCharacters(in: .whitespaces), query: query)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                app.editor.highlightedLine = nil
                app.editor.highlightedQuery = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("关闭定位提示")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private func highlighted(_ line: String, query: String) -> Text {
        guard !query.isEmpty,
              let range = line.range(of: query, options: [.caseInsensitive]) else {
            return Text(line)
        }
        return Text(line[..<range.lowerBound])
            + Text(line[range]).bold().foregroundStyle(Color.accentColor)
            + Text(line[range.upperBound...])
    }
}

private struct FormatToolbarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 25)
                .background(
                    isHovered ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// 当前挂载中的编辑器视图注册表。
/// PDF 导出复用这份已排版好的视图，而不是从 Markdown 源码重新解析，
/// 从而保证导出的效果与用户看到的所见即所得完全一致。
enum BenEditorViewRegistry {
    private static weak var currentView: NSTextView?

    static var current: NSTextView? { currentView }

    static func register(_ view: NSTextView) {
        if currentView !== view { currentView = view }
    }

    static func unregister(_ view: NSTextView) {
        if currentView === view { currentView = nil }
    }
}

// MARK: - 原生 AppKit NSTextView 封装（支持中文拼音输入法保护、Undo/Redo、列表自动续行、待办点击切换、满宽分割线与块装饰绘制）

private struct MarkdownCanvasRepresentable: NSViewRepresentable {
    let app: AppState
    @Binding var text: String
    let frontmatter: FrontmatterDocument?
    let isFrontmatterExpanded: Bool
    let styleConfig: MarkdownStyler.StyleConfig
    let comfortableLineWidth: Bool
    let scrollRequest: EditorState.ScrollRequest?
    let formatCommand: EditorState.FormatCommand?
    let onCursorPosition: (Int, Int) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        // 所见即所得与源码模式共用此滚动容器：底部留 20pt 空白，
        // 避免正文最后一行滚到底时紧贴状态栏横线。
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        ScrollbarStyleProbe.configureOverlayScrollbars(scrollView)

        let textView = BenEditorTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.appearance = NSAppearance(named: .aqua)
        textView.insertionPointColor = .controlAccentColor
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.comfortableLineWidth = comfortableLineWidth
        textView.onFocusChanged = { [weak coordinator = context.coordinator] in
            coordinator?.refreshActiveLineIfNeeded(force: true)
        }
        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        textView.string = text
        textView.updateHeaderAccessory(app: app, hasFrontmatter: frontmatter != nil)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.currentConfig = styleConfig
        context.coordinator.installImageReloadObserver()
        context.coordinator.applyStylesNow()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? BenEditorTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.onCursorPosition = onCursorPosition

        if textView.comfortableLineWidth != comfortableLineWidth {
            textView.comfortableLineWidth = comfortableLineWidth
        }
        textView.updateHeaderAccessory(app: app, hasFrontmatter: frontmatter != nil)
        textView.updateReadableInsets()

        var needsRestyle = false
        if coordinator.currentConfig != styleConfig {
            coordinator.currentConfig = styleConfig
            needsRestyle = true
        }

        // 中文输入法正在组词（markedText）时，绝不外部覆盖 string 或重刷属性，避免打断拼音候选框
        if !textView.hasMarkedText(), textView.string != text {
            let previousRanges = textView.selectedRanges
            coordinator.isApplyingExternalText = true
            textView.string = text
            let maxLen = (text as NSString).length
            if let first = previousRanges.first?.rangeValue {
                let clamped = NSRange(location: min(first.location, maxLen), length: 0)
                textView.setSelectedRange(clamped)
            }
            coordinator.isApplyingExternalText = false
            needsRestyle = true
        }

        if needsRestyle && !textView.hasMarkedText() {
            coordinator.applyStylesNow()
        }

        if let command = formatCommand, coordinator.lastFormatToken != command.token {
            coordinator.lastFormatToken = command.token
            DispatchQueue.main.async {
                coordinator.performFormat(command.action)
            }
        }

        if let request = scrollRequest, coordinator.lastScrollToken != request.token {
            coordinator.lastScrollToken = request.token
            DispatchQueue.main.async {
                coordinator.performScroll(request)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, config: styleConfig, onCursorPosition: onCursorPosition)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var text: Binding<String>
        var currentConfig: MarkdownStyler.StyleConfig
        var onCursorPosition: (Int, Int) -> Void
        weak var textView: BenEditorTextView?
        var lastScrollToken: UUID?
        var lastFormatToken: UUID?
        var isApplyingExternalText = false
        private var isApplyingStyles = false
        private var lastActiveLineSignature: NSRange = NSRange(location: NSNotFound, length: 0)
        private var highlightWorkItem: DispatchWorkItem?
        private var imageLoadObserver: NSObjectProtocol?

        init(
            text: Binding<String>,
            config: MarkdownStyler.StyleConfig,
            onCursorPosition: @escaping (Int, Int) -> Void
        ) {
            self.text = text
            self.currentConfig = config
            self.onCursorPosition = onCursorPosition
        }

        deinit {
            if let imageLoadObserver {
                NotificationCenter.default.removeObserver(imageLoadObserver)
            }
        }

        func installImageReloadObserver() {
            guard imageLoadObserver == nil else { return }
            imageLoadObserver = NotificationCenter.default.addObserver(
                forName: .benMarkdownImageDidLoad,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyStylesNow(forceInvalidateLayout: true)
            }
        }

        // MARK: - NSLayoutManagerDelegate

        /// 非光标行的无序列表标记 `-` / `*` / `+` 用圆点 `•` 的字形绘制。
        /// 仅替换字形，不改字符与 characterIndexes，因此光标位置、选中范围与复制出的文本完全不变。
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }

            // 先快速判定本字形范围是否含列表标记，绝大多数行直接返回 0 走系统默认字形。
            var needsReplacement = false
            for offset in 0..<glyphRange.length {
                let charIndex = characterIndexes[offset]
                if charIndex < storage.length,
                   storage.attribute(.benBulletGlyph, at: charIndex, effectiveRange: nil) != nil {
                    needsReplacement = true
                    break
                }
            }
            guard needsReplacement else { return 0 }

            var bulletGlyph = CGGlyph(0)
            let glyphFound = Array("•".utf16).withUnsafeBufferPointer { chars in
                CTFontGetGlyphsForCharacters(font as CTFont, chars.baseAddress!, &bulletGlyph, 1)
            }
            guard glyphFound else { return 0 }

            var replaced = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
            for offset in 0..<glyphRange.length {
                let charIndex = characterIndexes[offset]
                if charIndex < storage.length,
                   storage.attribute(.benBulletGlyph, at: charIndex, effectiveRange: nil) != nil {
                    replaced[offset] = bulletGlyph
                }
            }
            replaced.withUnsafeBufferPointer { buffer in
                layoutManager.setGlyphs(
                    buffer.baseAddress!,
                    properties: props,
                    characterIndexes: characterIndexes,
                    font: font,
                    forGlyphRange: glyphRange
                )
            }
            return glyphRange.length
        }

        /// 为含图片的段落最后一个行片段自动撑开真实图片渲染高度。
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard let storage = layoutManager.textStorage, storage.length > 0 else { return false }
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.location < storage.length,
                  let spec = storage.attribute(.benImageAttachment, at: charRange.location, effectiveRange: nil) as? BenImageLayoutSpec else {
                return false
            }

            let ns = storage.string as NSString
            let paraRange = ns.lineRange(for: NSRange(location: charRange.location, length: 0))
            let hasNewline = paraRange.length > 0 && ns.character(at: paraRange.location + paraRange.length - 1) == 10
            let contentEnd = paraRange.location + paraRange.length - (hasNewline ? 1 : 0)

            // 若当前行因超长 URL 折成多行，仅在该段落最后一个视觉行片段下方追加图片高度
            guard charRange.location + charRange.length >= contentEnd else { return false }

            let availableWidth = max(120, textContainer.containerSize.width)
            let imageBlockHeight = spec.totalBlockHeight(availableWidth: availableWidth)
            guard imageBlockHeight > 0 else { return false }

            if spec.isStandaloneLine && !spec.isLineActive {
                lineFragmentRect.pointee.size.height = imageBlockHeight
                lineFragmentUsedRect.pointee.size.height = imageBlockHeight
                lineFragmentUsedRect.pointee.size.width = availableWidth
                baselineOffset.pointee = 12
            } else {
                let textHeight = lineFragmentRect.pointee.size.height
                lineFragmentRect.pointee.size.height = textHeight + imageBlockHeight
                lineFragmentUsedRect.pointee.size.height = textHeight + imageBlockHeight
                lineFragmentUsedRect.pointee.size.width = max(lineFragmentUsedRect.pointee.size.width, availableWidth)
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            if !textView.hasMarkedText() {
                text.wrappedValue = textView.string
                scheduleHighlight()
            }
            updateCursorPosition()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingStyles, let textView, !textView.hasMarkedText() else { return }
            updateCursorPosition()
            // 仅当活动行真的改变时才安排重排，且复用 textDidChange 的同一条防抖任务。
            // 原先这里直接同步 applyStylesNow，与 35ms 后的 textDidChange 重排叠加，
            // 一次跨行输入会全篇重排两次，在 418 行 / 63 条分割线的文档上表现为可见闪动。
            let signature = computeActiveLineSignature(in: textView)
            if signature != lastActiveLineSignature {
                lastActiveLineSignature = signature
                scheduleHighlight()
            }
        }

        func refreshActiveLineIfNeeded(force: Bool) {
            guard let textView, !textView.hasMarkedText() else { return }
            let signature = computeActiveLineSignature(in: textView)
            if force || signature != lastActiveLineSignature {
                lastActiveLineSignature = signature
                applyStylesNow()
            }
        }

        private func computeActiveLineSignature(in textView: NSTextView) -> NSRange {
            guard textView.window?.firstResponder === textView else {
                return NSRange(location: NSNotFound, length: 0)
            }
            let ns = textView.string as NSString
            guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
            let sel = textView.selectedRange()
            let clampedLoc = min(max(0, sel.location), ns.length)
            let clampedLen = min(max(0, sel.length), ns.length - clampedLoc)
            return ns.lineRange(for: NSRange(location: clampedLoc, length: clampedLen))
        }

        /// 拦截回车键：支持无序列表、递增有序列表、待办清单与引用块的自动续行或空行退出。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
                return handleSmartReturn(in: textView)
            }
            return false
        }

        private func handleSmartReturn(in textView: NSTextView) -> Bool {
            let sel = textView.selectedRange()
            guard sel.length == 0 else { return false }
            let nsString = textView.string as NSString
            guard sel.location <= nsString.length else { return false }

            let lineRange = nsString.lineRange(for: NSRange(location: sel.location, length: 0))
            let lineBeforeCaretRange = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
            let typedLine = nsString.substring(with: lineBeforeCaretRange)

            // 匹配待办：`- [ ] ` / `- [x] `
            if let todoRegex = try? NSRegularExpression(pattern: #"^([ \t]*[-*+][ \t]+)\[[ xX]\][ \t]+(.*)$"#),
               let match = todoRegex.firstMatch(in: typedLine, range: NSRange(location: 0, length: (typedLine as NSString).length)) {
                let prefix = (typedLine as NSString).substring(with: match.range(at: 1))
                let content = (typedLine as NSString).substring(with: match.range(at: 2))
                if content.trimmingCharacters(in: .whitespaces).isEmpty {
                    replaceWithUndo(in: textView, range: lineBeforeCaretRange, replacement: "")
                } else {
                    replaceWithUndo(in: textView, range: sel, replacement: "\n\(prefix)[ ] ")
                }
                return true
            }

            // 匹配普通无序列表或有序列表（严格要求符号后紧跟空格）
            if let listRegex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+]|[0-9]+[.)])[ \t]+(.*)$"#),
               let match = listRegex.firstMatch(in: typedLine, range: NSRange(location: 0, length: (typedLine as NSString).length)) {
                let indent = (typedLine as NSString).substring(with: match.range(at: 1))
                let marker = (typedLine as NSString).substring(with: match.range(at: 2))
                let content = (typedLine as NSString).substring(with: match.range(at: 3))
                if content.trimmingCharacters(in: .whitespaces).isEmpty {
                    replaceWithUndo(in: textView, range: lineBeforeCaretRange, replacement: "")
                } else {
                    let nextMarker = Self.incrementListMarker(marker)
                    replaceWithUndo(in: textView, range: sel, replacement: "\n\(indent)\(nextMarker) ")
                }
                return true
            }

            // 匹配引用 `> `
            if let quoteRegex = try? NSRegularExpression(pattern: #"^([ \t]*>+[ \t]*)(.*)$"#),
               let match = quoteRegex.firstMatch(in: typedLine, range: NSRange(location: 0, length: (typedLine as NSString).length)) {
                let prefix = (typedLine as NSString).substring(with: match.range(at: 1))
                let content = (typedLine as NSString).substring(with: match.range(at: 2))
                if content.trimmingCharacters(in: .whitespaces).isEmpty {
                    replaceWithUndo(in: textView, range: lineBeforeCaretRange, replacement: "")
                } else {
                    replaceWithUndo(in: textView, range: sel, replacement: "\n\(prefix)")
                }
                return true
            }

            return false
        }

        private static func incrementListMarker(_ marker: String) -> String {
            guard let match = marker.range(of: #"^[0-9]+"#, options: .regularExpression),
                  let num = Int(marker[match]) else { return marker }
            return "\(num + 1)\(marker[match.upperBound...])"
        }

        // MARK: - 格式化指令（全部接入原生 Undo 栈，支持双向切换）

        func performFormat(_ action: MarkdownFormatAction) {
            guard let textView else { return }
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
            switch action {
            case .bold: toggleInlineWrapper("**", in: textView)
            case .italic: toggleInlineWrapper("*", in: textView)
            case .strikethrough: toggleInlineWrapper("~~", in: textView)
            case .highlight: toggleInlineWrapper("==", in: textView)
            case .inlineCode: toggleInlineWrapper("`", in: textView)
            case .link: insertMarkdownLink(in: textView)
            case .heading(let level): toggleHeading(level: level, in: textView)
            case .bulletList: toggleLinePrefix("- ", in: textView)
            case .numberedList: toggleLinePrefix("1. ", in: textView)
            case .todoList: toggleLinePrefix("- [ ] ", in: textView)
            case .toggleTodo: toggleCurrentLineTodoState(in: textView)
            case .blockquote: toggleLinePrefix("> ", in: textView)
            case .divider: insertHorizontalDivider(in: textView)
            }
        }

        private func toggleInlineWrapper(_ marker: String, in textView: NSTextView) {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let mLen = (marker as NSString).length

            if sel.location >= mLen,
               sel.location + sel.length + mLen <= ns.length,
               ns.substring(with: NSRange(location: sel.location - mLen, length: mLen)) == marker,
               ns.substring(with: NSRange(location: sel.location + sel.length, length: mLen)) == marker {
                let outer = NSRange(location: sel.location - mLen, length: sel.length + mLen * 2)
                let inner = ns.substring(with: sel)
                replaceWithUndo(in: textView, range: outer, replacement: inner)
                textView.setSelectedRange(NSRange(location: sel.location - mLen, length: sel.length))
                return
            }

            if sel.length >= mLen * 2 {
                let selectedText = ns.substring(with: sel)
                if selectedText.hasPrefix(marker) && selectedText.hasSuffix(marker) {
                    let unwrapped = String(selectedText.dropFirst(marker.count).dropLast(marker.count))
                    replaceWithUndo(in: textView, range: sel, replacement: unwrapped)
                    textView.setSelectedRange(NSRange(location: sel.location, length: (unwrapped as NSString).length))
                    return
                }
            }

            let selectedText = ns.substring(with: sel)
            let wrapped = marker + selectedText + marker
            replaceWithUndo(in: textView, range: sel, replacement: wrapped)
            textView.setSelectedRange(NSRange(location: sel.location + mLen, length: sel.length))
        }

        private func insertMarkdownLink(in textView: NSTextView) {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let label = sel.length > 0 ? ns.substring(with: sel) : "链接文字"
            let urlPlaceholder = "https://"
            let snippet = "[\(label)](\(urlPlaceholder))"
            replaceWithUndo(in: textView, range: sel, replacement: snippet)
            let urlOffset = sel.location + 1 + (label as NSString).length + 2
            textView.setSelectedRange(NSRange(location: urlOffset, length: (urlPlaceholder as NSString).length))
        }

        private func toggleHeading(level: Int, in textView: NSTextView) {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let hasNewline = lineRange.length > 0 && ns.substring(with: NSRange(location: lineRange.location + lineRange.length - 1, length: 1)) == "\n"
            let contentRange = NSRange(location: lineRange.location, length: lineRange.length - (hasNewline ? 1 : 0))
            let line = ns.substring(with: contentRange)
            let hashes = String(repeating: "#", count: level) + " "

            if let regex = try? NSRegularExpression(pattern: #"^(#{1,6}\s+)"#),
               let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let existing = (line as NSString).substring(with: match.range(at: 1))
                let stripped = (line as NSString).replacingCharacters(in: match.range(at: 1), with: "")
                let updated = existing == hashes ? stripped : (hashes + stripped)
                replaceWithUndo(in: textView, range: contentRange, replacement: updated)
            } else {
                replaceWithUndo(in: textView, range: NSRange(location: contentRange.location, length: 0), replacement: hashes)
            }
        }

        private func toggleLinePrefix(_ prefix: String, in textView: NSTextView) {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let hasNewline = lineRange.length > 0 && ns.substring(with: NSRange(location: lineRange.location + lineRange.length - 1, length: 1)) == "\n"
            let contentRange = NSRange(location: lineRange.location, length: lineRange.length - (hasNewline ? 1 : 0))
            let line = ns.substring(with: contentRange)

            if line.hasPrefix(prefix) {
                let updated = String(line.dropFirst(prefix.count))
                replaceWithUndo(in: textView, range: contentRange, replacement: updated)
            } else {
                replaceWithUndo(in: textView, range: NSRange(location: contentRange.location, length: 0), replacement: prefix)
            }
        }

        private func toggleCurrentLineTodoState(in textView: NSTextView) {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = ns.substring(with: lineRange)
            if let unchecked = line.range(of: "[ ]") {
                let nsRange = NSRange(unchecked, in: line)
                replaceWithUndo(in: textView, range: NSRange(location: lineRange.location + nsRange.location, length: 3), replacement: "[x]")
                textView.setSelectedRange(sel)
            } else if let checked = line.range(of: "[x]", options: .caseInsensitive) {
                let nsRange = NSRange(checked, in: line)
                replaceWithUndo(in: textView, range: NSRange(location: lineRange.location + nsRange.location, length: 3), replacement: "[ ]")
                textView.setSelectedRange(sel)
            }
        }

        private func insertHorizontalDivider(in textView: NSTextView) {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let prefix = sel.location > 0 && ns.substring(with: NSRange(location: sel.location - 1, length: 1)) != "\n" ? "\n\n" : ""
            let snippet = "\(prefix)---\n\n"
            replaceWithUndo(in: textView, range: sel, replacement: snippet)
        }

        func replaceWithUndo(in textView: NSTextView, range: NSRange, replacement: String) {
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
        }

        // MARK: - 定位与样式刷新

        func performScroll(_ request: EditorState.ScrollRequest) {
            guard let textView else { return }
            let nsText = textView.string as NSString
            let lines = nsText.components(separatedBy: "\n")
            guard request.line > 0, request.line <= lines.count else { return }

            var location = 0
            for idx in 0..<(request.line - 1) {
                location += (lines[idx] as NSString).length + 1
            }
            if let column = request.column {
                let lineLen = (lines[request.line - 1] as NSString).length
                location += min(max(column, 0), lineLen)
            }
            let safeLocation = min(max(location, 0), nsText.length)
            let range = NSRange(location: safeLocation, length: min(request.length, nsText.length - safeLocation))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            if request.showFindIndicator && range.length > 0 {
                textView.showFindIndicator(for: range)
            }
        }

        func scheduleHighlight() {
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.applyStylesNow()
            }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(35), execute: work)
        }

        func applyStylesNow(forceInvalidateLayout: Bool = false) {
            guard let textView, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            isApplyingStyles = true
            defer { isApplyingStyles = false }

            let selectedRanges = textView.selectedRanges
            let activeRanges: [NSRange] = (textView.window?.firstResponder === textView)
                ? selectedRanges.map(\.rangeValue)
                : []

            lastActiveLineSignature = computeActiveLineSignature(in: textView)
            MarkdownStyler.apply(to: storage, config: currentConfig, activeRanges: activeRanges)
            if storage.length > 0 {
                var hasAnyImage = forceInvalidateLayout
                if !hasAnyImage {
                    storage.enumerateAttribute(.benImageAttachment, in: NSRange(location: 0, length: storage.length), options: []) { val, _, stop in
                        if val != nil {
                            hasAnyImage = true
                            stop.pointee = true
                        }
                    }
                }
                if hasAnyImage {
                    textView.layoutManager?.invalidateLayout(
                        forCharacterRange: NSRange(location: 0, length: storage.length),
                        actualCharacterRange: nil
                    )
                }
            }
            textView.selectedRanges = selectedRanges

            let typingFont = currentConfig.mode == .wysiwyg
                ? MarkdownStyler.resolveProseFont(name: currentConfig.proseFontName, size: currentConfig.fontSize)
                : MarkdownStyler.resolveCodeFont(name: currentConfig.codeFontName, size: currentConfig.fontSize)

            // 保持当前光标所在段落的 paragraphStyle，杜绝打字瞬间覆盖缩进或行距导致串位
            let currentParagraphStyle: NSParagraphStyle = {
                guard storage.length > 0 else {
                    return MarkdownStyler.makeBaseParagraphStyle(config: currentConfig)
                }
                let probeIndex = min(max(0, textView.selectedRange().location), storage.length - 1)
                if let para = storage.attribute(.paragraphStyle, at: probeIndex, effectiveRange: nil) as? NSParagraphStyle {
                    return para
                }
                return MarkdownStyler.makeBaseParagraphStyle(config: currentConfig)
            }()

            textView.typingAttributes = [
                .font: typingFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: currentParagraphStyle
            ]
            // 不调用 needsDisplay：storage.setAttributes 已让 layoutManager 精确失效并重绘脏区。
            // 对含大量自定义绘制（分割线/引用竖线/代码块底板）的长文，整视图重绘会造成明显闪烁。
        }

        private func updateCursorPosition() {
            guard let textView else { return }
            let source = textView.string as NSString
            let location = min(textView.selectedRange().location, source.length)
            let prefix = source.substring(to: location) as NSString
            let lines = prefix.components(separatedBy: "\n")
            onCursorPosition(lines.count, ((lines.last as NSString?)?.length ?? 0) + 1)
        }
    }
}

/// 自定义 NSTextView：
/// 1. 自适应居中阅读版心（740pt）；
/// 2. 原生绘制满宽居中 1pt 水平分割线、引用块左侧竖线与连续围栏代码块圆角底板；
/// 3. 点击 `- [ ]` 复选框直接切换完成状态。
private final class BenEditorTextView: NSTextView {
    var comfortableLineWidth = true
    var onFocusChanged: (() -> Void)?
    private let maxReadableWidth: CGFloat = 740
    private var headerHostingView: NSHostingView<FrontmatterBarView>?
    private var currentHorizontalInset: CGFloat = 36
    private var currentTopOriginY: CGFloat = 14
    private var headerHeight: CGFloat = 0

    override var textContainerOrigin: NSPoint {
        NSPoint(x: currentHorizontalInset, y: currentTopOriginY)
    }

    override func resetCursorRects() {
        var textRect = visibleRect
        if headerHeight > 0 {
            let headerBottom = headerHeight + 14
            if textRect.minY < headerBottom {
                let delta = min(textRect.height, headerBottom - textRect.minY)
                textRect.origin.y += delta
                textRect.size.height -= delta
            }
        }
        if textRect.height > 0 {
            addCursorRect(textRect, cursor: .iBeam)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            DispatchQueue.main.async { [weak self] in self?.onFocusChanged?() }
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            DispatchQueue.main.async { [weak self] in self?.onFocusChanged?() }
        }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadableInsets()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateReadableInsets()
        if superview != nil {
            BenEditorViewRegistry.register(self)
        } else {
            BenEditorViewRegistry.unregister(self)
        }
    }

    override func removeFromSuperview() {
        super.removeFromSuperview()
        BenEditorViewRegistry.unregister(self)
    }

    func updateHeaderAccessory(app: AppState, hasFrontmatter: Bool) {
        if hasFrontmatter {
            let hosting: NSHostingView<FrontmatterBarView>
            if let existing = headerHostingView {
                existing.rootView = FrontmatterBarView(app: app)
                hosting = existing
            } else {
                let created = NSHostingView(rootView: FrontmatterBarView(app: app))
                // 保留默认 sizingOptions（intrinsicContentSize），否则 fittingSize 只返回
                // 约 12pt 的最小高度，属性栏会被压扁并裁掉字段内容。
                addSubview(created)
                headerHostingView = created
                hosting = created
            }
            hosting.isHidden = false
        } else {
            headerHostingView?.isHidden = true
            headerHeight = 0
        }
    }

    func updateReadableInsets() {
        let availableWidth = enclosingScrollView?.contentSize.width ?? bounds.width
        let horizontalInset: CGFloat
        if comfortableLineWidth && availableWidth > maxReadableWidth + 80 {
            horizontalInset = floor((availableWidth - maxReadableWidth) / 2)
        } else {
            horizontalInset = 36
        }
        let clampedX = max(28, horizontalInset)
        let columnWidth = max(200, availableWidth - clampedX * 2)

        var measuredHeader: CGFloat = 0
        if let hosting = headerHostingView, !hosting.isHidden {
            hosting.frame.size.width = columnWidth
            hosting.layoutSubtreeIfNeeded()
            measuredHeader = ceil(hosting.fittingSize.height)
            let targetFrame = NSRect(x: clampedX, y: 2, width: columnWidth, height: measuredHeader)
            if hosting.frame != targetFrame {
                hosting.frame = targetFrame
            }
        }
        headerHeight = measuredHeader

        let topOrigin: CGFloat = measuredHeader > 0 ? (2 + measuredHeader + 14) : 10
        let bottomPadding: CGFloat = 32
        let symmetricInsetHeight = ceil((topOrigin + bottomPadding) / 2)
        let targetInset = NSSize(width: clampedX, height: symmetricInsetHeight)

        let originChanged = currentHorizontalInset != clampedX || currentTopOriginY != topOrigin
        currentHorizontalInset = clampedX
        currentTopOriginY = topOrigin

        if textContainerInset != targetInset {
            textContainerInset = targetInset
        } else if originChanged {
            if let layoutManager, let textContainer {
                layoutManager.textContainerChangedGeometry(textContainer)
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawMarkdownBlockDecorations(in: rect)
    }

    private func drawMarkdownBlockDecorations(in dirtyRect: NSRect) {
        guard let layoutManager,
              let textContainer,
              let storage = textStorage,
              storage.length > 0 else { return }

        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -24)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        guard glyphRange.length > 0 else { return }

        let contentLeft = origin.x
        let contentWidth = max(40, textContainer.containerSize.width)

        var pendingCodeBlockRect: NSRect?
        func flushCodeBlock() {
            guard let blockRect = pendingCodeBlockRect else { return }
            let padded = NSRect(
                x: contentLeft - 10,
                y: blockRect.minY - 3,
                width: contentWidth + 20,
                height: blockRect.height + 6
            )
            let path = NSBezierPath(roundedRect: padded, xRadius: 7, yRadius: 7)
            NSColor.black.withAlphaComponent(0.042).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.065).setStroke()
            path.lineWidth = 1
            path.stroke()
            pendingCodeBlockRect = nil
        }

        var glyphIndex = glyphRange.location
        let endGlyph = glyphRange.location + glyphRange.length

        while glyphIndex < endGlyph {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            if charIndex < storage.length {
                let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
                let viewLineRect = NSRect(
                    x: contentLeft,
                    y: origin.y + lineFrag.minY,
                    width: contentWidth,
                    height: lineFrag.height
                )

                // 1. 连续代码块圆角底板聚合
                if attrs[.benCodeBlock] != nil {
                    if let existing = pendingCodeBlockRect {
                        pendingCodeBlockRect = existing.union(viewLineRect)
                    } else {
                        pendingCodeBlockRect = viewLineRect
                    }
                } else {
                    flushCodeBlock()
                }

                // 2. 居中满宽 1pt 浅灰水平分割线
                if (attrs[.benHorizontalRule] as? Bool) == true {
                    let midY = floor(viewLineRect.midY) + 0.5
                    let rulePath = NSBezierPath()
                    rulePath.move(to: NSPoint(x: contentLeft, y: midY))
                    rulePath.line(to: NSPoint(x: contentLeft + contentWidth, y: midY))
                    rulePath.lineWidth = 1.0
                    let isEditingLine = attrs[.benHiddenSyntax] == nil
                    NSColor.black.withAlphaComponent(isEditingLine ? 0.08 : 0.14).setStroke()
                    rulePath.stroke()
                }

                // 3. 引用块左侧竖线（支持多级嵌套 >>）
                if let depth = attrs[.benBlockquoteDepth] as? Int, depth > 0 {
                    for level in 1...depth {
                        let barX = contentLeft + CGFloat(level - 1) * 16 + 2
                        let barRect = NSRect(
                            x: barX,
                            y: viewLineRect.minY + 1,
                            width: 3,
                            height: max(4, viewLineRect.height - 2)
                        )
                        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
                        NSColor.black.withAlphaComponent(0.16).setFill()
                        barPath.fill()
                    }
                }

                // 4. 所见即所得内嵌图片与占位卡片渲染（仅在该段落最后一个视觉行片段底部绘制）
                if let imageSpec = attrs[.benImageAttachment] as? BenImageLayoutSpec {
                    let fragChars = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
                    let ns = storage.string as NSString
                    let paraRange = ns.lineRange(for: NSRange(location: fragChars.location, length: 0))
                    let hasNewline = paraRange.length > 0 && ns.character(at: paraRange.location + paraRange.length - 1) == 10
                    let contentEnd = paraRange.location + paraRange.length - (hasNewline ? 1 : 0)

                    if fragChars.location + fragChars.length >= contentEnd {
                        let totalImgHeight = imageSpec.totalBlockHeight(availableWidth: contentWidth)
                        var currentY = viewLineRect.maxY - totalImgHeight
                        for item in imageSpec.items {
                            let itemHeight = BenImageLayoutSpec.itemHeight(for: item, availableWidth: contentWidth)
                            drawImageItem(
                                item,
                                in: NSRect(x: contentLeft, y: currentY, width: contentWidth, height: itemHeight)
                            )
                            currentY += itemHeight
                        }
                    }
                }
            } else {
                flushCodeBlock()
            }

            glyphIndex = max(glyphIndex + 1, lineGlyphRange.location + lineGlyphRange.length)
        }

        flushCodeBlock()
    }

    private func drawImageItem(_ item: BenRenderedImageItem, in slotRect: NSRect) {
        switch item.state {
        case let .loaded(image, pixelSize):
            let fitted = BenImageLayoutSpec.displaySize(
                for: pixelSize,
                preferredMaxWidth: item.preferredMaxWidth,
                availableWidth: slotRect.width
            )
            let imageRect = NSRect(
                x: slotRect.minX,
                y: slotRect.minY + 6,
                width: fitted.width,
                height: fitted.height
            )

            NSGraphicsContext.saveGraphicsState()
            let clipPath = NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6)
            clipPath.addClip()
            image.draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()

            let borderPath = NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6)
            NSColor.black.withAlphaComponent(0.08).setStroke()
            borderPath.lineWidth = 1
            borderPath.stroke()

            let caption = item.alt.isEmpty ? (item.title ?? "") : item.alt
            if !caption.isEmpty {
                let captionAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let nsCaption = caption as NSString
                let captionSize = nsCaption.size(withAttributes: captionAttrs)
                let captionX = imageRect.minX + max(0, (imageRect.width - min(imageRect.width, captionSize.width)) / 2)
                let captionRect = NSRect(
                    x: captionX,
                    y: imageRect.maxY + 4,
                    width: min(slotRect.width, captionSize.width + 4),
                    height: 16
                )
                nsCaption.draw(with: captionRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: captionAttrs)
            }

        case .loading, .missing:
            let cardRect = NSRect(
                x: slotRect.minX,
                y: slotRect.minY + 6,
                width: min(slotRect.width, 420),
                height: 40
            )
            let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 7, yRadius: 7)
            NSColor.black.withAlphaComponent(0.032).setFill()
            cardPath.fill()
            NSColor.black.withAlphaComponent(0.10).setStroke()
            cardPath.lineWidth = 1
            cardPath.stroke()

            let statusPrefix = item.state == .loading ? "正在加载图片" : "未找到图片"
            let label = item.alt.isEmpty ? item.source : "\(item.alt)（\(item.source)）"
            let display = "\(statusPrefix)：\(label)" as NSString
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let textRect = NSRect(
                x: cardRect.minX + 12,
                y: cardRect.minY + 11,
                width: cardRect.width - 24,
                height: 18
            )
            display.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: textAttrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleCheckboxIfClicked(at: point) {
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleCheckboxIfClicked(at point: NSPoint) -> Bool {
        guard !hasMarkedText(),
              let layoutManager,
              let textContainer else { return false }
        let containerOrigin = textContainerOrigin
        let localPoint = NSPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)
        var fraction: CGFloat = 0
        let charIndex = layoutManager.characterIndex(
            for: localPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        let ns = string as NSString
        guard charIndex < ns.length else { return false }

        let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = ns.substring(with: lineRange)
        guard let regex = try? NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+(\[[ xX]\])"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return false
        }
        let boxInLine = match.range(at: 1)
        let boxGlobal = NSRange(location: lineRange.location + boxInLine.location, length: boxInLine.length)
        guard charIndex >= boxGlobal.location && charIndex <= boxGlobal.location + boxGlobal.length else {
            return false
        }
        let currentBox = ns.substring(with: boxGlobal)
        let replacement = currentBox == "[ ]" ? "[x]" : "[ ]"
        if shouldChangeText(in: boxGlobal, replacementString: replacement) {
            textStorage?.replaceCharacters(in: boxGlobal, with: replacement)
            didChangeText()
            return true
        }
        return false
    }
}
