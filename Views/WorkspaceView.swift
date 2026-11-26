import SwiftUI
import AppKit

struct WorkspaceView: View {
    @Environment(AppState.self) private var app
    @State private var pendingClose = false
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            if app.editor.currentNote == nil {
                emptyState
            } else {
                MarkdownEditorView()
                statusBar
            }
        }
        .frame(minWidth: 440, minHeight: 340)
        .navigationTitle(app.editor.displayName)
        .navigationSubtitle(noteSubtitle)
        .background(WindowCloseGuard(
            isDirty: app.editor.isDirty,
            onCloseAttempt: { pendingClose = true }
        ))
        .alert("重命名笔记", isPresented: Binding(
            get: { app.isRenamingCurrentNote },
            set: { if !$0 { app.isRenamingCurrentNote = false } }
        )) {
            TextField("笔记名称", text: $renameDraft)
            Button("取消", role: .cancel) { app.isRenamingCurrentNote = false }
            Button("重命名") {
                if let url = app.editor.currentNote {
                    app.renameItem(url, to: renameDraft, isDirectory: false)
                }
                app.isRenamingCurrentNote = false
            }
        }
        .onChange(of: app.isRenamingCurrentNote) { _, presenting in
            if presenting {
                renameDraft = app.editor.displayName
            }
        }
        .alert("有未保存的修改", isPresented: $pendingClose) {
            Button("保存") {
                if app.editor.save() { closeWindow() }
            }
            Button("放弃", role: .destructive) {
                app.editor.revert()
                closeWindow()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(app.editor.displayName)」尚未保存，是否保存后再关闭？")
        }
    }

    private var noteSubtitle: String {
        guard let noteURL = app.editor.currentNote,
              let rootURL = app.vaultStore.vaultURL else {
            return app.vaultStore.vault?.name ?? ""
        }
        let parent = noteURL.deletingLastPathComponent().standardizedFileURL
        if parent == rootURL.standardizedFileURL {
            return rootURL.lastPathComponent
        }
        return "\(rootURL.lastPathComponent) / \(parent.lastPathComponent)"
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(app.editor.nonWhitespaceCount) 字")
                .monospacedDigit()
            Text("·")
                .foregroundStyle(.quaternary)
            Text("约 \(app.editor.estimatedReadingMinutes) 分钟阅读")
                .monospacedDigit()

            Spacer()

            if app.editor.isDirty {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: 6, height: 6)
                    Text("自动保存中")
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }

            Text("行 \(app.editor.cursorLine)，列 \(app.editor.cursorColumn)")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.easeInOut(duration: 0.2), value: app.editor.isDirty)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.pages")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text("选择或新建一篇笔记")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                Button {
                    app.createNoteInCurrentFolder()
                } label: {
                    Label("新建笔记 (⌘N)", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    app.presentOverlay(.quickSwitcher)
                } label: {
                    Label("快速打开 (⌘O)", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func closeWindow() {
        DispatchQueue.main.async {
            NSApplication.shared.keyWindow?.close()
        }
    }
}

/// 拦截窗口关闭，未保存时先自动尝试保存；仅当磁盘保存失败时弹出确认。
private struct WindowCloseGuard: NSViewRepresentable {
    let isDirty: Bool
    let onCloseAttempt: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.onCloseAttempt = onCloseAttempt
        if nsView.window?.delegate !== context.coordinator {
            nsView.window?.delegate = context.coordinator
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        var isDirty = false
        var onCloseAttempt: () -> Void = {}

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isDirty {
                onCloseAttempt()
                return false
            }
            return true
        }
    }
}
