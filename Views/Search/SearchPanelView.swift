import SwiftUI

struct SearchPanelView: View {
    @Environment(AppState.self) private var app
    @AppStorage("hideMarkdownExtension") private var hideMarkdownExtension = true
    @FocusState private var isFocused: Bool
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("全库全文搜索…", text: searchQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                    .onSubmit { openSelectedHit() }
                    .onKeyPress(.downArrow) {
                        guard !app.search.results.isEmpty else { return .ignored }
                        selectedIndex = min(selectedIndex + 1, app.search.results.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !app.search.results.isEmpty else { return .ignored }
                        selectedIndex = max(0, selectedIndex - 1)
                        return .handled
                    }
                if !app.search.query.isEmpty {
                    Button {
                        app.search.clear()
                        selectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button("关闭") { app.dismissOverlay() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .controlSize(.small)
            }

            HStack(spacing: 16) {
                Toggle("区分大小写", isOn: caseSensitive)
                    .toggleStyle(.checkbox)
                Toggle("全词匹配", isOn: wholeWord)
                    .toggleStyle(.checkbox)
                Spacer()
                if !app.search.query.isEmpty {
                    Text("\(app.search.results.count) 条结果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.callout)

            Divider()

            if app.search.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(app.search.query.isEmpty ? "输入关键词检索所有笔记（↑↓ 选择，回车跳转）" : "没有找到匹配内容")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(app.search.results.enumerated()), id: \.element.id) { index, hit in
                                SearchResultRow(
                                    hit: hit,
                                    hideExtension: hideMarkdownExtension,
                                    isSelected: index == selectedIndex
                                ) {
                                    app.jump(to: hit)
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
        .padding(16)
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
        .onAppear { isFocused = true }
        .task(id: app.search.query) {
            selectedIndex = 0
            guard !app.search.query.isEmpty else {
                app.search.results = []
                return
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            app.search.run(in: app.vaultStore.vaultURL)
        }
        .onChange(of: app.search.isCaseSensitive) { _, _ in
            selectedIndex = 0
            app.search.run(in: app.vaultStore.vaultURL)
        }
        .onChange(of: app.search.isWholeWord) { _, _ in
            selectedIndex = 0
            app.search.run(in: app.vaultStore.vaultURL)
        }
    }

    private func openSelectedHit() {
        guard app.search.results.indices.contains(selectedIndex) else { return }
        app.jump(to: app.search.results[selectedIndex])
    }

    private var searchQuery: Binding<String> {
        Binding(get: { app.search.query }, set: { app.search.query = $0 })
    }
    private var caseSensitive: Binding<Bool> {
        Binding(get: { app.search.isCaseSensitive }, set: { app.search.isCaseSensitive = $0 })
    }
    private var wholeWord: Binding<Bool> {
        Binding(get: { app.search.isWholeWord }, set: { app.search.isWholeWord = $0 })
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let hideExtension: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let title = hideExtension
            ? hit.url.deletingPathExtension().lastPathComponent
            : hit.url.lastPathComponent

        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("第 \(hit.lineNumber) 行")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                highlightedLine(hit)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var backgroundStyle: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    private func highlightedLine(_ hit: SearchHit) -> Text {
        let line = hit.line
        let range = hit.matchRange
        return Text(line[..<range.lowerBound].trimmingCharacters(in: .whitespaces))
            + Text(line[range]).bold().foregroundStyle(Color.accentColor)
            + Text(line[range.upperBound...])
    }
}
