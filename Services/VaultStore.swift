import Foundation
import Observation
import AppKit
import Darwin

/// 负责仓库目录的读写、文件树构建、摘要缓存、文件操作与外部改动监听。
@Observable
final class VaultStore {
    private(set) var vaultURL: URL?
    private(set) var tree: [NoteFile] = []
    private(set) var totalNoteCount: Int = 0
    var errorMessage: String?

    /// 仓库变化通知（用于持久化）。
    var onVaultChanged: ((URL?) -> Void)?
    /// 文件树刷新通知（用于同步当前打开笔记的外部改动）。
    var onFilesChanged: (() -> Void)?

    private var watchers: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounceTimer: DispatchSourceTimer?
    private let fsQueue = DispatchQueue(label: "com.ben.vault.fs", qos: .utility)

    var vault: Vault? { vaultURL.map(Vault.init(url:)) }

    // MARK: - 仓库

    /// 弹出系统面板选择（或创建）一个文件夹作为本子。
    func chooseVault() {
        let panel = NSOpenPanel()
        panel.title = "选择本子文件夹"
        panel.message = "选择一个已有文件夹，或新建一个文件夹存放你的 Markdown 笔记。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    @discardableResult
    func open(url: URL) -> Bool {
        guard Vault.isValid(url) else {
            errorMessage = "「\(url.lastPathComponent)」不是一个可用的文件夹。"
            return false
        }
        stopWatching()
        vaultURL = url
        errorMessage = nil
        rebuildTree()
        onVaultChanged?(url)
        return true
    }

    func close() {
        stopWatching()
        vaultURL = nil
        tree = []
        totalNoteCount = 0
        onVaultChanged?(nil)
    }

    /// 仓库根目录被外部改名或删除时，退回引导页。
    func checkHealth() {
        guard let url = vaultURL else { return }
        if !Vault.isValid(url) {
            errorMessage = "原来的本子文件夹已不存在，请重新选择。"
            close()
        }
    }

    // MARK: - 文件树与查询

    func refresh() {
        guard vaultURL != nil else { return }
        rebuildTree()
    }

    /// 在文件树中递归查找指定 URL 对应的节点（支持任意深度子目录）。
    func node(for targetURL: URL) -> NoteFile? {
        let standardizedTarget = targetURL.standardizedFileURL
        func search(_ nodes: [NoteFile]) -> NoteFile? {
            for item in nodes {
                if item.url.standardizedFileURL == standardizedTarget {
                    return item
                }
                if let children = item.children, let match = search(children) {
                    return match
                }
            }
            return nil
        }
        return search(tree)
    }

    /// 获取全部笔记（按最近修改时间倒序）。
    func allNotes() -> [NoteFile] {
        func collect(_ nodes: [NoteFile]) -> [NoteFile] {
            nodes.flatMap { item in
                item.isDirectory ? collect(item.children ?? []) : (item.isMarkdown ? [item] : [])
            }
        }
        return Self.sortNotesByModifiedDate(collect(tree))
    }

    /// 获取指定目录下的笔记列表；若传入根目录或 nil，则返回全库所有笔记。
    func notes(in folderURL: URL?) -> [NoteFile] {
        guard let root = vaultURL else { return [] }
        let target = (folderURL ?? root).standardizedFileURL
        if target == root.standardizedFileURL {
            return allNotes()
        }
        guard let folderNode = node(for: target) else { return [] }
        let directNotes = (folderNode.children ?? []).filter(\.isMarkdown)
        return Self.sortNotesByModifiedDate(directNotes)
    }

    private func rebuildTree() {
        guard let root = vaultURL else {
            tree = []
            totalNoteCount = 0
            return
        }
        let built = Self.buildNodes(at: root)
        tree = built
        totalNoteCount = Self.countAllNotes(in: built)
        installWatchers()
    }

    private static func countAllNotes(in nodes: [NoteFile]) -> Int {
        nodes.reduce(0) { sum, item in
            if item.isDirectory {
                return sum + countAllNotes(in: item.children ?? [])
            }
            return sum + (item.isMarkdown ? 1 : 0)
        }
    }

    private static func sortNotesByModifiedDate(_ notes: [NoteFile]) -> [NoteFile] {
        notes.sorted {
            let lhs = $0.modifiedDate ?? .distantPast
            let rhs = $1.modifiedDate ?? .distantPast
            if lhs != rhs { return lhs > rhs }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func buildNodes(at directory: URL) -> [NoteFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var folders: [NoteFile] = []
        var notes: [NoteFile] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                let children = buildNodes(at: entry)
                let directCount = children.filter(\.isMarkdown).count
                folders.append(NoteFile(
                    url: entry,
                    isDirectory: true,
                    modifiedDate: values?.contentModificationDate,
                    directNoteCount: directCount,
                    children: children
                ))
            } else if entry.pathExtension.lowercased() == "md" {
                notes.append(NoteFile(
                    url: entry,
                    isDirectory: false,
                    modifiedDate: values?.contentModificationDate,
                    previewText: extractPreviewText(from: entry)
                ))
            }
        }

        let byName: (NoteFile, NoteFile) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + notes.sorted(by: byName)
    }

    /// 仅剥离首行开始且有闭合标记的 YAML，再提取第一段真实正文。
    private static func extractPreviewText(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无附加文本" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384) else { return "无附加文本" }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)

        // YAML front matter is recognized only when line 1 is exactly `---`
        // and a matching exact delimiter closes it. Other separators are content.
        if lines.first == "---", let closing = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(0...closing)
        }

        var inCodeBlock = false
        var paragraph: [String] = []
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                if !paragraph.isEmpty { break }
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { continue }
            if trimmed.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if trimmed.range(of: #"^#{1,6}(?:\s|$)"#, options: .regularExpression) != nil
                || trimmed.hasPrefix("<!--")
                || trimmed == "---" || trimmed == "***" || trimmed == "___" {
                if !paragraph.isEmpty { break }
                continue
            }
            // 跳过表格分隔线
            if trimmed.contains("|"),
               trimmed.replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            paragraph.append(trimmed)
        }

        let cleaned = stripMarkdownSyntax(paragraph.joined(separator: " "))
        return cleaned.isEmpty ? "无附加文本" : String(cleaned.prefix(240))
    }

