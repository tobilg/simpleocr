import Foundation
import CoreGraphics
import CoreText
import ImageIO

enum PDFGenerator {
    static func generateTextPDF(result: OCRResult) throws -> Data {
        let pageWidth = CGFloat(result.imageSize.width)
        let pageHeight = CGFloat(result.imageSize.height)

        guard let pdfData = CFDataCreateMutable(nil, 0) else {
            throw CLIError.pdfGenerationFailed("Failed to create PDF data buffer")
        }
        guard let consumer = CGDataConsumer(data: pdfData) else {
            throw CLIError.pdfGenerationFailed("Failed to create PDF data consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CLIError.pdfGenerationFailed("Failed to create PDF context")
        }

        context.beginPDFPage(nil)
        renderTextOverlay(
            context: context,
            observations: result.observations,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            invisible: false
        )
        context.endPDFPage()
        context.closePDF()

        return pdfData as Data
    }

    static func generateImagePDF(result: OCRResult, imageURL: URL) throws -> Data {
        let pageWidth = CGFloat(result.imageSize.width)
        let pageHeight = CGFloat(result.imageSize.height)

        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CLIError.pdfGenerationFailed("Failed to load image: \(imageURL.path)")
        }

        guard let pdfData = CFDataCreateMutable(nil, 0) else {
            throw CLIError.pdfGenerationFailed("Failed to create PDF data buffer")
        }
        guard let consumer = CGDataConsumer(data: pdfData) else {
            throw CLIError.pdfGenerationFailed("Failed to create PDF data consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CLIError.pdfGenerationFailed("Failed to create PDF context")
        }

        context.beginPDFPage(nil)

        let fullPageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        context.draw(cgImage, in: fullPageRect)

        renderTextOverlay(
            context: context,
            observations: result.observations,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            invisible: true
        )

        context.endPDFPage()
        context.closePDF()

        return pdfData as Data
    }

    /// Per-observation rendering info computed from row analysis.
    private struct RenderInfo {
        let fontSize: CGFloat
        let rowY: Double       // normalized y shared by all observations in the row
        let rowHeight: Double  // normalized height shared by all observations in the row
    }

    /// Compute consistent font size AND vertical position for each observation by
    /// grouping into rows. All observations on the same row share the same y-position
    /// and height for proper vertical alignment.
    private static func computeRowRenderInfo(
        observations: [Observation],
        pageWidth: CGFloat,
        pageHeight: CGFloat
    ) -> [Int: RenderInfo] {
        let yTolerance = 0.005

        struct Row {
            var indices: [Int]
            var representativeY: Double
        }
        var rows: [Row] = []

        for (i, obs) in observations.enumerated() {
            let y = obs.boundingBox.y
            if let rowIdx = rows.firstIndex(where: { abs($0.representativeY - y) <= yTolerance }) {
                rows[rowIdx].indices.append(i)
            } else {
                rows.append(Row(indices: [i], representativeY: y))
            }
        }

        var renderMap: [Int: RenderInfo] = [:]

        for row in rows {
            // Median y-position and height for consistent vertical alignment
            let yValues = row.indices.map { observations[$0].boundingBox.y }.sorted()
            let medianY: Double
            if yValues.count % 2 == 1 {
                medianY = yValues[yValues.count / 2]
            } else {
                medianY = (yValues[yValues.count / 2 - 1] + yValues[yValues.count / 2]) / 2.0
            }

            let heights = row.indices.map { observations[$0].boundingBox.height }.sorted()
            let medianHeight: Double
            if heights.count % 2 == 1 {
                medianHeight = heights[heights.count / 2]
            } else {
                medianHeight = (heights[heights.count / 2 - 1] + heights[heights.count / 2]) / 2.0
            }
            let heightFont = CGFloat(medianHeight * Double(pageHeight) * 0.85)

            // Per-observation width-based font size
            var widthFonts: [(idx: Int, size: CGFloat)] = []
            for idx in row.indices {
                let obs = observations[idx]
                let bboxWidthPx = obs.boundingBox.width * Double(pageWidth)
                guard bboxWidthPx > 0 else { continue }

                let unitFont = CTFontCreateWithName("Helvetica" as CFString, 1.0, nil)
                let attrs: [String: Any] = [kCTFontAttributeName as String: unitFont]
                let attrStr = CFAttributedStringCreate(nil, obs.text as CFString, attrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(attrStr)
                let unitWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                guard unitWidth > 0 else { continue }

                widthFonts.append((idx: idx, size: CGFloat(bboxWidthPx / unitWidth)))
            }

            // Width-based consensus from long observations
            let longTextFonts = widthFonts
                .filter { observations[$0.idx].text.count >= 8 }
                .map { $0.size }
            let shortTextFonts = widthFonts
                .filter { observations[$0.idx].text.count >= 3 }
                .map { $0.size }
                .sorted()

            let consensusWidthFont: CGFloat
            if !longTextFonts.isEmpty {
                consensusWidthFont = longTextFonts.min()!
            } else if !shortTextFonts.isEmpty {
                if shortTextFonts.count % 2 == 1 {
                    consensusWidthFont = shortTextFonts[shortTextFonts.count / 2]
                } else {
                    consensusWidthFont = (shortTextFonts[shortTextFonts.count / 2 - 1] + shortTextFonts[shortTextFonts.count / 2]) / 2.0
                }
            } else {
                consensusWidthFont = heightFont
            }

            let rowFont = min(heightFont, consensusWidthFont)

            // Assign render info to each observation in this row
            for (idx, widthFont) in widthFonts {
                renderMap[idx] = RenderInfo(
                    fontSize: min(rowFont, widthFont),
                    rowY: medianY,
                    rowHeight: medianHeight
                )
            }
            for idx in row.indices where renderMap[idx] == nil {
                renderMap[idx] = RenderInfo(
                    fontSize: rowFont,
                    rowY: medianY,
                    rowHeight: medianHeight
                )
            }
        }

        return renderMap
    }

    private static func renderTextOverlay(
        context: CGContext,
        observations: [Observation],
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        invisible: Bool
    ) {
        let color: CGColor = invisible
            ? CGColor(red: 0, green: 0, blue: 0, alpha: 0)
            : CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        let orderedObservations = ObservationLayout.ordered(observations)
        let renderInfos = computeRowRenderInfo(
            observations: orderedObservations,
            pageWidth: pageWidth,
            pageHeight: pageHeight
        )

        for (i, obs) in orderedObservations.enumerated() {
            let info = renderInfos[i]
            let finalFontSize = info?.fontSize ?? CGFloat(obs.boundingBox.height * Double(pageHeight) * 0.85)
            guard finalFontSize > 0.5 else { continue }

            let bboxWidthPx = obs.boundingBox.width * Double(pageWidth)
            guard bboxWidthPx > 0 else { continue }

            let font = CTFontCreateWithName("Helvetica" as CFString, finalFontSize, nil)
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            let textHeight = ascent + descent

            let attributes: [String: Any] = [
                kCTFontAttributeName as String: font,
                kCTForegroundColorAttributeName as String: color
            ]
            let attrString = CFAttributedStringCreate(nil, obs.text as CFString, attributes as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrString)

            // Use row-normalized y and height for consistent vertical alignment
            let rowY = info?.rowY ?? obs.boundingBox.y
            let rowHeight = info?.rowHeight ?? obs.boundingBox.height
            let bboxHeightPx = rowHeight * Double(pageHeight)
            let cgX = obs.boundingBox.x * Double(pageWidth)
            let cgBoxBottom = Double(pageHeight) - (rowY * Double(pageHeight)) - bboxHeightPx

            // Vertically center the text within the row's bounding box
            let verticalPadding = (CGFloat(bboxHeightPx) - textHeight) / 2.0
            let baselineY = CGFloat(cgBoxBottom) + verticalPadding + descent

            context.saveGState()
            context.setTextDrawingMode(invisible ? .invisible : .fill)
            context.textPosition = CGPoint(x: cgX, y: Double(baselineY))
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
