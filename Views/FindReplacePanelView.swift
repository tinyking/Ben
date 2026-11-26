import SwiftUI

struct FindReplacePanelView: View {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Field?
    private enum Field { case query, replacement }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("查找当前笔记…", text: Binding(
                        get: { app.editor.findQuery },
                        set: { app.editor.updateFindQuery($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($focused, equals: .query)
                    .onSubmit { app.editor.findNext() }

                    if !app.editor.findQuery.isEmpty {
                        Text(matchCountLabel)
                            .font(.caption2)
                            .foregroundStyle(app.editor.findMatches.isEmpty ? Color.red.opacity(0.85) : .secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                Button {
                    app.editor.toggleFindCaseSensitive()
                } label: {
                    Text("Aa")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(app.editor.isFindCaseSensitive ? Color.accentColor : .secondary)
                        .frame(width: 26, height: 24)
                        .background(
                            app.editor.isFindCaseSensitive ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .help("区分大小写")

                HStack(spacing: 2) {
                    Button { app.editor.findPrevious() } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 22, height: 22)
                    }
                    .disabled(app.editor.findMatches.isEmpty)
                    .help("上一个")

                    Button { app.editor.findNext() } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 22, height: 22)
                    }
                    .disabled(app.editor.findMatches.isEmpty)
                    .help("下一个 (Return)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { app.dismissOverlay() } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("关闭查找 (Esc)")
            }

            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("替换为…", text: Binding(
                        get: { app.editor.replaceText },
                        set: { app.editor.replaceText = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($focused, equals: .replacement)
                    .onSubmit { app.editor.replaceCurrent() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                Button("替换") { app.editor.replaceCurrent() }
                    .controlSize(.small)
                    .disabled(app.editor.findMatches.isEmpty)

                Button("全部") { app.editor.replaceAll() }
                    .controlSize(.small)
                    .disabled(app.editor.findMatches.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 410)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .onAppear {
            app.editor.recomputeFindMatches(resetIndex: false)
            focused = .query
        }
    }

    private var matchCountLabel: String {
        let total = app.editor.findMatches.count
        guard total > 0 else { return "无匹配" }
        return "\(app.editor.currentFindMatchIndex + 1)/\(total)"
    }
}
