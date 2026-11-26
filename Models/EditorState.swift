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

/// 当前打开笔记的编辑状态（MVVM 中的 ViewModel）。
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
    var text: String = ""
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

    var nonWhitespaceCount: Int {
        text.filter { !$0.isWhitespace }.count
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
            currentNote = url
            text = content
            isDirty = false
            errorMessage = nil
            cursorLine = 1
            cursorColumn = 1
            recomputeFindMatches(resetIndex: true)
            return true
        } catch {
            errorMessage = "无法打开「\(url.lastPathComponent)」：\(error.localizedDescription)"
            return false
        }
    }

    func updateTextFromUser(_ value: String) {
        guard text != value else { return }
        text = value
        isDirty = true
        if !findQuery.isEmpty {
            recomputeFindMatches(resetIndex: false)
        }
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

    // MARK: - 文档大纲（自动忽略代码块内的 # 注释）

    var outline: [OutlineEntry] {
        var insideFence = false
        var entries: [OutlineEntry] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level),
                  trimmed.count > level,
                  trimmed.dropFirst(level).first?.isWhitespace == true else { continue }
            let title = trimmed.dropFirst(level).drop(while: { $0.isWhitespace })
            guard !title.isEmpty else { continue }
            entries.append(OutlineEntry(line: index + 1, level: level, title: String(title)))
        }
        return entries
    }

    // MARK: - 保存与同步

    @discardableResult
    func save() -> Bool {
        guard let url = currentNote else { return false }
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
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
        if diskText != text {
            text = diskText
            highlightedLine = nil
            recomputeFindMatches(resetIndex: false)
        }
    }

    func clear() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        currentNote = nil
        text = ""
        isDirty = false
        highlightedLine = nil
        highlightedQuery = ""
        scrollRequest = nil
        findMatches = []
        currentFindMatchIndex = 0
    }
}

struct OutlineEntry: Identifiable {
    let line: Int
    let level: Int
    let title: String
    var id: Int { line }
}
