import CoreGraphics
import Foundation
import ImageIO
import Vision

public final class TextRecognitionService: @unchecked Sendable {
    public struct Match: Sendable, Equatable {
        public var text: String
        public var confidence: Float
        public var boundsPixels: WindowBounds

        public init(text: String, confidence: Float, boundsPixels: WindowBounds) {
            self.text = text
            self.confidence = confidence
            self.boundsPixels = boundsPixels
        }

        public var centerPointPixels: CGPoint {
            CGPoint(
                x: boundsPixels.x + (boundsPixels.width / 2),
                y: boundsPixels.y + (boundsPixels.height / 2)
            )
        }
    }

    private let log = AppLogs.accessibility

    public init() {}

    public func matches(in frame: CapturedFrame) throws -> [Match] {
        let image = try decode(frame: frame)
        return try matches(in: image)
    }

    public func bestMatch(in frame: CapturedFrame, query: String) throws -> Match? {
        let matches = try matches(in: frame)
        return Self.bestMatch(in: matches, query: query)
    }

    func matches(in image: CGImage) throws -> [Match] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let results = (request.results ?? []).compactMap { observation -> Match? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }

            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }

            let bounds = observation.boundingBox
            let pixelBounds = WindowBounds(
                x: bounds.minX * imageWidth,
                y: (1 - bounds.maxY) * imageHeight,
                width: bounds.width * imageWidth,
                height: bounds.height * imageHeight
            )
            guard pixelBounds.width > 0, pixelBounds.height > 0 else {
                return nil
            }

            return Match(
                text: text,
                confidence: candidate.confidence,
                boundsPixels: pixelBounds
            )
        }

        return results.sorted(by: Self.readingOrder(_:_:))
    }

    static func bestMatch(in matches: [Match], query: String) -> Match? {
        let normalizedQuery = LabelMatching.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return nil
        }

        return matches
            .compactMap { match -> (score: Int, match: Match)? in
                guard let score = matchScore(match.text, query: normalizedQuery) else {
                    return nil
                }
                return (score, match)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return readingOrder(lhs.match, rhs.match)
            }
            .first?
            .match
    }

    func logMatch(frame: CapturedFrame, query: String, match: Match) {
        log.notice(
            "Visible text match frameId=\(frame.frameId) query=\(query) matchedText=\(match.text) boundsPixels=\(match.boundsPixels.logDescription) confidence=\(String(format: "%.2f", match.confidence))"
        )
    }

    private func decode(frame: CapturedFrame) throws -> CGImage {
        guard let data = Data(base64Encoded: frame.dataBase64) else {
            throw AppCoreError.invalidPayload("Failed to decode the captured frame for visible text matching.")
        }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AppCoreError.invalidPayload("Failed to read the captured frame image for visible text matching.")
        }
        return image
    }

    private static func matchScore(_ text: String, query: String) -> Int? {
        LabelMatching.score(candidate: text, normalizedQuery: query)
    }

    private static func readingOrder(_ lhs: Match, _ rhs: Match) -> Bool {
        let yDelta = lhs.boundsPixels.y - rhs.boundsPixels.y
        if abs(yDelta) > 6 {
            return yDelta < 0
        }
        if lhs.boundsPixels.x != rhs.boundsPixels.x {
            return lhs.boundsPixels.x < rhs.boundsPixels.x
        }
        return lhs.confidence > rhs.confidence
    }

}
