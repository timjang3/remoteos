import Testing
@testable import AppCore

@Test func labelMatchingPrefersExactMatches() {
    let score = LabelMatching.score(candidate: "hi", normalizedQuery: LabelMatching.normalize("hi"))

    #expect(score == 0)
}

@Test func labelMatchingAllowsExactTokenMatchesForShortLabels() {
    let score = LabelMatching.score(candidate: "open hi thread", normalizedQuery: LabelMatching.normalize("hi"))

    #expect(score == 1)
}

@Test func labelMatchingRejectsShortSubstringMatches() {
    let score = LabelMatching.score(candidate: "This thread", normalizedQuery: LabelMatching.normalize("hi"))

    #expect(score == nil)
}

@Test func labelMatchingAllowsLongerSubstringMatches() {
    let score = LabelMatching.score(candidate: "Fix coordinateconversion bug", normalizedQuery: LabelMatching.normalize("coordinate"))

    #expect(score == 2)
}
