import SwiftUI
import AppKit

/// 统一承载「所见即所得（类 Bear 风格）」与「纯源码」两种模式的编辑器视图。
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
                text: Binding(
                    get: { app.editor.text },
                    set: { app.editor.updateTextFromUser($0) }
                ),
                styleConfig: MarkdownStyler.StyleConfig(
                    mode: app.editor.mode,
                    proseFontName: proseFontName,
                    codeFontName: codeFontName,
                    fontSize: CGFloat(fontSize),
                    lineSpacing: CGFloat(lineSpacing)
                ),
                comfortableLineWidth: comfortableLineWidth,
                scrollRequest: app.editor.scrollRequest,
                formatCommand: app.editor.formatCommand,
                onCursorPosition: { line, column in
                    app.editor.cursorLine = line
                    app.editor.cursorColumn = column
                }
            )
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

    // MARK: - 类 Bear 顶部轻量格式栏

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
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - 搜索跳转提示横幅

    private func matchBanner(line: Int) -> some View {
        let lines = app.editor.text.components(separatedBy: "\n")
        let lineText = lines.indices.contains(line - 1) ? lines[line - 1] : ""
        let query = app.editor.highlightedQuery

        return HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .foregroundStyle(Color.accentColor)
            Text("第 \(line) 行")
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

// MARK: - 原生 AppKit NSTextView 封装（支持中文拼音输入法保护、Undo/Redo、列表自动续行、待办点击切换、居中舒适版心）

private struct MarkdownCanvasRepresentable: NSViewRepresentable {
    @Binding var text: String
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
        textView.insertionPointColor = .controlAccentColor
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.comfortableLineWidth = comfortableLineWidth
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.currentConfig = styleConfig
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
            textView.updateReadableInsets()
        }

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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var currentConfig: MarkdownStyler.StyleConfig
        var onCursorPosition: (Int, Int) -> Void
        weak var textView: BenEditorTextView?
        var lastScrollToken: UUID?
        var lastFormatToken: UUID?
        var isApplyingExternalText = false
        private var highlightWorkItem: DispatchWorkItem?

        init(
            text: Binding<String>,
            config: MarkdownStyler.StyleConfig,
            onCursorPosition: @escaping (Int, Int) -> Void
        ) {
            self.text = text
            self.currentConfig = config
            self.onCursorPosition = onCursorPosition
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
            updateCursorPosition()
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

            // 匹配普通列表或有序列表
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

            // 若选区外侧紧邻 marker，则剥离
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

            // 若选区本身首尾包含 marker，也剥离
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
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(45), execute: work)
        }

        func applyStylesNow() {
            guard let textView, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            let selectedRanges = textView.selectedRanges
            MarkdownStyler.apply(to: storage, config: currentConfig)
            textView.selectedRanges = selectedRanges
            let typingFont = currentConfig.mode == .wysiwyg
                ? MarkdownStyler.resolveProseFont(name: currentConfig.proseFontName, size: currentConfig.fontSize)
                : MarkdownStyler.resolveCodeFont(name: currentConfig.codeFontName, size: currentConfig.fontSize)
            let typingPara = NSMutableParagraphStyle()
            typingPara.lineSpacing = currentConfig.lineSpacing
            textView.typingAttributes = [
                .font: typingFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: typingPara
            ]
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

/// 自定义 NSTextView：支持自适应居中阅读版心，以及在点击 `- [ ]` 复选框时直接切换完成状态。
private final class BenEditorTextView: NSTextView {
    var comfortableLineWidth = true
    private let maxReadableWidth: CGFloat = 740

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadableInsets()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateReadableInsets()
    }

    func updateReadableInsets() {
        let availableWidth = enclosingScrollView?.contentSize.width ?? bounds.width
        let horizontalInset: CGFloat
        if comfortableLineWidth && availableWidth > maxReadableWidth + 80 {
            horizontalInset = floor((availableWidth - maxReadableWidth) / 2)
        } else {
            horizontalInset = 36
        }
        let targetInset = NSSize(width: max(28, horizontalInset), height: 28)
        if textContainerInset != targetInset {
            textContainerInset = targetInset
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
        guard let regex = try? NSRegularExpression(pattern: #"^\s*[-*+]\s+(\[[ xX]\])"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return false
        }
        let boxInLine = match.range(at: 1)
        let boxGlobal = NSRange(location: lineRange.location + boxInLine.location, length: boxInLine.length)
        // 仅当点击落在 `[ ]` 附近字符时触发切换
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
