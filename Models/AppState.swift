import Foundation
import Observation
import SwiftUI

enum ActiveOverlay: Equatable {
    case search
    case quickSwitcher
    case findReplace
    case outline
}

enum NoteSortOrder: String, CaseIterable {
    case modifiedDate
    case title

    var label: String {
        switch self {
        case .modifiedDate: return "按修改时间"
        case .title: return "按标题名称"
        }
    }
}

/// 应用级状态：把仓库、编辑、搜索与浮层状态统一串联。
@Observable
final class AppState {
    let vaultStore = VaultStore()
    let editor = EditorState()
    let search = SearchService()

    var activeOverlay: ActiveOverlay?
    var isRenamingCurrentNote = false
    var currentFolderURL: URL?
    var noteSortOrder: NoteSortOrder = .modifiedDate

    static func isSameDirectory(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // 注意：@Observable 类里直接读写 UserDefaults，避免与宏合成冲突。
    var vaultPath: String {
        get { UserDefaults.standard.string(forKey: "vaultPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vaultPath") }
    }

    private(set) var recentVaultPaths: [String] = []
    /// 视图重建可能让 onAppear 多次触发，启动扫描必须只执行一次。
    private var didBootstrap = false

    var recentVaultURLs: [URL] {
        recentVaultPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { Vault.isValid($0) }
    }

    init() {
        recentVaultPaths = UserDefaults.standard.stringArray(forKey: "recentVaultPaths") ?? []

        vaultStore.onVaultChanged = { [weak self] url in
            guard let self else { return }
            self.vaultPath = url?.path ?? ""
            if let url {
                self.currentFolderURL = url
                self.recordRecentVault(url)
            }
        }
        vaultStore.onFilesChanged = { [weak self] in
            self?.editor.reloadFromDiskIfNeeded()
        }
        editor.onDidSave = { [weak self] in
            // 保存后延迟刷新摘要与修改时间
            self?.vaultStore.refresh()
        }
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard !vaultPath.isEmpty else { return }
        let url = URL(fileURLWithPath: vaultPath)
        guard Vault.isValid(url) else {
            vaultPath = ""
            return
        }
        // 与「选择文件夹」共用同一套异步扫描路径，避免两套逻辑互相覆盖状态。
        DispatchQueue.main.async { [weak self] in
            _ = self?.vaultStore.open(url: url)
        }
    }

    func checkVaultHealth() {
        vaultStore.checkHealth()
    }

    // MARK: - 浮层控制（严格互斥）

    func toggleOverlay(_ target: ActiveOverlay) {
        if activeOverlay == target {
            activeOverlay = nil
        } else {
            activeOverlay = target
        }
    }

    func presentOverlay(_ target: ActiveOverlay) {
        activeOverlay = target
    }

    func dismissOverlay() {
        activeOverlay = nil
    }

    // MARK: - 本子与文件管理

    func openVault() {
        guard !editor.isDirty || editor.save() else { return }
        let previousVault = vaultStore.vaultURL
        vaultStore.chooseVault()
        if vaultStore.vaultURL != previousVault {
            editor.clear()
            dismissOverlay()
        }
    }

    func openRecentVault(_ url: URL) {
        guard vaultStore.vaultURL?.standardizedFileURL != url.standardizedFileURL else { return }
        guard !editor.isDirty || editor.save() else { return }
        if vaultStore.open(url: url) {
            editor.clear()
            dismissOverlay()
        }
    }

    private func recordRecentVault(_ url: URL) {
        let path = url.standardizedFileURL.path
        var list = recentVaultPaths.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > 6 { list = Array(list.prefix(6)) }
        recentVaultPaths = list
        UserDefaults.standard.set(list, forKey: "recentVaultPaths")
    }

    /// 切换笔记前先保存当前内容，避免切换时丢失未保存修改。
    func selectNote(_ url: URL, preserveFolder: Bool = false) {
        guard editor.currentNote?.standardizedFileURL != url.standardizedFileURL else { return }
        guard !editor.isDirty || editor.save() else { return }
        editor.load(url)
        if !preserveFolder, FileManager.default.fileExists(atPath: url.path) {
            // 若当前处于「所有笔记」视图，保持「所有笔记」不强制跳目录；否则同步到所属文件夹
            if let root = vaultStore.vaultURL,
               !Self.isSameDirectory(currentFolderURL, root) {
                currentFolderURL = url.deletingLastPathComponent()
            }
        }
    }

    func createNoteInCurrentFolder() {
        guard let root = vaultStore.vaultURL else { return }
        let folder = currentFolderURL ?? root
        guard let url = vaultStore.createNote(in: folder) else { return }
        selectNote(url, preserveFolder: true)
    }

    /// Appends a quick-capture line to the vault's canonical Inbox note.
    func quickAppendToInbox(_ rawText: String, createIfMissing: Bool = false) {
        guard let root = vaultStore.vaultURL else { return }
        let content = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || createIfMissing else { return }
        let inboxURL = vaultStore.allNotes().first(where: { $0.name == "00 Inbox.md" })?.url
            ?? root.appendingPathComponent("00 Inbox.md")
        do {
            if !FileManager.default.fileExists(atPath: inboxURL.path) {
                try "".write(to: inboxURL, atomically: true, encoding: .utf8)
            }
            if !content.isEmpty {
                let isOpenInbox = editor.currentNote?.standardizedFileURL == inboxURL.standardizedFileURL
                var existing = isOpenInbox ? editor.text : ((try? String(contentsOf: inboxURL, encoding: .utf8)) ?? "")
                if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
                existing += content + "\n"
                if isOpenInbox {
                    editor.updateTextFromUser(existing)
                    _ = editor.save()
                } else {
                    try existing.write(to: inboxURL, atomically: true, encoding: .utf8)
                }
            }
            vaultStore.refresh()
        } catch {
            editor.errorMessage = "追加到 Inbox 失败：\(error.localizedDescription)"
        }
    }

    func createFolderInCurrentLocation(parent: URL? = nil) {
        guard let root = vaultStore.vaultURL else { return }
        let targetParent = parent ?? currentFolderURL ?? root
        if let created = vaultStore.createFolder(in: targetParent) {
            currentFolderURL = created
        }
    }

    /// 统一处理笔记或文件夹重命名，同步修复打开中的笔记路径和选中目录路径。
    @discardableResult
    func renameItem(_ url: URL, to newName: String, isDirectory: Bool) -> URL? {
        if !isDirectory && editor.currentNote?.standardizedFileURL == url.standardizedFileURL && editor.isDirty {
            _ = editor.save()
        }
        guard let renamedURL = vaultStore.rename(url, to: newName, isDirectory: isDirectory) else {
            return nil
        }
        let oldStd = url.standardizedFileURL.path

        if let openURL = editor.currentNote?.standardizedFileURL {
            if openURL.path == oldStd {
                editor.currentNote = renamedURL
            } else if isDirectory && openURL.path.hasPrefix(oldStd + "/") {
                let suffix = String(openURL.path.dropFirst(oldStd.count + 1))
                editor.currentNote = renamedURL.appendingPathComponent(suffix)
            }
        }

        if let folderURL = currentFolderURL?.standardizedFileURL {
            if folderURL.path == oldStd {
                currentFolderURL = renamedURL
            } else if isDirectory && folderURL.path.hasPrefix(oldStd + "/") {
                let suffix = String(folderURL.path.dropFirst(oldStd.count + 1))
                currentFolderURL = renamedURL.appendingPathComponent(suffix)
            }
        }
        return renamedURL
    }

    /// 统一处理笔记或文件夹移入废纸篓，清理已失效的选中状态。
    func deleteItem(_ url: URL) {
        let deletedStd = url.standardizedFileURL.path
        guard vaultStore.delete(url) else { return }

        if let openPath = editor.currentNote?.standardizedFileURL.path,
           openPath == deletedStd || openPath.hasPrefix(deletedStd + "/") {
            editor.clear()
        }
        if let folderPath = currentFolderURL?.standardizedFileURL.path,
           folderPath == deletedStd || folderPath.hasPrefix(deletedStd + "/") {
            currentFolderURL = vaultStore.vaultURL
        }
    }

    func jump(to hit: SearchHit) {
        selectNote(hit.url, preserveFolder: true)
        let offset = editor.frontmatterLineOffset
        if offset > 0 && hit.lineNumber <= offset {
            editor.isFrontmatterExpanded = true
            editor.highlightedLine = nil
            editor.highlightedQuery = ""
            dismissOverlay()
            return
        }
        let bodyLine = max(1, hit.lineNumber - offset)
        let nsLine = hit.line as NSString
        let matchNSRange = NSRange(hit.matchRange, in: hit.line)
        editor.highlightedLine = bodyLine
        editor.highlightedQuery = search.query
        editor.scrollRequest = EditorState.ScrollRequest(
            url: hit.url,
            line: bodyLine,
            column: matchNSRange.location != NSNotFound ? matchNSRange.location : 0,
            length: matchNSRange.location != NSNotFound ? min(matchNSRange.length, nsLine.length) : 0,
            showFindIndicator: true
        )
        dismissOverlay()
    }
}
