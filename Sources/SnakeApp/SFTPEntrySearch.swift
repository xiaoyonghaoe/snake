import Foundation

enum SFTPEntrySearch {
    static func results(in entries: [RemoteFile], query: String) -> [RemoteFile] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return entries }

        return entries.filter { entry in
            let searchableText = [entry.name, entry.linkTarget]
                .compactMap { $0 }
                .joined(separator: " ")
            return terms.allSatisfy { term in
                searchableText.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                ) != nil
            }
        }
    }
}
