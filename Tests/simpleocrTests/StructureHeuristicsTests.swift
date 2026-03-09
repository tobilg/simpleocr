#if canImport(XCTest)
import XCTest
@testable import simpleocr

final class StructureHeuristicsTests: XCTestCase {
    func testStructuredRegionsDetectAlignedDenseRows() {
        let observations = [
            makeObservation("A1", x: 0.10, y: 0.20, width: 0.10, height: 0.02),
            makeObservation("B1", x: 0.35, y: 0.20, width: 0.10, height: 0.02),
            makeObservation("C1", x: 0.65, y: 0.20, width: 0.10, height: 0.02),
            makeObservation("A2", x: 0.10, y: 0.24, width: 0.10, height: 0.02),
            makeObservation("B2", x: 0.35, y: 0.24, width: 0.10, height: 0.02),
            makeObservation("C2", x: 0.65, y: 0.24, width: 0.10, height: 0.02),
            makeObservation("A3", x: 0.10, y: 0.28, width: 0.10, height: 0.02),
            makeObservation("B3", x: 0.35, y: 0.28, width: 0.10, height: 0.02),
            makeObservation("C3", x: 0.65, y: 0.28, width: 0.10, height: 0.02)
        ]

        let regions = ObservationLayout.structuredRegions(observations)

        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].rows.count, 3)
        XCTAssertGreaterThanOrEqual(regions[0].columnAnchors.count, 3)
    }

    func testCellClustersPreserveTableShape() {
        let observations = [
            makeObservation("R1C1", x: 0.10, y: 0.20, width: 0.10, height: 0.02),
            makeObservation("R1C2", x: 0.35, y: 0.20, width: 0.10, height: 0.02),
            makeObservation("R2C1", x: 0.10, y: 0.24, width: 0.10, height: 0.02),
            makeObservation("R2C2", x: 0.35, y: 0.24, width: 0.10, height: 0.02)
        ]

        let region = try XCTUnwrap(ObservationLayout.structuredRegions(observations).first)
        let cells = ObservationLayout.cellClusters(in: region)

        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].count, 2)
        XCTAssertEqual(cells[0][0].text, "R1C1")
        XCTAssertEqual(cells[1][1].text, "R2C2")
    }

    func testStructuredRegionsCanSplitMergedColumnsUsingTokenCenters() throws {
        let observations = [
            makeObservation("HeaderA", x: 0.10, y: 0.20, width: 0.12, height: 0.02),
            makeObservation("HeaderB", x: 0.40, y: 0.20, width: 0.12, height: 0.02),
            makeObservation("1", x: 0.10, y: 0.24, width: 0.02, height: 0.02),
            makeObservation("120,00", x: 0.40, y: 0.24, width: 0.12, height: 0.02),
            makeObservation("2", x: 0.68, y: 0.24, width: 0.02, height: 0.02),
            makeObservation("2", x: 0.10, y: 0.28, width: 0.02, height: 0.02),
            makeObservation("98,00", x: 0.40, y: 0.28, width: 0.10, height: 0.02),
            makeObservation("3", x: 0.68, y: 0.28, width: 0.02, height: 0.02)
        ]

        let region = try XCTUnwrap(ObservationLayout.structuredRegions(observations).first)

        XCTAssertGreaterThanOrEqual(region.columnAnchors.count, 3)

        let cells = ObservationLayout.cellClusters(in: region)
        XCTAssertEqual(cells[1].count, 3)
        XCTAssertEqual(cells[1][0].text, "1")
        XCTAssertEqual(cells[1][1].text, "120,00")
        XCTAssertEqual(cells[1][2].text, "2")
    }

    func testExampleBillProducesStructuredRegionsInJSON() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let imageURL = repoRoot.appendingPathComponent("examples/example-bill.png")

        let result = try OCREngine.performOCR(
            on: imageURL,
            languages: ["de-DE", "en-US"],
            mode: .accurate,
            minConfidence: 0.3
        )

        let output = try OutputFormatter.format(
            result: result,
            as: .json,
            source: imageURL.path,
            languages: ["de-DE", "en-US"],
            mode: .accurate
        )

        let data = try XCTUnwrap(output.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let structuredRegions = try XCTUnwrap(object["structured_regions"] as? [[String: Any]])

        XCTAssertFalse(structuredRegions.isEmpty)
        XCTAssertTrue(structuredRegions.contains { ($0["row_count"] as? Int ?? 0) >= 2 })

        let maxCellCount = structuredRegions
            .flatMap { $0["rows"] as? [[String: Any]] ?? [] }
            .compactMap { $0["cell_count"] as? Int }
            .max() ?? 0

        XCTAssertGreaterThanOrEqual(maxCellCount, 4)
    }

    private func makeObservation(_ text: String, x: Double, y: Double, width: Double, height: Double) -> Observation {
        Observation(
            text: text,
            confidence: 0.95,
            boundingBox: BoundingBox(x: x, y: y, width: width, height: height)
        )
    }
}
#endif
