import SwiftUI

/// 左侧笔记列表栏：展示选中目录下的笔记卡片（标题 + 相对时间 + 清洗后摘要），支持过滤、排序、重命名与安全删除。
struct NoteListView: View {
    @Environment(AppState.self) private var app
    @AppStorage("hideMarkdownExtension") private var hideMarkdownExtension = true
    @State private var filterText = ""
    @State private var renameTarget: NoteFile?
    @State private var renameText = ""
    @State private var deleteTarget: NoteFile?

    private var notes: [NoteFile] {
        var base = app.vaultStore.notes(in: app.currentFolderURL)
        if app.noteSortOrder == .title {
            base.sort {
                $0.displayTitle(hideExtension: hideMarkdownExtension)
                    .localizedStandardCompare($1.displayTitle(hideExtension: hideMarkdownExtension)) == .orderedAscending
            }
        }
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
                VStack(spacing: 10) {
                    Image(systemName: filterText.isEmpty ? "note.text" : "magnifyingglass")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.42))
                    Text(filterText.isEmpty ? "没有笔记" : "没有匹配的笔记")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                    if filterText.isEmpty {
                        Text("在这个文件夹中新建一篇 Markdown 笔记。")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                        Button {
                            app.createNoteInCurrentFolder()
                        } label: {
                            Text("新建笔记")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(notes) { note in
                            NoteListRow(
                                note: note,
                                title: note.displayTitle(hideExtension: hideMarkdownExtension),
                                dateText: Self.relativeDate(note.modifiedDate),
                                folderBadge: isShowingAllNotes ? parentFolderBadge(for: note.url) : nil,
                                isSelected: AppState.isSameDirectory(app.editor.currentNote, note.url)
                            ) {
                                app.selectNote(note.url, preserveFolder: true)
                            }
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
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var isShowingAllNotes: Bool {
        guard let root = app.vaultStore.vaultURL else { return true }
        return AppState.isSameDirectory(app.currentFolderURL ?? root, root)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.white.opacity(0.5))
                .font(.system(size: 12))

            DarkPlainTextField(
                placeholder: "筛选当前列表…",
                text: $filterText,
                fontSize: 12
            )
            .frame(height: 17)

            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.55))
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func parentFolderBadge(for url: URL) -> String? {
        guard let root = app.vaultStore.vaultURL else { return nil }
        let parent = url.deletingLastPathComponent()
        guard !AppState.isSameDirectory(parent, root) else { return nil }
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

private struct NoteListRow: View {
    let note: NoteFile
    let title: String
    let dateText: String
    let folderBadge: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(dateText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.56))
                        .monospacedDigit()
                    Text(note.previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                if let folderBadge {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(folderBadge)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.white.opacity(0.14)
                    : (isHovered ? Color.white.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
