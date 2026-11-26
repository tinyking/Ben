import SwiftUI

/// 类 Apple 备忘录中间笔记列表栏：展示选中目录下的笔记卡片（标题 + 相对时间 + 清洗后摘要），支持过滤、重命名与安全删除。
struct NoteListView: View {
    @Environment(AppState.self) private var app
    @AppStorage("hideMarkdownExtension") private var hideMarkdownExtension = true
    @State private var filterText = ""
    @State private var renameTarget: NoteFile?
    @State private var renameText = ""
    @State private var deleteTarget: NoteFile?

    private var notes: [NoteFile] {
        let base = app.vaultStore.notes(in: app.currentFolderURL)
        let keyword = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return base }
        return base.filter { note in
            note.displayTitle(hideExtension: hideMarkdownExtension).localizedCaseInsensitiveContains(keyword)
                || note.previewText.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            if notes.isEmpty {
                if filterText.isEmpty {
                    ContentUnavailableView {
                        Label("没有笔记", systemImage: "note.text")
                    } description: {
                        Text("在这个文件夹中新建一篇 Markdown 笔记。")
                    } actions: {
                        Button("新建笔记") {
                            app.createNoteInCurrentFolder()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    ContentUnavailableView.search(text: filterText)
                }
            } else {
                List(selection: Binding(
                    get: { app.editor.currentNote },
                    set: { if let url = $0 { app.selectNote(url, preserveFolder: true) } }
                )) {
                    ForEach(notes) { note in
                        noteRow(note)
                            .tag(note.url)
                            .contextMenu {
                                Button("重命名…") {
                                    renameTarget = note
                                    renameText = note.url.deletingPathExtension().lastPathComponent
                                }
                                Button("在 Finder 中显示") {
                                    app.vaultStore.revealInFinder(note.url)
                                }
                                Divider()
                                Button("删除（移到废纸篓）…", role: .destructive) {
                                    deleteTarget = note
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { app.createNoteInCurrentFolder() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("新建笔记 (⌘N)")
            }
        }
        .alert("重命名笔记", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("笔记名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("重命名") {
                if let target = renameTarget {
                    app.renameItem(target.url, to: renameText, isDirectory: false)
                }
                renameTarget = nil
            }
        }
        .alert("删除笔记", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("移到废纸篓", role: .destructive) {
                if let target = deleteTarget {
                    app.deleteItem(target.url)
                }
                deleteTarget = nil
            }
        } message: {
            Text("「\(deleteTarget?.displayTitle(hideExtension: hideMarkdownExtension) ?? "")」会被移到系统废纸篓，可随时从废纸篓恢复。")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))
            TextField("筛选当前列表…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func noteRow(_ note: NoteFile) -> some View {
        let title = note.displayTitle(hideExtension: hideMarkdownExtension)
        let isShowingAllNotes = app.currentFolderURL?.standardizedFileURL == app.vaultStore.vaultURL?.standardizedFileURL

        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.relativeDate(note.modifiedDate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Text(note.previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isShowingAllNotes, let folderName = parentFolderBadge(for: note.url) {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(folderName)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func parentFolderBadge(for url: URL) -> String? {
        guard let root = app.vaultStore.vaultURL?.standardizedFileURL else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent != root else { return nil }
        return parent.lastPathComponent
    }

    private static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: .now)
            ? "MM/dd"
            : "yy/MM/dd"
        return formatter.string(from: date)
    }
}
