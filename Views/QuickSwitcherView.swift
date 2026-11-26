import SwiftUI

struct QuickSwitcherView: View {
    @Environment(AppState.self) private var app
    @AppStorage("hideMarkdownExtension") private var hideMarkdownExtension = true
    @FocusState private var isFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0

    private var notes: [NoteFile] {
        let allNotes = app.vaultStore.allNotes()
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allNotes }
        return allNotes.filter { note in
            note.displayTitle(hideExtension: hideMarkdownExtension).localizedCaseInsensitiveContains(keyword)
                || note.url.deletingLastPathComponent().lastPathComponent.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        let visibleNotes = Array(notes.prefix(50))

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("快速打开笔记…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                    .onSubmit { openSelected(in: visibleNotes) }
                    .onKeyPress(.downArrow) {
                        guard !visibleNotes.isEmpty else { return .ignored }
                        selectedIndex = min(selectedIndex + 1, visibleNotes.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !visibleNotes.isEmpty else { return .ignored }
                        selectedIndex = max(0, selectedIndex - 1)
                        return .handled
                    }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }

                Button("关闭") { app.dismissOverlay() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .controlSize(.small)
            }

            Divider()

            if visibleNotes.isEmpty {
                VStack(spacing: 6) {
                    Text("没有匹配的笔记")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("在当前目录新建「\(query)」") {
                            createAndOpenNamedNote()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(visibleNotes.enumerated()), id: \.element.id) { index, note in
                                QuickSwitcherRow(
                                    title: note.displayTitle(hideExtension: hideMarkdownExtension),
                                    subtitle: relativeFolder(for: note.url),
                                    isSelected: index == selectedIndex
                                ) {
                                    open(note.url)
                                }
                                .id(index)
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
        .onAppear { isFocused = true }
    }

    private func relativeFolder(for url: URL) -> String {
        guard let root = app.vaultStore.vaultURL?.standardizedFileURL else {
            return url.deletingLastPathComponent().lastPathComponent
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent != root else { return "根目录" }
        return String(parent.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func openSelected(in visibleNotes: [NoteFile]) {
        guard visibleNotes.indices.contains(selectedIndex) else { return }
        open(visibleNotes[selectedIndex].url)
    }

    private func open(_ url: URL) {
        app.selectNote(url)
        app.dismissOverlay()
    }

    private func createAndOpenNamedNote() {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let root = app.vaultStore.vaultURL else { return }
        let folder = app.currentFolderURL ?? root
        if let tempURL = app.vaultStore.createNote(in: folder) {
            let finalURL = app.renameItem(tempURL, to: name, isDirectory: false) ?? tempURL
            app.selectNote(finalURL, preserveFolder: true)
        }
        app.dismissOverlay()
    }
}

private struct QuickSwitcherRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct DocumentOutlineView: View {
    @Environment(AppState.self) private var app

    private var activeHeadingLine: Int? {
        let cursor = app.editor.cursorLine
        return app.editor.outline.last(where: { $0.line <= cursor })?.line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("文档大纲", systemImage: "list.bullet.indent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { app.dismissOverlay() } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("关闭大纲 (Esc)")
            }

            Divider()

            if app.editor.outline.isEmpty {
                VStack(spacing: 6) {
                    Text("这篇笔记还没有标题")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("使用 #、##、### 创建章节结构")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(app.editor.outline) { heading in
                            OutlineItemRow(
                                heading: heading,
                                isActive: heading.line == activeHeadingLine
                            ) {
                                if let url = app.editor.currentNote {
                                    app.editor.scrollRequest = EditorState.ScrollRequest(
                                        url: url,
                                        line: heading.line
                                    )
                                }
                                app.dismissOverlay()
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

private struct OutlineItemRow: View {
    let heading: OutlineEntry
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(width: 5, height: 5)
                Text(heading.title)
                    .font(heading.level <= 2 ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 11)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isActive ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
