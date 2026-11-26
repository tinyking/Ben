import Foundation

/// 仓库文件树中的一个节点：可以是文件夹，也可以是一篇 `.md` 笔记。
struct NoteFile: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let modifiedDate: Date?
    let previewText: String
    let directNoteCount: Int
    var children: [NoteFile]?

    init(
        url: URL,
        isDirectory: Bool,
        modifiedDate: Date? = nil,
        previewText: String = "",
        directNoteCount: Int = 0,
        children: [NoteFile]? = nil
    ) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.modifiedDate = modifiedDate
        self.previewText = previewText
        self.directNoteCount = directNoteCount
        self.children = children
    }

    var isMarkdown: Bool {
        !isDirectory && url.pathExtension.lowercased() == "md"
    }

    func displayTitle(hideExtension: Bool) -> String {
        if isMarkdown && hideExtension {
            return url.deletingPathExtension().lastPathComponent
        }
        return name
    }
}
