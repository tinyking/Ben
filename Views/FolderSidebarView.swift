import SwiftUI

/// 类 Apple 备忘录左侧文件夹栏：支持全部笔记统计、多级目录展开、新建子文件夹、重命名与移入废纸篓。
struct FolderSidebarView: View {
    @Environment(AppState.self) private var app
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @State private var deleteTarget: URL?

    private var folders: [NoteFile] {
        app.vaultStore.tree.compactMap(Self.folderOnly)
    }

    var body: some View {
        List(selection: Binding(
            get: { app.currentFolderURL },
            set: { if let url = $0 { app.currentFolderURL = url } }
        )) {
            if let root = app.vaultStore.vaultURL {
                Section {
                    HStack {
                        Label("所有笔记", systemImage: "tray.full")
                        Spacer(minLength: 6)
                        Text("\(app.vaultStore.totalNoteCount)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.56))
                            .monospacedDigit()
                    }
                    .tag(root)
                    .contextMenu {
                        Button("在根目录新建笔记") {
                            app.currentFolderURL = root
                            app.createNoteInCurrentFolder()
                        }
                        Button("新建文件夹") {
                            app.createFolderInCurrentLocation(parent: root)
                        }
                        Divider()
                        Button("在 Finder 中显示") {
                            app.vaultStore.revealInFinder(root)
                        }
                    }
                }
            }

            Section {
                if folders.isEmpty {
                    Text("尚无子文件夹")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    OutlineGroup(folders, children: \.children) { folder in
                        folderRow(folder)
                            .tag(folder.url)
                    }
                }
            } header: {
                HStack {
                    Text("文件夹")
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button {
                        app.createFolderInCurrentLocation(parent: app.vaultStore.vaultURL)
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("新建文件夹 (⌘⇧N)")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 8)
        }
        .foregroundStyle(.white.opacity(0.86))
        .onAppear {
            if app.currentFolderURL == nil {
                app.currentFolderURL = app.vaultStore.vaultURL
            }
        }
        .onChange(of: app.vaultStore.vaultURL) { _, url in
            app.currentFolderURL = url
        }
        .alert("重命名文件夹", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("文件夹名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("重命名") {
                if let target = renameTarget {
                    app.renameItem(target, to: renameText, isDirectory: true)
                }
                renameTarget = nil
            }
        }
        .alert("删除文件夹", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("移到废纸篓", role: .destructive) {
                if let target = deleteTarget {
                    app.deleteItem(target)
                }
                deleteTarget = nil
            }
        } message: {
            Text("文件夹「\(deleteTarget?.lastPathComponent ?? "")」及其内部笔记会被移到系统废纸篓。")
        }
    }

    private func folderRow(_ folder: NoteFile) -> some View {
        HStack {
            Label(folder.name, systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 6)
            if folder.directNoteCount > 0 {
                Text("\(folder.directNoteCount)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.56))
                    .monospacedDigit()
            }
        }
        .contextMenu {
            Button("在此新建笔记") {
                app.currentFolderURL = folder.url
                app.createNoteInCurrentFolder()
            }
            Button("新建子文件夹") {
                app.createFolderInCurrentLocation(parent: folder.url)
            }
            Divider()
            Button("重命名…") {
                renameTarget = folder.url
                renameText = folder.name
            }
            Button("在 Finder 中显示") {
                app.vaultStore.revealInFinder(folder.url)
            }
            Divider()
            Button("删除（移到废纸篓）…", role: .destructive) {
                deleteTarget = folder.url
            }
        }
    }

    private static func folderOnly(_ node: NoteFile) -> NoteFile? {
        guard node.isDirectory else { return nil }
        let subFolders = (node.children ?? []).compactMap(folderOnly)
        return NoteFile(
            url: node.url,
            isDirectory: true,
            modifiedDate: node.modifiedDate,
            directNoteCount: node.directNoteCount,
            children: subFolders.isEmpty ? nil : subFolders
        )
    }
}
