import Foundation

enum LabelMatching {
    static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func bestScore(candidates: [String?], normalizedQuery: String) -> Int? {
        candidates.compactMap { candidate in
            guard let candidate else {
                return nil
            }
            return score(candidate: candidate, normalizedQuery: normalizedQuery)
        }
        .min()
    }

    static func score(candidate: String, normalizedQuery: String) -> Int? {
        let normalizedCandidate = normalize(candidate)
        guard !normalizedCandidate.isEmpty, !normalizedQuery.isEmpty else {
            return nil
        }
        if normalizedCandidate == normalizedQuery {
            return 0
        }
        let tokens = normalizedCandidate
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if tokens.contains(normalizedQuery) {
            return 1
        }
        if normalizedQuery.count >= 3, normalizedCandidate.contains(normalizedQuery) {
            return 2
        }
        return nil
    }
}
