import AppKit

extension Notification.Name {
    static let benMarkdownImageDidLoad = Notification.Name("ben.markdownImageDidLoad")
}

enum MarkdownImageLoadState: Hashable {
    case loaded(NSImage, NSSize)
    case loading
    case missing

    static func == (lhs: MarkdownImageLoadState, rhs: MarkdownImageLoadState) -> Bool {
        switch (lhs, rhs) {
        case let (.loaded(imgA, sizeA), .loaded(imgB, sizeB)):
            return imgA === imgB && sizeA == sizeB
        case (.loading, .loading), (.missing, .missing):
            return true
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let (.loaded(img, size)):
            hasher.combine(0)
            hasher.combine(ObjectIdentifier(img))
            hasher.combine(size.width)
            hasher.combine(size.height)
        case .loading:
            hasher.combine(1)
        case .missing:
            hasher.combine(2)
        }
    }
}

struct BenRenderedImageItem: Hashable {
    let alt: String
    let source: String
    let title: String?
    let preferredMaxWidth: CGFloat?
    let state: MarkdownImageLoadState
}

struct BenImageLayoutSpec: Hashable {
    let items: [BenRenderedImageItem]
    let isStandaloneLine: Bool
    let isLineActive: Bool

    /// 计算该行图片区域所需的总垂直高度（含上下间距与可选图注）。
    func totalBlockHeight(availableWidth: CGFloat) -> CGFloat {
        let safeWidth = max(120, availableWidth)
        return items.reduce(0) { sum, item in
            sum + Self.itemHeight(for: item, availableWidth: safeWidth)
        }
    }

    static func displaySize(for pixelSize: NSSize, preferredMaxWidth: CGFloat?, availableWidth: CGFloat) -> NSSize {
        let maxW = min(availableWidth, preferredMaxWidth ?? min(availableWidth, 680))
        let maxH: CGFloat = 460
        let w = max(1, pixelSize.width)
        let h = max(1, pixelSize.height)
        let scale = min(1.0, min(maxW / w, maxH / h))
        return NSSize(width: round(w * scale), height: round(h * scale))
    }

    static func itemHeight(for item: BenRenderedImageItem, availableWidth: CGFloat) -> CGFloat {
        switch item.state {
        case .loaded(_, let size):
            let fitted = displaySize(for: size, preferredMaxWidth: item.preferredMaxWidth, availableWidth: availableWidth)
            let captionText = item.alt.isEmpty ? (item.title ?? "") : item.alt
            let captionHeight: CGFloat = captionText.isEmpty ? 0 : 20
            return fitted.height + captionHeight + 14
        case .loading, .missing:
            return 52
        }
    }
}

/// 负责解析 Markdown / WikiLink 图片路径（相对当前笔记目录、相对本子根目录、本子内同名附件、绝对路径与远程 URL）并缓存 `NSImage`。
final class MarkdownImageLoader {
    static let shared = MarkdownImageLoader()

    private let imageCache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var inFlightRemoteURLs: Set<String> = []
    private var failedRemoteURLs: Set<String> = []

    private init() {
        imageCache.countLimit = 128
    }

    func resolveImage(source rawSource: String, noteURL: URL?, vaultURL: URL?) -> MarkdownImageLoadState {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }

