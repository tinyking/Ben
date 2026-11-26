import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if app.vaultStore.vaultURL == nil {
                OnboardingView()
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    FolderSidebarView()
                        .navigationTitle(app.vaultStore.vault?.name ?? "本子")
                        .navigationSplitViewColumnWidth(min: 175, ideal: 215, max: 280)
                } content: {
                    NoteListView()
                        .navigationTitle(currentFolderTitle)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
                } detail: {
                    WorkspaceView()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if app.recentVaultURLs.count > 1 {
                    Menu {
                        ForEach(app.recentVaultURLs, id: \.path) { url in
                            Button {
                                app.openRecentVault(url)
                            } label: {
                                if url.standardizedFileURL == app.vaultStore.vaultURL?.standardizedFileURL {
                                    Label(url.lastPathComponent, systemImage: "checkmark")
                                } else {
                                    Text(url.lastPathComponent)
                                }
                            }
                        }
                        Divider()
                        Button("打开其他本子文件夹…") { app.openVault() }
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .help("打开／切换本子 (⌘⇧O)")
                } else {
                    Button { app.openVault() } label: {
                        Image(systemName: "books.vertical")
                    }
                    .help("打开／切换本子 (⌘⇧O)")
                }
            }

            if app.vaultStore.vaultURL != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    HStack(spacing: 2) {
                        ForEach(EditorMode.allCases) { mode in
                            EditorModeButton(
                                mode: mode,
                                isSelected: app.editor.mode == mode
                            ) {
                                app.editor.mode = mode
                            }
                            .disabled(app.editor.currentNote == nil)
                        }
                    }
                    .padding(2.5)
                    .background(.quaternary.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))

                    Button { app.toggleOverlay(.search) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("全库全文搜索 (⌘⇧F)")

                    Button { app.toggleOverlay(.findReplace) } label: {
                        Image(systemName: "text.magnifyingglass")
                    }
                    .help("页内查找与替换 (⌘F)")
                    .disabled(app.editor.currentNote == nil)

                    Button { app.toggleOverlay(.outline) } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                    .help("文档大纲 (⌘⌥O)")
                    .disabled(app.editor.currentNote == nil)

                    Menu {
                        Button {
                            app.isRenamingCurrentNote = true
                        } label: {
                            Label("重命名笔记…", systemImage: "pencil")
                        }
                        .disabled(app.editor.currentNote == nil)

                        Button {
                            app.editor.appendTodayHeading()
                        } label: {
                            Label("文末插入今日日期", systemImage: "calendar.badge.plus")
                        }
                        .disabled(app.editor.currentNote == nil)

                        Divider()

                        Button {
                            if let url = app.editor.currentNote {
                                app.vaultStore.revealInFinder(url)
                            }
                        } label: {
                            Label("在 Finder 中显示", systemImage: "arrow.up.forward.app")
                        }
                        .disabled(app.editor.currentNote == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("当前笔记操作")
                    .disabled(app.editor.currentNote == nil)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = app.vaultStore.errorMessage ?? app.editor.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.red.opacity(0.12))
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .overlay {
            overlayLayer
        }
        .animation(.easeOut(duration: 0.16), value: app.activeOverlay)
        .benOverlayScrollbars(trigger: app.editor.currentNote)
    }

    private var currentFolderTitle: String {
        guard let folder = app.currentFolderURL,
              let root = app.vaultStore.vaultURL,
              folder.standardizedFileURL != root.standardizedFileURL else {
            return "所有笔记"
        }
        return folder.lastPathComponent
    }

    @ViewBuilder
    private var overlayLayer: some View {
        switch app.activeOverlay {
        case .search:
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { app.dismissOverlay() }
                SearchPanelView()
                    .padding(.top, 46)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        case .quickSwitcher:
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { app.dismissOverlay() }
                QuickSwitcherView()
                    .padding(.top, 46)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        case .findReplace:
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { app.dismissOverlay() }
                FindReplacePanelView()
                    .padding(.top, 10)
                    .padding(.trailing, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        case .outline:
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.03)
                    .ignoresSafeArea()
                    .onTapGesture { app.dismissOverlay() }
                DocumentOutlineView()
                    .padding(.top, 10)
                    .padding(.trailing, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        case nil:
            EmptyView()
        }
    }
}

private struct EditorModeButton: View {
    let mode: EditorMode
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(mode.shortLabel)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 10)
            .frame(height: 23)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(mode.label) (\(mode == .wysiwyg ? "⌘1" : "⌘2"))")
    }

    private var foregroundStyle: Color {
        guard isSelected else { return .secondary }
        return colorScheme == .dark ? .black.opacity(0.88) : .white
    }

    private var backgroundStyle: Color {
        isSelected ? Color.accentColor : Color.clear
    }
}
