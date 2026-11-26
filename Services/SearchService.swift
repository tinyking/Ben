import Foundation
import Observation

struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let lineNumber: Int
    let line: String
    let matchRange: Range<String.Index>
}

/// 全库全文搜索服务。
@Observable
final class SearchService {
    var query: String = ""
    var isCaseSensitive = false
    var isWholeWord = false
    var results: [SearchHit] = []

    func run(in vault: URL?) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, let vault else {
            results = []
            return
        }

        var hits: [SearchHit] = []
        let enumerator = FileManager.default.enumerator(
            at: vault,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
                var cursor = line.startIndex

                while let range = line.range(of: keyword, options: options, range: cursor..<line.endIndex) {
                    if !isWholeWord || Self.isWholeWordMatch(range, in: line) {
                        hits.append(SearchHit(
                            url: fileURL,
                            lineNumber: index + 1,
                            line: line,
                            matchRange: range
                        ))
                    }
                    if range.upperBound >= line.endIndex { break }
                    cursor = range.upperBound
                }
            }
        }
        results = hits
    }

    func clear() {
        query = ""
        results = []
    }

    private static func isWholeWordMatch(_ range: Range<String.Index>, in line: String) -> Bool {
        func isBoundary(_ character: Character) -> Bool {
            !character.isLetter && !character.isNumber && character != "_"
        }
        let beforeOK = range.lowerBound == line.startIndex || isBoundary(line[line.index(before: range.lowerBound)])
        let afterOK = range.upperBound == line.endIndex || isBoundary(line[range.upperBound])
        return beforeOK && afterOK
    }
}