        // 1. 远程 HTTP / HTTPS 图片异步加载与内存缓存
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            let cacheKey = trimmed as NSString
            if let cached = imageCache.object(forKey: cacheKey) {
                return .loaded(cached, Self.logicalSize(of: cached))
            }
            lock.lock()
            let alreadyFailed = failedRemoteURLs.contains(trimmed)
            let alreadyLoading = inFlightRemoteURLs.contains(trimmed)
            if !alreadyFailed && !alreadyLoading, let url = URL(string: trimmed) {
                inFlightRemoteURLs.insert(trimmed)
                lock.unlock()
                fetchRemoteImage(url: url, key: trimmed)
                return .loading
            }
            lock.unlock()
            return alreadyFailed ? .missing : .loading
        }

        // 2. Data URI Base64 内嵌图片支持（如 `data:image/png;base64,...`）
        if trimmed.lowercased().hasPrefix("data:image/"),
           let commaIndex = trimmed.firstIndex(of: ",") {
            let cacheKey = String(trimmed.prefix(96) + "_\(trimmed.count)") as NSString
            if let cached = imageCache.object(forKey: cacheKey) {
                return .loaded(cached, Self.logicalSize(of: cached))
            }
            let base64Part = String(trimmed[trimmed.index(after: commaIndex)...])
            if let data = Data(base64Encoded: base64Part, options: .ignoreUnknownCharacters),
               let img = NSImage(data: data) {
                imageCache.setObject(img, forKey: cacheKey)
                return .loaded(img, Self.logicalSize(of: img))
            }
            return .missing
        }

        // 3. 本地文件 URL / 绝对路径 / 相对路径 / WikiLink 文件名查找
        guard let fileURL = resolveLocalFileURL(trimmed, noteURL: noteURL, vaultURL: vaultURL) else {
            return .missing
        }

        let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let cacheKey = "\(fileURL.path)#\(Int(mtime))" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return .loaded(cached, Self.logicalSize(of: cached))
        }

        guard let image = NSImage(contentsOf: fileURL), image.isValid else {
            return .missing
        }
        imageCache.setObject(image, forKey: cacheKey)
        return .loaded(image, Self.logicalSize(of: image))
    }

    private func resolveLocalFileURL(_ raw: String, noteURL: URL?, vaultURL: URL?) -> URL? {
        let fm = FileManager.default
        let candidatesStrings: [String] = {
            if let decoded = raw.removingPercentEncoding, decoded != raw {
                return [raw, decoded]
            }
            return [raw]
        }()

        for candidate in candidatesStrings {
            // file:// scheme
            if candidate.lowercased().hasPrefix("file://"),
               let url = URL(string: candidate),
               fm.fileExists(atPath: url.path) {
                return url
            }

            // 绝对路径或 ~ 路径
            if candidate.hasPrefix("/") || candidate.hasPrefix("~") {
                let expanded = (candidate as NSString).expandingTildeInPath
                if fm.fileExists(atPath: expanded) {
                    return URL(fileURLWithPath: expanded)
                }
            }

            let cleanedRel = candidate.hasPrefix("./") ? String(candidate.dropFirst(2)) : candidate

            // 相对于当前打开笔记所在文件夹
            if let noteDir = noteURL?.deletingLastPathComponent() {
                let relToNote = noteDir.appendingPathComponent(cleanedRel).standardizedFileURL
                if fm.fileExists(atPath: relToNote.path) {
                    return relToNote
                }
            }

            // 相对于本子（Vault）根目录
            if let root = vaultURL {
                let relToVault = root.appendingPathComponent(cleanedRel).standardizedFileURL
                if fm.fileExists(atPath: relToVault.path) {
                    return relToVault
                }
            }
        }

        // 若是仅写了文件名（如 Obsidian `![[image.png]]` 存放在 assets / attachments 子目录），在本子内按文件名检索
        let targetName = (candidatesStrings.last as NSString?)?.lastPathComponent ?? raw
        if !targetName.isEmpty, let root = vaultURL {
            let commonAssetFolders = ["assets", "Assets", "attachments", "Attachments", "images", "Images", "media", "static"]
            for folder in commonAssetFolders {
                let direct = root.appendingPathComponent(folder).appendingPathComponent(targetName)
                if fm.fileExists(atPath: direct.path) {
                    return direct
                }
                if let noteDir = noteURL?.deletingLastPathComponent() {
                    let nearNote = noteDir.appendingPathComponent(folder).appendingPathComponent(targetName)
                    if fm.fileExists(atPath: nearNote.path) {
                        return nearNote
                    }
                }
            }

            if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator where url.lastPathComponent == targetName {
                    return url
                }
            }
        }

        return nil
    }

    private func fetchRemoteImage(url: URL, key: String) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            var loadedImage: NSImage?
            if let data, let img = NSImage(data: data), img.isValid {
                loadedImage = img
                self.imageCache.setObject(img, forKey: key as NSString)
            }
            self.lock.lock()
            self.inFlightRemoteURLs.remove(key)
            if loadedImage == nil {
                self.failedRemoteURLs.insert(key)
            }
            self.lock.unlock()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .benMarkdownImageDidLoad, object: key)
            }
        }.resume()
    }

    private static func logicalSize(of image: NSImage) -> NSSize {
        if image.size.width > 1 && image.size.height > 1 {
            return image.size
        }
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return NSSize(width: 320, height: 200)
    }
}
