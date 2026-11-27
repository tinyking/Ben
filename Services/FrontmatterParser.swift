import Foundation

struct FrontmatterField: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    /// 供界面展示使用的净值（自动剥离 YAML 首尾包裹的双引号或单引号）。
    var displayValue: String {
        Self.stripSurroundingQuotes(value)
    }

    /// 当属性值为 `http://` 或 `https://` 链接（含被双引号包裹的 YAML 字符串）时返回可跳转 URL。
    var webURL: URL? {
        let clean = displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.lowercased().hasPrefix("http://") || clean.lowercased().hasPrefix("https://") else {
            return nil
        }
        return URL(string: clean) ?? clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    static func stripSurroundingQuotes(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
        }
        if trimmed.hasPrefix("'") && trimmed.hasSuffix("'") {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }
}

struct FrontmatterDocument: Equatable {
    /// 包含首尾 `---`（及闭合行末尾换行符，若原文件存在）的完整原始块，用于未修改属性时字节级无损保存。
    var rawBlock: String
    var fields: [FrontmatterField]
    var isModified: Bool = false

    /// 正文第 1 行相对于完整 `.md` 物理文件的行号偏移量。
    var lineOffset: Int {
        let block = isModified ? Self.serializeHeader(fields: fields) + "\n" : rawBlock
        let newlineCount = block.filter { $0 == "\n" }.count
        return block.hasSuffix("\n") ? newlineCount : (newlineCount + 1)
    }

