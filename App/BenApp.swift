import SwiftUI

@main
struct BenApp: App {
    @State private var app = AppState()
    @AppStorage("appearance") private var appearance = 0

    private var colorScheme: ColorScheme? {
        switch appearance {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(app)
                .preferredColorScheme(app.vaultStore.vaultURL == nil ? colorScheme : .dark)
                .onAppear { DispatchQueue.main.async { app.bootstrap() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    app.checkVaultHealth()
                    app.editor.reloadFromDiskIfNeeded()
                }
        }
        .defaultSize(width: 1140, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("本子") {
                Button("打开／切换本子…") { app.openVault() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                if !app.recentVaultURLs.isEmpty {
                    Menu("最近打开的本子") {
                        ForEach(app.recentVaultURLs, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                app.openRecentVault(url)
                            }
                        }
                    }
                }

                Divider()

                Button("新建笔记") { app.createNoteInCurrentFolder() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(app.vaultStore.vaultURL == nil)

                Button("新建文件夹") { app.createFolderInCurrentLocation() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(app.vaultStore.vaultURL == nil)

                Button("重命名当前笔记…") { app.isRenamingCurrentNote = true }
                    .disabled(app.editor.currentNote == nil)

                Button("保存") { app.editor.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(app.editor.currentNote == nil)

                Button("跳到文末并插入今日日期") { app.editor.appendTodayHeading() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(app.editor.currentNote == nil)

                Divider()

                Button("查找与替换当前笔记…") { app.presentOverlay(.findReplace) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(app.editor.currentNote == nil)

                Button("全库全文搜索…") { app.presentOverlay(.search) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(app.vaultStore.vaultURL == nil)

                Button("快速打开笔记…") { app.presentOverlay(.quickSwitcher) }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(app.vaultStore.vaultURL == nil)

                Divider()

                Button("在 Finder 中显示") {
                    if let url = app.editor.currentNote { app.vaultStore.revealInFinder(url) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.editor.currentNote == nil)
            }

            CommandMenu("格式") {
                Button("一级标题") { app.editor.applyFormat(.heading(1)) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    .disabled(app.editor.currentNote == nil)
                Button("二级标题") { app.editor.applyFormat(.heading(2)) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(app.editor.currentNote == nil)
                Button("三级标题") { app.editor.applyFormat(.heading(3)) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                    .disabled(app.editor.currentNote == nil)

                Divider()

                Button("加粗") { app.editor.applyFormat(.bold) }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(app.editor.currentNote == nil)
                Button("斜体") { app.editor.applyFormat(.italic) }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(app.editor.currentNote == nil)
                Button("删除线") { app.editor.applyFormat(.strikethrough) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(app.editor.currentNote == nil)
                Button("高亮标记") { app.editor.applyFormat(.highlight) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(app.editor.currentNote == nil)
                Button("行内代码") { app.editor.applyFormat(.inlineCode) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(app.editor.currentNote == nil)
                Button("插入链接") { app.editor.applyFormat(.link) }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(app.editor.currentNote == nil)

                Divider()

                Button("无序列表") { app.editor.applyFormat(.bulletList) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(app.editor.currentNote == nil)
                Button("待办清单") { app.editor.applyFormat(.todoList) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(app.editor.currentNote == nil)
                Button("切换待办完成状态") { app.editor.applyFormat(.toggleTodo) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(app.editor.currentNote == nil)
                Button("引用") { app.editor.applyFormat(.blockquote) }
                    .disabled(app.editor.currentNote == nil)
                Button("分割线") { app.editor.applyFormat(.divider) }
                    .disabled(app.editor.currentNote == nil)
            }

            CommandMenu("视图") {
                Button("所见即所得") { app.editor.mode = .wysiwyg }
                    .keyboardShortcut("1", modifiers: .command)
                Button("纯源码") { app.editor.mode = .source }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("文档大纲") { app.toggleOverlay(.outline) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(app.editor.currentNote == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
