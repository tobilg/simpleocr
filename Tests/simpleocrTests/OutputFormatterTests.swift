#if canImport(XCTest)
import Foundation
import XCTest
@testable import simpleocr

final class OutputFormatterTests: XCTestCase {
    func testTextOutputSortsByYThenX() throws {
        let result = OCRResult(
            observations: [
                Observation(
                    text: "third",
                    confidence: 0.9,
                    boundingBox: BoundingBox(x: 0.8, y: 0.4, width: 0.1, height: 0.1)
                ),
                Observation(
                    text: "first",
                    confidence: 0.9,
                    boundingBox: BoundingBox(x: 0.4, y: 0.1, width: 0.1, height: 0.1)
                ),
                Observation(
                    text: "second",
                    confidence: 0.9,
                    boundingBox: BoundingBox(x: 0.6, y: 0.1, width: 0.1, height: 0.1)
                )
            ],
            imageSize: ImageSize(width: 100, height: 200)
        )

        let output = try OutputFormatter.format(
            result: result,
            as: .text,
            source: "/tmp/invoice.png",
            languages: ["en-US"],
            mode: .accurate
        )

        XCTAssertEqual(output, """
        [y=0.10,x=0.40] first
        [y=0.10,x=0.60] second
        [y=0.40,x=0.80] third
        """)
    }

    func testJSONOutputIncludesMetadata() throws {
        let result = OCRResult(
            observations: [
                Observation(
                    text: "Muster GmbH",
                    confidence: 0.981,
                    boundingBox: BoundingBox(x: 0.061, y: 0.084, width: 0.221, height: 0.031)
                )
            ],
            imageSize: ImageSize(width: 2480, height: 3508)
        )

        let output = try OutputFormatter.format(
            result: result,
            as: .json,
            source: "/tmp/invoice.png",
            languages: ["de-DE", "en-US"],
            mode: .accurate,
            piiRedacted: true
        )

        let data = try XCTUnwrap(output.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["source"] as? String, "invoice.png")
        XCTAssertEqual(object["recognition_level"] as? String, "accurate")
        XCTAssertEqual(object["pii_redacted"] as? Bool, true)

        let imageSize = try XCTUnwrap(object["image_size"] as? [String: Any])
        XCTAssertEqual(imageSize["width"] as? Int, 2480)
        XCTAssertEqual(imageSize["height"] as? Int, 3508)

        let observations = try XCTUnwrap(object["observations"] as? [[String: Any]])
        let first = try XCTUnwrap(observations.first)
        XCTAssertEqual(first["text"] as? String, "Muster GmbH")
        XCTAssertEqual(first["confidence"] as? Double, 0.98)

        let structuredRegions = try XCTUnwrap(object["structured_regions"] as? [[String: Any]])
        XCTAssertEqual(structuredRegions.count, 0)
    }

