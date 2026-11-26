import Foundation

/// 一个「本子」= 磁盘上的一个本地文件夹。
struct Vault {
    let url: URL

    var name: String { url.lastPathComponent }

    static func isValid(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