    private static func stripMarkdownSyntax(_ line: String) -> String {
        var s = line
        // 去掉列表/引用/待办前缀
        s = s.replacingOccurrences(of: #"^(?:>\s*)+|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
        // 图片 ![alt](url) -> alt
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // 链接 [text](url) -> text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // 行内标记
        s = s.replacingOccurrences(of: #"[`*~_==]+"#, with: "", options: .regularExpression)
        // 表格竖线转空格
        s = s.replacingOccurrences(of: "|", with: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 文件与文件夹操作

    /// 在指定目录新建笔记（重名时自动递增序号）。
    @discardableResult
    func createNote(in directory: URL) -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let parent = fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? directory
            : vaultURL
        guard let parent else { return nil }

        var candidate = parent.appendingPathComponent("未命名笔记.md")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("未命名笔记 \(index).md")
            index += 1
        }
        do {
            try "".write(to: candidate, atomically: true, encoding: .utf8)
            rebuildTree()
            return candidate
        } catch {
            errorMessage = "新建笔记失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 在指定目录新建子文件夹（重名时自动递增序号）。
    @discardableResult
    func createFolder(in directory: URL) -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let parent = fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? directory
            : vaultURL
        guard let parent else { return nil }

        var candidate = parent.appendingPathComponent("新建文件夹")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("新建文件夹 \(index)")
            index += 1
        }
        do {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
            rebuildTree()
            return candidate
        } catch {
            errorMessage = "新建文件夹失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func rename(_ url: URL, to rawName: String, isDirectory: Bool) -> URL? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != "." && name != ".." else {
            errorMessage = "名称不合法，请避免斜杠或冒号。"
            return nil
        }
        if !isDirectory && !name.lowercased().hasSuffix(".md") {
            name += ".md"
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.standardizedFileURL != url.standardizedFileURL else { return url }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "「\(name)」已存在。"
            return nil
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            rebuildTree()
            return destination
        } catch {
            errorMessage = "重命名失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func delete(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            rebuildTree()
            return true
        } catch {
            errorMessage = "移到废纸篓失败：\(error.localizedDescription)"
            return false
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 外部改动监听

    private func installWatchers() {
        stopWatching()
        guard let root = vaultURL else { return }

        var directories: [URL] = [root]
        func collect(_ nodes: [NoteFile]) {
            for node in nodes where node.isDirectory {
                directories.append(node.url)
                if let children = node.children { collect(children) }
            }
        }
        collect(tree)

        for directory in directories {
            let fd = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY)
            }
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: fsQueue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleRefresh()
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            source.resume()
            watchers[directory] = source
        }
    }

    private func scheduleRefresh() {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: fsQueue)
        timer.schedule(deadline: .now() + 0.3, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.rebuildTree()
                self?.onFilesChanged?()
            }
        }
        timer.resume()
        debounceTimer = timer
    }

    private func stopWatching() {
        debounceTimer?.cancel()
        debounceTimer = nil
        for source in watchers.values { source.cancel() }
        watchers.removeAll()
    }

    deinit {
        stopWatching()
    }
}
