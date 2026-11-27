import SwiftUI
import AppKit

struct WorkspaceView: View {
    @Environment(AppState.self) private var app
    @State private var pendingClose = false
    @State private var renameDraft = ""

    private static let inkCharcoal = Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0)

    var body: some View {
        VStack(spacing: 0) {
            paperToolbar
            if app.editor.currentNote == nil {
                emptyState
            } else {
                MarkdownEditorView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(minWidth: 500, minHeight: 360)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .environment(\.colorScheme, .light)
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

    private var paperToolbar: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 18) {
                ForEach([EditorMode.wysiwyg, .source], id: \.self) { mode in
                    Button { app.editor.mode = mode } label: {
                        VStack(spacing: 7) {
                            Text(mode == .wysiwyg ? "所见即所得" : "源码")
                                .font(.system(size: 12, weight: app.editor.mode == mode ? .semibold : .regular))
                                .foregroundStyle(app.editor.mode == mode ? Self.inkCharcoal : Color.secondary)
                            Capsule().fill(app.editor.mode == mode ? Self.inkCharcoal : .clear).frame(height: 2)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.editor.currentNote == nil)
                }
            }
            Spacer(minLength: 10)
            Text(app.editor.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 10)
            Button { app.presentOverlay(.findReplace) } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .buttonStyle(.plain).help("文内查找与替换 (⌘F)")
            .disabled(app.editor.currentNote == nil)
            Button(action: exportPDF) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain).help("导出 PDF")
            .disabled(app.editor.currentNote == nil)
            Button { app.createNoteInCurrentFolder() } label: {
                Text("新建")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Self.inkCharcoal, in: Capsule())
            }
            .buttonStyle(.plain).help("新建笔记 (⌘N)")
        }
        .padding(.horizontal, 2)
        .padding(.top, 3)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1) }
    }

    private func exportPDF() {
        guard let noteURL = app.editor.currentNote else { return }
        // 直接打印编辑器当前渲染出的视图，而不是用系统 Markdown 解析器从源码重新生成：
        // 后者会丢掉所见即所得下的隐藏语法、圆点列表、分割线、代码块底板与 frontmatter 属性栏。
        guard let editorView = BenEditorViewRegistry.current else {
            app.editor.errorMessage = "无法导出 PDF：编辑器尚未就绪，请稍后再试。"
            return
        }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let operation = NSPrintOperation(view: editorView, printInfo: printInfo)
        operation.jobTitle = noteURL.deletingPathExtension().lastPathComponent
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
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
        .background(Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1) }
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
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(Self.inkCharcoal, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    app.presentOverlay(.quickSwitcher)
                } label: {
                    Label("快速打开 (⌘O)", systemImage: "magnifyingglass")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Self.inkCharcoal.opacity(0.84))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.05), in: Capsule())
                        .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
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
