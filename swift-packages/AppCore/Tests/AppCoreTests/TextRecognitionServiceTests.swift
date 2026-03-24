import Foundation
import Testing
@testable import AppCore

@Test func bestMatchPrefersExactVisibleTextMatches() {
    let matches = [
        TextRecognitionService.Match(
            text: "This thread",
            confidence: 0.99,
            boundsPixels: WindowBounds(x: 40, y: 100, width: 180, height: 24)
        ),
        TextRecognitionService.Match(
            text: "hi",
            confidence: 0.98,
            boundsPixels: WindowBounds(x: 40, y: 140, width: 40, height: 24)
        )
    ]

    let match = TextRecognitionService.bestMatch(in: matches, query: "hi")

    #expect(match?.text == "hi")
}

@Test func bestMatchUsesReadingOrderWhenMultipleTextMatchesExist() {
    let matches = [
        TextRecognitionService.Match(
            text: "Settings",
            confidence: 0.99,
            boundsPixels: WindowBounds(x: 120, y: 220, width: 120, height: 24)
        ),
        TextRecognitionService.Match(
            text: "Settings",
            confidence: 0.97,
            boundsPixels: WindowBounds(x: 120, y: 140, width: 120, height: 24)
        )
    ]

    let match = TextRecognitionService.bestMatch(in: matches, query: "Settings")

    #expect(match?.boundsPixels.y == 140)
}

@Test func bestMatchFallsBackToSubstringMatching() {
    let matches = [
        TextRecognitionService.Match(
            text: "remoteos",
            confidence: 0.99,
            boundsPixels: WindowBounds(x: 40, y: 80, width: 120, height: 24)
        ),
        TextRecognitionService.Match(
            text: "Fix host coordinate mapping",
            confidence: 0.98,
            boundsPixels: WindowBounds(x: 40, y: 120, width: 320, height: 24)
        )
    ]

    let match = TextRecognitionService.bestMatch(in: matches, query: "coordinate")

    #expect(match?.text == "Fix host coordinate mapping")
}

@Test func bestMatchDoesNotUseSubstringMatchingForVeryShortQueries() {
    let matches = [
        TextRecognitionService.Match(
            text: "This thread",
            confidence: 0.99,
            boundsPixels: WindowBounds(x: 40, y: 80, width: 180, height: 24)
        ),
        TextRecognitionService.Match(
            text: "Fix new tab switching bug",
            confidence: 0.98,
            boundsPixels: WindowBounds(x: 40, y: 120, width: 320, height: 24)
        )
    ]

    let match = TextRecognitionService.bestMatch(in: matches, query: "hi")

    #expect(match == nil)
}
