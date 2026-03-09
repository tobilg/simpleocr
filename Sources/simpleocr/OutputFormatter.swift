import Foundation

enum OutputFormatter {
    static func format(result: OCRResult, as format: OutputFormat,
                       source: String, languages: [String], mode: RecognitionMode,
                       piiRedacted: Bool = false) throws -> String {
        switch format {
        case .text:
            return formatText(result: result)
        case .json:
            return try formatJSON(result: result, source: source, languages: languages,
                                  mode: mode, piiRedacted: piiRedacted)
        case .tableJSON:
            return try formatTableJSON(result: result, source: source, languages: languages,
                                       mode: mode, piiRedacted: piiRedacted)
        case .pdfText, .pdfImage:
            fatalError("PDF formats are handled by PDFGenerator")
        }
    }

    private static func formatText(result: OCRResult) -> String {
        let sorted = ObservationLayout.ordered(result.observations)

        return sorted.map { obs in
            let y = String(format: "%.2f", obs.boundingBox.y)
            let x = String(format: "%.2f", obs.boundingBox.x)
            return "[y=\(y),x=\(x)] \(obs.text)"
        }.joined(separator: "\n")
    }

    private static func formatJSON(result: OCRResult, source: String,
                                    languages: [String], mode: RecognitionMode,
                                    piiRedacted: Bool) throws -> String {
        let filename = URL(fileURLWithPath: source).lastPathComponent

        let jsonObservations = result.observations.map { obs in
            JSONObservation(
                text: obs.text,
                confidence: roundTo2dp(Double(obs.confidence)),
                boundingBox: jsonBoundingBox(from: obs.boundingBox)
            )
        }
        let jsonStructuredRegions = buildJSONStructuredRegions(result.structuredRegions)

        let output = JSONOutput(
            source: filename,
            imageSize: JSONImageSize(width: result.imageSize.width, height: result.imageSize.height),
            languageHints: languages,
            recognitionLevel: mode.rawValue,
            piiRedacted: piiRedacted,
            observations: jsonObservations,
            structuredRegions: jsonStructuredRegions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(output)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CLIError.ocrFailed("Failed to encode JSON output as UTF-8")
        }

        return jsonString
    }

    private static func formatTableJSON(result: OCRResult, source: String,
                                        languages: [String], mode: RecognitionMode,
                                        piiRedacted: Bool) throws -> String {
        let output = JSONTableOutput(
            source: URL(fileURLWithPath: source).lastPathComponent,
            imageSize: JSONImageSize(width: result.imageSize.width, height: result.imageSize.height),
            languageHints: languages,
            recognitionLevel: mode.rawValue,
            piiRedacted: piiRedacted,
            tables: buildJSONStructuredRegions(result.structuredRegions)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(output)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CLIError.ocrFailed("Failed to encode table JSON output as UTF-8")
        }

        return jsonString
    }

    private static func roundTo2dp(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func jsonBoundingBox(from boundingBox: BoundingBox) -> JSONBoundingBox {
        JSONBoundingBox(
            x: roundTo2dp(boundingBox.x),
            y: roundTo2dp(boundingBox.y),
            width: roundTo2dp(boundingBox.width),
            height: roundTo2dp(boundingBox.height)
        )
    }

    private static func boundingBoxForCells(_ cells: [ObservationLayout.CellCluster]) -> BoundingBox {
        let nonEmpty = cells.filter { !$0.observations.isEmpty }
        let source = nonEmpty.isEmpty ? cells : nonEmpty

        let minX = source.map(\.boundingBox.x).min() ?? 0
        let minY = source.map(\.boundingBox.y).min() ?? 0
        let maxX = source.map { $0.boundingBox.x + $0.boundingBox.width }.max() ?? minX
        let maxY = source.map { $0.boundingBox.y + $0.boundingBox.height }.max() ?? minY

        return BoundingBox(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func buildJSONStructuredRegions(_ regions: [ObservationLayout.StructuredRegion]) -> [JSONStructuredRegion] {
        regions.map { region in
            let rows = ObservationLayout.cellClusters(in: region).map { cells in
                let rowBox = boundingBoxForCells(cells)
                let rowConfidences = cells.flatMap { $0.observations.map { Double($0.confidence) } }
                return JSONStructuredRow(
                    boundingBox: jsonBoundingBox(from: rowBox),
                    cellCount: cells.count,
                    averageConfidence: roundTo2dp(average(rowConfidences)),
                    minConfidence: roundTo2dp(rowConfidences.min() ?? 0),
                    maxConfidence: roundTo2dp(rowConfidences.max() ?? 0),
                    cells: cells.map { cell in
                        JSONStructuredCell(
                            columnIndex: cell.columnIndex,
                            text: cell.text,
                            observationCount: cell.observations.count,
                            averageConfidence: roundTo2dp(cell.averageConfidence),
                            minConfidence: roundTo2dp(cell.minConfidence),
                            maxConfidence: roundTo2dp(cell.maxConfidence),
                            boundingBox: jsonBoundingBox(from: cell.boundingBox)
                        )
                    }
                )
            }

            let regionConfidences = rows.flatMap { row in
                row.cells.map(\.averageConfidence).filter { $0 > 0 }
            }

            return JSONStructuredRegion(
                boundingBox: JSONBoundingBox(
                    x: roundTo2dp(region.minX),
                    y: roundTo2dp(region.minY),
                    width: roundTo2dp(region.maxX - region.minX),
                    height: roundTo2dp(region.maxY - region.minY)
                ),
                rowCount: region.rows.count,
                columnAnchors: region.columnAnchors.map(roundTo2dp),
                averageConfidence: roundTo2dp(average(regionConfidences)),
                minConfidence: roundTo2dp(regionConfidences.min() ?? 0),
                maxConfidence: roundTo2dp(regionConfidences.max() ?? 0),
                rows: rows
            )
        }
    }
}