    func testJSONOutputIncludesStructuredRegions() throws {
        let structuredRegion = ObservationLayout.StructuredRegion(
            rows: [
                ObservationLayout.RowCluster(
                    observations: [
                        Observation(
                            text: "A1",
                            confidence: 0.9,
                            boundingBox: BoundingBox(x: 0.10, y: 0.20, width: 0.10, height: 0.02)
                        ),
                        Observation(
                            text: "B1",
                            confidence: 0.9,
                            boundingBox: BoundingBox(x: 0.35, y: 0.20, width: 0.10, height: 0.02)
                        )
                    ],
                    centerY: 0.21,
                    averageHeight: 0.02,
                    averageWidth: 0.10,
                    minY: 0.20,
                    maxY: 0.22,
                    minX: 0.10,
                    maxX: 0.45
                )
            ],
            columnAnchors: [0.10, 0.35],
            minX: 0.10,
            maxX: 0.45,
            minY: 0.20,
            maxY: 0.22,
            averageCellHeight: 0.02,
            averageCellWidth: 0.10
        )

        let result = OCRResult(
            observations: [
                Observation(
                    text: "A1",
                    confidence: 0.9,
                    boundingBox: BoundingBox(x: 0.10, y: 0.20, width: 0.10, height: 0.02)
                ),
                Observation(
                    text: "B1",
                    confidence: 0.9,
                    boundingBox: BoundingBox(x: 0.35, y: 0.20, width: 0.10, height: 0.02)
                )
            ],
            imageSize: ImageSize(width: 1000, height: 1000),
            structuredRegions: [structuredRegion]
        )

        let output = try OutputFormatter.format(
            result: result,
            as: .json,
            source: "/tmp/grid.png",
            languages: ["en-US"],
            mode: .accurate
        )

        let data = try XCTUnwrap(output.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let structuredRegions = try XCTUnwrap(object["structured_regions"] as? [[String: Any]])
        let firstRegion = try XCTUnwrap(structuredRegions.first)
        let rows = try XCTUnwrap(firstRegion["rows"] as? [[String: Any]])
        let firstRow = try XCTUnwrap(rows.first)
        let cells = try XCTUnwrap(firstRow["cells"] as? [[String: Any]])

        XCTAssertEqual(firstRegion["row_count"] as? Int, 1)
        XCTAssertEqual(firstRegion["average_confidence"] as? Double, 0.9)
        XCTAssertEqual(firstRegion["min_confidence"] as? Double, 0.9)
        XCTAssertEqual(firstRegion["max_confidence"] as? Double, 0.9)
        XCTAssertEqual(firstRow["average_confidence"] as? Double, 0.9)
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0]["text"] as? String, "A1")
        XCTAssertEqual(cells[1]["text"] as? String, "B1")
        XCTAssertEqual(cells[0]["average_confidence"] as? Double, 0.9)
        XCTAssertEqual(cells[1]["average_confidence"] as? Double, 0.9)
    }

    func testTableJSONOutputIncludesOnlyStructuredTables() throws {
        let structuredRegion = ObservationLayout.StructuredRegion(
            rows: [
                ObservationLayout.RowCluster(
                    observations: [
                        Observation(
                            text: "A1",
                            confidence: 0.9,
                            boundingBox: BoundingBox(x: 0.10, y: 0.20, width: 0.10, height: 0.02)
                        ),
                        Observation(
                            text: "B1",
                            confidence: 0.8,
                            boundingBox: BoundingBox(x: 0.35, y: 0.20, width: 0.10, height: 0.02)
                        )
                    ],
                    centerY: 0.21,
                    averageHeight: 0.02,
                    averageWidth: 0.10,
                    minY: 0.20,
                    maxY: 0.22,
                    minX: 0.10,
                    maxX: 0.45
                )
            ],
            columnAnchors: [0.10, 0.35],
            minX: 0.10,
            maxX: 0.45,
            minY: 0.20,
            maxY: 0.22,
            averageCellHeight: 0.02,
            averageCellWidth: 0.10
        )

        let result = OCRResult(
            observations: [
                Observation(
                    text: "free text",
                    confidence: 0.7,
                    boundingBox: BoundingBox(x: 0.05, y: 0.05, width: 0.20, height: 0.03)
                )
            ],
            imageSize: ImageSize(width: 1000, height: 1000),
            structuredRegions: [structuredRegion]
        )

        let output = try OutputFormatter.format(
            result: result,
            as: .tableJSON,
            source: "/tmp/grid.png",
            languages: ["en-US"],
            mode: .accurate
        )

        let data = try XCTUnwrap(output.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["source"] as? String, "grid.png")
        XCTAssertNil(object["observations"])

        let tables = try XCTUnwrap(object["tables"] as? [[String: Any]])
        XCTAssertEqual(tables.count, 1)

        let firstTable = try XCTUnwrap(tables.first)
        XCTAssertEqual(firstTable["row_count"] as? Int, 1)
        XCTAssertEqual(firstTable["average_confidence"] as? Double, 0.85)

        let rows = try XCTUnwrap(firstTable["rows"] as? [[String: Any]])
        let firstRow = try XCTUnwrap(rows.first)
        let cells = try XCTUnwrap(firstRow["cells"] as? [[String: Any]])

        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0]["text"] as? String, "A1")
        XCTAssertEqual(cells[1]["text"] as? String, "B1")
    }
}
#endif