    static func serializeHeader(fields: [FrontmatterField]) -> String {
        var lines: [String] = ["---"]
        for field in fields {
            let trimmedKey = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            let val = field.value
            if val.contains("\n") {
                lines.append("\(trimmedKey):")
                for item in val.components(separatedBy: "\n") {
                    lines.append(item.hasPrefix("  ") ? item : "  \(item)")
                }
            } else if val.isEmpty {
                lines.append("\(trimmedKey):")
            } else if needsYAMLQuotes(val) {
                let escaped = val.replacingOccurrences(of: "\"", with: "\\\"")
                lines.append("\(trimmedKey): \"\(escaped)\"")
            } else {
                lines.append("\(trimmedKey): \(val)")
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func needsYAMLQuotes(_ val: String) -> Bool {
        let trimmed = val.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("\"") && !trimmed.hasPrefix("'") && !trimmed.hasPrefix("[") else {
            return false
        }
        return trimmed.hasPrefix("#") || trimmed.contains(": ")
    }
}

/// 独立处理 Markdown 文件头部的 YAML Frontmatter，将其与正文彻底解耦并保证无损读写。
enum FrontmatterParser {
    struct ParseResult: Equatable {
        let frontmatter: FrontmatterDocument?
        let body: String
    }

    /// 仅当文件以 `---\n`（或 `---\r\n`）开头且存在合法闭合 `\n---` 行时剥离 Frontmatter。
    static func parse(_ fullText: String) -> ParseResult {
        let openingLength: Int
        if fullText.hasPrefix("---\n") {
            openingLength = 4
        } else if fullText.hasPrefix("---\r\n") {
            openingLength = 5
        } else {
            return ParseResult(frontmatter: nil, body: fullText)
        }

        let ns = fullText as NSString
        let totalLength = ns.length
        var cursor = openingLength
        var yamlLines: [String] = []
        var closingEndLocation: Int?

        while cursor <= totalLength {
            if cursor == totalLength {
                break
            }
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let rawLine = ns.substring(with: lineRange)
            let strippedLine = Self.stripLineEnding(rawLine)

            if strippedLine == "---" || strippedLine.range(of: #"^---[ \t]+$"#, options: .regularExpression) != nil {
                closingEndLocation = lineRange.location + lineRange.length
                break
            }

            yamlLines.append(strippedLine)
            if lineRange.length == 0 { break }
            cursor = lineRange.location + lineRange.length
        }

        guard let splitLocation = closingEndLocation,
              isValidYAMLBlock(yamlLines) else {
            return ParseResult(frontmatter: nil, body: fullText)
        }

        let rawBlock = ns.substring(with: NSRange(location: 0, length: splitLocation))
        let body = ns.substring(from: splitLocation)
        let fields = extractFields(from: yamlLines)

        return ParseResult(
            frontmatter: FrontmatterDocument(rawBlock: rawBlock, fields: fields, isModified: false),
            body: body
        )
    }

    /// 将 Frontmatter 与正文重新拼装为完整 `.md` 文件文本。
    static func compose(frontmatter: FrontmatterDocument?, body: String) -> String {
        guard let frontmatter else { return body }

        if !frontmatter.isModified {
            if !body.isEmpty && !frontmatter.rawBlock.hasSuffix("\n") && !frontmatter.rawBlock.hasSuffix("\r\n") {
                return frontmatter.rawBlock + "\n" + body
            }
            return frontmatter.rawBlock + body
        }

        let header = FrontmatterDocument.serializeHeader(fields: frontmatter.fields)
        if body.isEmpty {
            return header + "\n"
        }
        return header + "\n" + body
    }

    // MARK: - 内部校验与字段解析

    private static func stripLineEnding(_ line: String) -> String {
        var s = line
        if s.hasSuffix("\r\n") {
            s.removeLast(2)
        } else if s.hasSuffix("\n") || s.hasSuffix("\r") {
            s.removeLast()
        }
        return s
    }

    /// 校验候选行集合确实为 YAML 键值结构，避免把「首行分割线 `---` + 普通正文 + 后续分割线 `---`」误判为 Frontmatter。
    private static func isValidYAMLBlock(_ lines: [String]) -> Bool {
        if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return true
        }

        var hasKeyValueLine = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if line.first == " " || line.first == "\t" {
                continue
            }
            if trimmed == "-" || trimmed.hasPrefix("- ") {
                continue
            }
            if isTopLevelKeyLine(line) {
                hasKeyValueLine = true
                continue
            }
            return false
        }
        return hasKeyValueLine
    }

    private static func isTopLevelKeyLine(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let keyPart = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !keyPart.isEmpty, !keyPart.hasPrefix("#") else { return false }
        let afterColon = line[line.index(after: colon)...]
        return afterColon.isEmpty || afterColon.first == " " || afterColon.first == "\t"
    }

    private static func extractFields(from lines: [String]) -> [FrontmatterField] {
        var fields: [FrontmatterField] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            guard let colon = line.firstIndex(of: ":"), isTopLevelKeyLine(line) else {
                index += 1
                continue
            }

            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let inlineValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if !inlineValue.isEmpty && inlineValue != "|" && inlineValue != ">" {
                fields.append(FrontmatterField(key: key, value: inlineValue))
                index += 1
            } else {
                var continuation: [String] = []
                var next = index + 1
                while next < lines.count {
                    let sub = lines[next]
                    let subTrimmed = sub.trimmingCharacters(in: .whitespaces)
                    if subTrimmed.isEmpty {
                        next += 1
                        continue
                    }
                    if sub.first == " " || sub.first == "\t" || subTrimmed.hasPrefix("- ") || subTrimmed == "-" {
                        continuation.append(subTrimmed)
                        next += 1
                    } else {
                        break
                    }
                }

                if continuation.isEmpty {
                    fields.append(FrontmatterField(key: key, value: inlineValue))
                } else if continuation.allSatisfy({ $0.hasPrefix("- ") || $0 == "-" }) {
                    let items = continuation.map {
                        $0 == "-" ? "" : String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty }
                    fields.append(FrontmatterField(key: key, value: "[\(items.joined(separator: ", "))]"))
                } else {
                    fields.append(FrontmatterField(key: key, value: continuation.joined(separator: " ")))
                }
                index = next
            }
        }

        return fields
    }
}
