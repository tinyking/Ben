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
    /// 扫描串行化：同一时刻只允许一次文件树构建，期间的新请求合并为一次重扫。
    private var isScanning = false
    private var needsRescan = false
    private var refreshScheduled = false
    private var watchersActive = false
    private var watchersArmedAt: Date = .distantPast

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
        // 仓库切换立即持久化并同步选中目录，不依赖后台扫描结果。
        onVaultChanged?(url)
        rebuildTree()
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
        let target = folderURL ?? root
        if target.resolvingSymlinksInPath().standardizedFileURL.path
            == root.resolvingSymlinksInPath().standardizedFileURL.path {
            return allNotes()
        }
        guard let folderNode = node(for: target) else { return [] }
        let directNotes = (folderNode.children ?? []).filter(\.isMarkdown)
        return Self.sortNotesByModifiedDate(directNotes)
    }

    /// 串行化后台构建文件树：同一时刻只允许一次扫描，期间的新请求合并为一次重扫，
    /// 避免监听器事件风暴导致多份并发扫描互相丢弃结果、界面始终为空。
    private func rebuildTree() {
        guard let root = vaultURL else {
            tree = []
            totalNoteCount = 0
            needsRescan = false
            return
        }
        if isScanning {
            needsRescan = true
            return
        }
        isScanning = true
        DispatchQueue.global(qos: .utility).async {
            let snapshot = Self.makeTreeSnapshot(at: root)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isScanning = false
                // 仓库未变则一定落地快照；若扫描途中切换了本子，交给后续重扫。
                if self.vaultURL == root {
                    self.tree = snapshot.0
                    self.totalNoteCount = snapshot.1
                    self.installWatchers()
                }
                if self.needsRescan {
                    self.needsRescan = false
                    self.rebuildTree()
                }
            }
        }
    }

    /// 在后台线程构建仓库快照，避免扫描阻塞主线程导致鼠标持续转圈。
    static func makeTreeSnapshot(at root: URL) -> ([NoteFile], Int) {
        let built = buildNodes(at: root)
        return (built, countAllNotes(in: built))
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

    /// 仅剥离首行开始且有闭合标记的合法 YAML Frontmatter，跳过封面/纯图片行，提取第一段真实正文摘要。
    private static func extractPreviewText(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无附加文本" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384) else { return "无附加文本" }
        let rawText = String(decoding: data, as: UTF8.self)
        return extractPreviewSummary(from: rawText)
    }

    static func extractPreviewSummary(from rawText: String) -> String {
        let body = FrontmatterParser.parse(rawText).body
        let lines = body.components(separatedBy: .newlines)
        let codeStates = MarkdownStyler.computeCodeBlockLineStates(in: lines)

        var paragraph: [String] = []
        for (idx, rawLine) in lines.enumerated() {
            if codeStates[idx] != .none {
                if !paragraph.isEmpty { break }
                continue
            }
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if trimmed.range(of: #"^#{1,6}(?:\s|$)"#, options: .regularExpression) != nil
                || trimmed.hasPrefix("<!--")
                || MarkdownStyler.isHorizontalRuleLine(rawLine) {
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
            // 摘要最多只取 240 字，超长行无需整行参与正则处理（同时限制回溯型正则的输入规模）。
            let cleanedLine = stripMarkdownSyntax(String(trimmed.prefix(600)))
            if cleanedLine.isEmpty {
                continue
            }
            paragraph.append(cleanedLine)
        }

        let joined = paragraph.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "无附加文本" : String(joined.prefix(240))
    }

    private static func stripMarkdownSyntax(_ line: String) -> String {
        var s = line
        // 去掉列表/引用/待办前缀
        s = s.replacingOccurrences(of: #"^(?:>\s*)+|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
        // 去掉嵌套图片链接 [![Cover](img)](url)
        // 注意：这里刻意使用不含嵌套量词的线性正则。
        // 形如 (?:[^()]+|\([^()]*\))* 的写法在长行上会触发 ICU 灾难性回溯，实测单次 >20s 无法完成，
        // 会拖垮整个文件树扫描导致界面永远加载不出笔记。
        //
        // 括号处理：目标地址允许一层括号平衡（如 `cover_(hero).jpg`），因此用 `(?:[^()]|\([^()]*\))*`。
        // 该写法每个位置的两个分支按首字符互斥（括号 / 非括号），匹配唯一、无回溯歧义，仍为线性复杂度。
        let balancedParens = #"(?:[^()]|\([^()]*\))*"#
        s = s.replacingOccurrences(
            of: #"\[!\[[^\]]*\]\("# + balancedParens + #"\)\]\("# + balancedParens + #"\)"#,
            with: "", options: .regularExpression
        )
        // 去掉标准 Markdown 图片 ![Cover](url)（不保留 alt 以避免残留 Cover / Image）
        s = s.replacingOccurrences(
            of: #"!\[[^\]]*\]\("# + balancedParens + #"\)"#,
            with: "", options: .regularExpression
        )
        // 去掉 Obsidian WikiLink 图片 ![[cover.png]]
        s = s.replacingOccurrences(of: #"!\[\[[^\[\]]+\]\]"#, with: "", options: .regularExpression)
        // 去掉 HTML <img> 标签
        s = s.replacingOccurrences(of: #"<img\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        // 普通文字链接 [text](url) -> text
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\("# + balancedParens + #"\)"#,
            with: "$1", options: .regularExpression
        )
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
        guard let root = vaultURL else { return }

        var directories: [URL] = [root]
        func collect(_ nodes: [NoteFile]) {
            for node in nodes where node.isDirectory {
                directories.append(node.url)
                if let children = node.children { collect(children) }
            }
        }
        collect(tree)

        // 目录集合未变化时复用已有监听器，避免每次刷新都重装 800+ 个 vnode 源而自触发刷新风暴。
        let desired = Set(directories.map { $0.standardizedFileURL })
        let current = Set(watchers.keys.map { $0.standardizedFileURL })
        if desired == current {
            watchersActive = true
            return
        }
        stopWatching()

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
        watchersActive = true
        watchersArmedAt = Date()
    }

    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.watchersActive else { return }
            // 忽略刚安装监听器时产生的自触发事件。
            guard Date().timeIntervalSince(self.watchersArmedAt) > 1.5 else { return }
            guard !self.refreshScheduled else { return }
            self.refreshScheduled = true
            self.debounceTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.fsQueue)
            timer.schedule(deadline: .now() + 0.4, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshScheduled = false
                    self.rebuildTree()
                    self.onFilesChanged?()
                }
            }
            timer.resume()
            self.debounceTimer = timer
        }
    }

    private func stopWatching() {
        watchersActive = false
        refreshScheduled = false
        debounceTimer?.cancel()
        debounceTimer = nil
        for source in watchers.values { source.cancel() }
        watchers.removeAll()
    }

    deinit {
        stopWatching()
    }
}
