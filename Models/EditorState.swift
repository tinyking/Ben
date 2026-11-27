import Foundation
import Observation

enum EditorMode: String, CaseIterable, Identifiable {
    case wysiwyg
    case source

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wysiwyg: return "所见即所得"
        case .source: return "纯源码"
        }
    }

    var shortLabel: String {
        switch self {
        case .wysiwyg: return "所见即所得"
        case .source: return "源码"
        }
    }

    var symbol: String {
        switch self {
        case .wysiwyg: return "doc.richtext"
        case .source: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum MarkdownFormatAction: Equatable {
    case bold
    case italic
    case strikethrough
    case highlight
    case inlineCode
    case link
    case heading(Int)
    case bulletList
    case numberedList
    case todoList
    case toggleTodo
    case blockquote
    case divider
}

/// 当前打开笔记的编辑状态（MVVM 中的 ViewModel）：
/// `frontmatter` 与纯 Markdown 正文 `text` 分离持有，加载时自动解耦，保存时无损拼回。
@Observable
final class EditorState {
    struct ScrollRequest: Equatable {
        let url: URL
        let line: Int
        let column: Int?
        let length: Int
        let showFindIndicator: Bool
        let token: UUID

        init(
            url: URL,
            line: Int,
            column: Int? = nil,
            length: Int = 0,
            showFindIndicator: Bool = false,
            token: UUID = UUID()
        ) {
            self.url = url
            self.line = line
            self.column = column
            self.length = length
            self.showFindIndicator = showFindIndicator
            self.token = token
        }
    }

    struct FormatCommand: Equatable {
        let token = UUID()
        let action: MarkdownFormatAction
    }

    var currentNote: URL?
    /// 剥离了头部 YAML Frontmatter 后的纯 Markdown 正文。
    var text: String = ""
    /// 文档头部的 YAML Frontmatter（无 Frontmatter 时为 `nil`）。
    var frontmatter: FrontmatterDocument?
    var isFrontmatterExpanded = false
    var isDirty = false
    var mode: EditorMode = .wysiwyg
    var errorMessage: String?
    var highlightedLine: Int?
    var highlightedQuery: String = ""
    var scrollRequest: ScrollRequest?
    var formatCommand: FormatCommand?
    var cursorLine = 1
    var cursorColumn = 1

    // 页内查找与替换状态
    var findQuery = ""
    var replaceText = ""
    var isFindCaseSensitive = false
    private(set) var findMatches: [NSRange] = []
    private(set) var currentFindMatchIndex: Int = 0

    private var autosaveWorkItem: DispatchWorkItem?
    var onDidSave: (() -> Void)?

    var displayName: String {
        currentNote?.deletingPathExtension().lastPathComponent ?? "未打开笔记"
    }

    var frontmatterLineOffset: Int {
        frontmatter?.lineOffset ?? 0
    }

    /// 拼回头部 Frontmatter 后的完整磁盘 `.md` 文本。
    var fullDocumentText: String {
        FrontmatterParser.compose(frontmatter: frontmatter, body: text)
    }

    @ObservationIgnored private var countCacheKey = ""
    @ObservationIgnored private var countCacheValue = 0

    var nonWhitespaceCount: Int {
        if countCacheKey == text { return countCacheValue }
        let value = text.filter { !$0.isWhitespace }.count
        countCacheKey = text
        countCacheValue = value
        return value
    }

    var estimatedReadingMinutes: Int {
        max(1, (nonWhitespaceCount + 399) / 400)
    }

    /// 从磁盘加载一篇笔记。若目标与当前文件相同且有未保存修改，则跳过。
    @discardableResult
    func load(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "md" else { return false }
        if currentNote == url && isDirty { return false }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            applyLoadedContent(content, url: url)
            return true
        } catch {
            errorMessage = "无法打开「\(url.lastPathComponent)」：\(error.localizedDescription)"
            return false
        }
    }

    func applyLoadedContent(_ content: String, url: URL? = nil) {
        let parsed = FrontmatterParser.parse(content)
        currentNote = url
        frontmatter = parsed.frontmatter
        isFrontmatterExpanded = false
        text = parsed.body
        isDirty = false
        errorMessage = nil
        cursorLine = 1
        cursorColumn = 1
        recomputeFindMatches(resetIndex: true)
    }

    func updateTextFromUser(_ value: String) {
        guard text != value else { return }
        text = value
        isDirty = true
        if !findQuery.isEmpty {
            recomputeFindMatches(resetIndex: false)
        }
        scheduleAutosave()
    }

    // MARK: - Frontmatter 属性栏编辑

    func updateFrontmatterField(id: UUID, key: String, value: String) {
        guard var doc = frontmatter,
              let idx = doc.fields.firstIndex(where: { $0.id == id }) else { return }
        guard doc.fields[idx].key != key || doc.fields[idx].value != value else { return }
        doc.fields[idx].key = key
        doc.fields[idx].value = value
        doc.isModified = true
        frontmatter = doc
        isDirty = true
        scheduleAutosave()
    }

    func addFrontmatterField(key: String = "属性", value: String = "") {
        guard var doc = frontmatter else { return }
        doc.fields.append(FrontmatterField(key: key, value: value))
        doc.isModified = true
        frontmatter = doc
        isFrontmatterExpanded = true
        isDirty = true
        scheduleAutosave()
    }

    func removeFrontmatterField(id: UUID) {
        guard var doc = frontmatter else { return }
        doc.fields.removeAll { $0.id == id }
        doc.isModified = true
        frontmatter = doc
        isDirty = true
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.save() }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600), execute: work)
    }

    func applyFormat(_ action: MarkdownFormatAction) {
        guard currentNote != nil else { return }
        formatCommand = FormatCommand(action: action)
    }

    func appendTodayHeading() {
        guard let currentNote else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let heading = "### \(formatter.string(from: Date()))"
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        text += separator + heading + "\n\n"
        isDirty = true
        save()
        let line = text.components(separatedBy: "\n").count
        scrollRequest = ScrollRequest(url: currentNote, line: line, column: 0)
    }

    // MARK: - 页内查找与替换

    func updateFindQuery(_ query: String) {
        findQuery = query
        recomputeFindMatches(resetIndex: true)
        if !findMatches.isEmpty {
            scrollToFindMatch(at: 0)
        }
    }

    func toggleFindCaseSensitive() {
        isFindCaseSensitive.toggle()
        recomputeFindMatches(resetIndex: true)
        if !findMatches.isEmpty {
            scrollToFindMatch(at: 0)
        }
    }

    func recomputeFindMatches(resetIndex: Bool) {
        guard !findQuery.isEmpty else {
            findMatches = []
            currentFindMatchIndex = 0
            return
        }
        let source = text as NSString
        let options: NSString.CompareOptions = isFindCaseSensitive ? [] : [.caseInsensitive]
        var ranges: [NSRange] = []
        var searchLocation = 0
        while searchLocation < source.length {
            let found = source.range(
                of: findQuery,
                options: options,
                range: NSRange(location: searchLocation, length: source.length - searchLocation)
            )
            if found.location == NSNotFound { break }
            ranges.append(found)
            searchLocation = found.location + max(1, found.length)
        }
        findMatches = ranges
        if resetIndex || currentFindMatchIndex >= ranges.count {
            currentFindMatchIndex = 0
        }
    }

    func findNext() {
        recomputeFindMatches(resetIndex: false)
        guard !findMatches.isEmpty else { return }
        let next = (currentFindMatchIndex + 1) % findMatches.count
        currentFindMatchIndex = next
        scrollToFindMatch(at: next)
    }

    func findPrevious() {
        recomputeFindMatches(resetIndex: false)
        guard !findMatches.isEmpty else { return }
        let prev = (currentFindMatchIndex - 1 + findMatches.count) % findMatches.count
        currentFindMatchIndex = prev
        scrollToFindMatch(at: prev)
    }

    func replaceCurrent() {
        recomputeFindMatches(resetIndex: false)
        guard !findMatches.isEmpty, currentNote != nil else { return }
        let safeIndex = min(max(0, currentFindMatchIndex), findMatches.count - 1)
        let targetRange = findMatches[safeIndex]
        let source = text as NSString
        guard targetRange.location + targetRange.length <= source.length else { return }
        let updated = source.replacingCharacters(in: targetRange, with: replaceText)
        updateTextFromUser(updated)
        recomputeFindMatches(resetIndex: false)
        if !findMatches.isEmpty {
            let nextIndex = min(safeIndex, findMatches.count - 1)
            currentFindMatchIndex = nextIndex
            scrollToFindMatch(at: nextIndex)
        }
    }

    func replaceAll() {
        guard !findQuery.isEmpty, currentNote != nil else { return }
        let options: String.CompareOptions = isFindCaseSensitive ? [] : [.caseInsensitive]
        let updated = text.replacingOccurrences(of: findQuery, with: replaceText, options: options)
        guard updated != text else { return }
        updateTextFromUser(updated)
        recomputeFindMatches(resetIndex: true)
    }

    private func scrollToFindMatch(at index: Int) {
        guard let currentNote, findMatches.indices.contains(index) else { return }
        let range = findMatches[index]
        let source = text as NSString
        let prefix = source.substring(to: range.location)
        let line = prefix.components(separatedBy: "\n").count
        let lastNewline = (prefix as NSString).range(of: "\n", options: .backwards).location
        let column = lastNewline == NSNotFound ? (prefix as NSString).length : (prefix as NSString).length - lastNewline - 1
        scrollRequest = ScrollRequest(
            url: currentNote,
            line: line,
            column: column,
            length: range.length,
            showFindIndicator: true
        )
    }

    // MARK: - 文档大纲（仅扫描剥离 Frontmatter 后的正文，且精确跳过任意长度围栏代码块）

    // 光标每次移动都会触发右侧大纲重绘；若不缓存，417 行长文会被重复全篇扫描 3 次以上。
    // 用 @ObservationIgnored 避免缓存写入本身再次触发 SwiftUI 更新。
    @ObservationIgnored private var outlineCacheKey = ""
    @ObservationIgnored private var outlineCache: [OutlineEntry] = []

    var outline: [OutlineEntry] {
        if outlineCacheKey == text { return outlineCache }
        let lines = text.components(separatedBy: "\n")
        let codeStates = MarkdownStyler.computeCodeBlockLineStates(in: lines)
        var entries: [OutlineEntry] = []

        for (index, line) in lines.enumerated() where codeStates[index] == .none {
            let trimmed = line.drop(while: { $0 == " " })
            guard line.prefix(while: { $0 == " " }).count <= 3 else { continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level),
                  trimmed.count > level,
                  trimmed.dropFirst(level).first?.isWhitespace == true else { continue }
            var title = String(trimmed.dropFirst(level).drop(while: { $0.isWhitespace }))
            if let closingRange = title.range(of: #"[ \t]+#+[ \t]*$"#, options: .regularExpression) {
                title.removeSubrange(closingRange)
            }
            guard !title.isEmpty else { continue }
            entries.append(OutlineEntry(line: index + 1, level: level, title: title))
        }
        outlineCacheKey = text
        outlineCache = entries
        return entries
    }

    // MARK: - 保存与同步（自动将 Frontmatter 原样或结构化拼回文件头部）

    @discardableResult
    func save() -> Bool {
        guard let url = currentNote else { return false }
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        do {
            try fullDocumentText.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            errorMessage = nil
            onDidSave?()
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 放弃未保存的修改，从磁盘重新读取。
    func revert() {
        guard let url = currentNote else { return }
        isDirty = false
        load(url)
    }

    /// 外部进程改动了当前文件且本地没有未保存修改时，静默同步内容。
    func reloadFromDiskIfNeeded() {
        guard let url = currentNote, !isDirty else { return }
        guard let diskText = try? String(contentsOf: url, encoding: .utf8) else { return }
        if diskText != fullDocumentText {
            let parsed = FrontmatterParser.parse(diskText)
            frontmatter = parsed.frontmatter
            text = parsed.body
            highlightedLine = nil
            recomputeFindMatches(resetIndex: false)
        }
    }

    func clear() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        currentNote = nil
        frontmatter = nil
        isFrontmatterExpanded = false
        text = ""
        isDirty = false
        highlightedLine = nil
        highlightedQuery = ""
        scrollRequest = nil
        findMatches = []
        currentFindMatchIndex = 0
    }
}

struct OutlineEntry: Identifiable, Equatable {
    let line: Int
    let level: Int
    let title: String
    var id: Int { line }
}
