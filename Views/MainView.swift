import SwiftUI
import AppKit

struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var showingFolders = false
    @State private var sidebarCollapsed = false
    @State private var outlineCollapsed = false
    @State private var quickCapture = ""

    var body: some View {
        ZStack {
            WindowChrome(material: .hudWindow)
                .ignoresSafeArea()
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            if app.vaultStore.vaultURL == nil {
                OnboardingView()
                    .preferredColorScheme(.dark)
            } else {
                VStack(spacing: 0) {
                    topControlBar

                    HStack(spacing: 0) {
                        // 图标轨常驻：sidebar.left 只控制笔记列表，不参与折叠动画，
                        // fixedSize + zIndex 防止 SwiftUI 在条件视图切换时压缩或覆盖它。
                        DarkRailView(
                            showingFolders: $showingFolders,
                            sidebarCollapsed: $sidebarCollapsed
                        )
                        .fixedSize(horizontal: true, vertical: false)
                        .zIndex(1)

                        if !sidebarCollapsed {
                            leftPanel
                                .frame(width: 280)
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(.white.opacity(0.08))
                                        .frame(width: 1)
                                }
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }

                        WorkspaceView()
                            .padding(.leading, sidebarCollapsed ? 22 : 18)
                            .padding(.trailing, 18)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if !outlineCollapsed {
                            outlinePanel
                                .frame(width: 244)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(.white.opacity(0.08))
                                        .frame(width: 1)
                                }
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .ignoresSafeArea(.container, edges: .top)
                .preferredColorScheme(.dark)

                overlayLayer
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = app.vaultStore.errorMessage ?? app.editor.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(message)
                    Spacer()
                    Button {
                        app.vaultStore.errorMessage = nil
                        app.editor.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.red.opacity(0.24))
            }
        }
        .animation(.easeOut(duration: 0.16), value: app.activeOverlay)
        .benOverlayScrollbars(trigger: app.editor.currentNote)
    }

    /// 36pt 顶部安全区：透出 WindowChrome 的磨砂外壳，无边框、无分割线。
    /// 原生红绿灯保持系统原尺寸，下方所有内容从这条带子以下开始排列。
    private var topControlBar: some View {
        HStack(spacing: 0) {
            // 红绿灯中心约在 x=19/39/59、直径 12pt，绿灯右缘约 x=65；
            // 再右移 16pt 安放常驻的列表开关，因此 leading 取 80pt。
            Color.clear.frame(width: 80)

            topToggleButton(symbol: "sidebar.left", help: "收起／展开笔记列表（左侧图标轨常驻）") {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed.toggle() }
            }

            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            topToggleButton(symbol: "sidebar.right", help: "展开／收起本文大纲") {
                withAnimation(.easeInOut(duration: 0.18)) { outlineCollapsed.toggle() }
            }
            .padding(.trailing, 16)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .foregroundStyle(.white)
    }

    private func topToggleButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var leftPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentViewTitle)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    Text("\(app.vaultStore.vault?.name ?? "本子") · \(app.vaultStore.totalNoteCount) 篇")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if !showingFolders {
                    Menu {
                        ForEach(NoteSortOrder.allCases, id: \.self) { order in
                            Button {
                                app.noteSortOrder = order
                            } label: {
                                if app.noteSortOrder == order {
                                    Label(order.label, systemImage: "checkmark")
                                } else {
                                    Text(order.label)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("列表排序")
                }

            }
            .padding(.horizontal, 15)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if showingFolders {
                FolderSidebarView()
                    .onChange(of: app.currentFolderURL) { _, _ in showingFolders = false }
            } else {
                NoteListView()
            }

            quickCaptureBar
                .padding(.top, 8)
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private var currentViewTitle: String {
        if showingFolders { return "目录" }
        guard let root = app.vaultStore.vaultURL else { return "所有笔记" }
        let folder = app.currentFolderURL ?? root
        if AppState.isSameDirectory(folder, root) {
            return "所有笔记"
        }
        return folder.lastPathComponent
    }

    private var quickCaptureBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            DarkPlainTextField(
                placeholder: "快速记入 Inbox…",
                text: $quickCapture,
                fontSize: 12,
                onSubmit: submitQuickCapture
            )
            .frame(height: 18)

            HStack(spacing: 5) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("00 Inbox.md")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
                Button(action: submitQuickCapture) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .help("追加到 Inbox (Return)")
            }
        }
        .padding(11)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.10), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var outlinePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("本文大纲", systemImage: "list.bullet.indent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
            }
            .padding(.horizontal, 15)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            DocumentOutlineView(embedded: true)
                .padding(.horizontal, 8)
                .padding(.top, 8)
        }
        .foregroundStyle(.white.opacity(0.86))
    }

    private func submitQuickCapture() {
        guard !quickCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        app.quickAppendToInbox(quickCapture)
        quickCapture = ""
    }

    @ViewBuilder
    private var overlayLayer: some View {
        switch app.activeOverlay {
        case .search:
            ZStack(alignment: .top) {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { app.dismissOverlay() }
                SearchPanelView().padding(.top, 48).transition(.move(edge: .top).combined(with: .opacity))
            }
        case .quickSwitcher:
            ZStack(alignment: .top) {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { app.dismissOverlay() }
                QuickSwitcherView().padding(.top, 48).transition(.move(edge: .top).combined(with: .opacity))
            }
        case .findReplace:
            FindReplacePanelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 48)
                .padding(.trailing, outlineCollapsed ? 56 : 272)
        case .outline:
            EmptyView()
        case nil:
            EmptyView()
        }
    }
}

/// 顶部控制带中间的窗口拖拽热区。SwiftUI 的 hosting view 默认不参与窗口拖动，
/// 这里用原生 NSView 显式开启 mouseDownCanMoveWindow，保证空白区可直接拖拽窗口。
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
