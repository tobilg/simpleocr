#if canImport(XCTest)
import XCTest
@testable import simpleocr

final class PIIRedactorTests: XCTestCase {
    func testRegexBasedRedactionHandlesMultiplePassesOnSameString() {
        let input = "Card 4111 1111 1111 1111 SSN 123-45-6789 IBAN DE89370400440532013000"
        let redacted = PIIRedactor.redact(input)

        XCTAssertFalse(redacted.contains("4111 1111 1111 1111"))
        XCTAssertFalse(redacted.contains("123-45-6789"))
        XCTAssertFalse(redacted.contains("DE89370400440532013000"))
        XCTAssertTrue(redacted.contains("[CREDIT_CARD]"))
        XCTAssertTrue(redacted.contains("[SSN]"))
        XCTAssertTrue(redacted.contains("[IBAN]"))
    }

    func testObservationRedactionPreservesGeometry() {
        let observation = Observation(
            text: "SSN 123-45-6789",
            confidence: 0.75,
            boundingBox: BoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        )

        let redacted = PIIRedactor.redact(observations: [observation])

        XCTAssertEqual(redacted.count, 1)
        XCTAssertEqual(redacted[0].confidence, observation.confidence)
        XCTAssertEqual(redacted[0].boundingBox.x, observation.boundingBox.x)
        XCTAssertEqual(redacted[0].boundingBox.y, observation.boundingBox.y)
        XCTAssertEqual(redacted[0].boundingBox.width, observation.boundingBox.width)
        XCTAssertEqual(redacted[0].boundingBox.height, observation.boundingBox.height)
        XCTAssertTrue(redacted[0].text.contains("[SSN]"))
    }
}
#endif
