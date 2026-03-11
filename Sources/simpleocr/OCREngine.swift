import Foundation
import Vision
import CoreImage
import CoreGraphics

enum OCREngine {
    private struct NormalizedRegion {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    static func performOCR(on fileURL: URL, languages: [String],
                           mode: RecognitionMode, minConfidence: Float,
                           outputFormat: OutputFormat = .text) throws -> OCRResult {
        guard let ciImage = CIImage(contentsOf: fileURL) else {
            throw CLIError.ocrFailed("Failed to load image: \(fileURL.path)")
        }

        let extent = ciImage.extent
        let imageSize = ImageSize(width: Int(extent.width), height: Int(extent.height))

        // Pad image with white borders to improve detection of text near edges.
        // Vision often clips first/last characters of text near image boundaries.
        let padding = max(extent.width, extent.height) * 0.05
        let paddedImage = padImage(ciImage, padding: padding)
        let paddedExtent = paddedImage.extent

        // Primary pass on padded image
        var observations = try runRecognition(
            ciImage: paddedImage,
            languages: languages,
            mode: mode,
            minConfidence: minConfidence
        )

        // Convert coordinates from padded image space back to original image space
        observations = observations.compactMap { obs in
            remapToOriginal(obs, padding: padding, paddedExtent: paddedExtent, originalExtent: extent)
        }

        // In fast mode, skip all supplemental passes and return the primary result.
        guard mode == .accurate else {
            let structuredRegions = ObservationLayout.structuredRegions(observations)
            return OCRResult(observations: observations, imageSize: imageSize, structuredRegions: structuredRegions)
        }

        // Additional passes at higher resolutions to catch small text (e.g. single digits
        // in table cells) that Vision misses. Only run when the primary pass found few
        // numeric tokens, indicating small digits may have been missed.
        let needsSupplementalScales = outputFormat == .tableJSON || hasSparsNumericContent(observations)
        if needsSupplementalScales && (extent.width < 2000 || extent.height < 2000) {
            let supplementalScales: [CGFloat] = max(extent.width, extent.height) < 1400 ? [2.0, 3.0] : [2.0]

            for scale in supplementalScales {
                let upscaled = paddedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let extraObservations = try runRecognition(
                    ciImage: upscaled,
                    languages: languages,
                    mode: mode,
                    minConfidence: minConfidence,
                    languageCorrection: false
                )
                for var extra in extraObservations {
                    guard let remapped = remapToOriginal(extra, padding: padding * scale,
                        paddedExtent: upscaled.extent, originalExtent: CGRect(
                            x: 0, y: 0, width: extent.width * scale, height: extent.height * scale))
                    else { continue }
                    extra = remapped

                    guard isSupplementalNumericToken(extra.text) else { continue }
                    mergeSupplementalObservation(extra, into: &observations, allowAppend: true)
                }
            }
        }

        observations = try refineTextObservations(
            from: ciImage,
            observations: observations,
            languages: languages,
            mode: mode,
            minConfidence: minConfidence
        )

        // Structured recovery is expensive — only run for formats that use it.
        let needsStructuredRecovery = outputFormat == .json || outputFormat == .tableJSON
        let structuredRegions = ObservationLayout.structuredRegions(observations)

        if needsStructuredRecovery {
            let structuredObservations = try recoverStructuredRegions(
                from: ciImage,
                regions: structuredRegions,
                languages: languages,
                mode: mode,
                minConfidence: minConfidence
            )

            for extra in structuredObservations {
                mergeSupplementalObservation(extra, into: &observations, allowAppend: false)
            }

            let finalStructuredRegions = ObservationLayout.structuredRegions(observations)
            return OCRResult(observations: observations, imageSize: imageSize, structuredRegions: finalStructuredRegions)
        }

        return OCRResult(observations: observations, imageSize: imageSize, structuredRegions: structuredRegions)
    }

    /// Check if the primary pass has sparse numeric content, suggesting small digits were missed.
    private static func hasSparsNumericContent(_ observations: [Observation]) -> Bool {
        guard !observations.isEmpty else { return false }
        let numericCount = observations.filter { isSupplementalNumericToken($0.text) }.count
        // If less than 10% of observations are numeric, supplemental scales may help
        return Double(numericCount) / Double(observations.count) < 0.1
    }

    /// Add white padding around the image so text near edges isn't clipped.
    /// Uses CIImage compositing to preserve original pixel data exactly.
    private static func padImage(_ image: CIImage, padding: CGFloat) -> CIImage {
        let extent = image.extent
        let paddedSize = CGRect(
            x: 0, y: 0,
            width: extent.width + padding * 2,
            height: extent.height + padding * 2
        )
        let white = CIImage(color: CIColor.white).cropped(to: paddedSize)
        let shifted = image.transformed(by: CGAffineTransform(translationX: padding, y: padding))
        return shifted.composited(over: white)
    }

    /// Convert bounding box from padded image coordinates to original image coordinates.
    /// Returns nil if the observation falls entirely within the padding area.
    private static func remapToOriginal(
        _ obs: Observation,
        padding: CGFloat,
        paddedExtent: CGRect,
        originalExtent: CGRect
    ) -> Observation? {
        let pw = Double(paddedExtent.width)
        let ph = Double(paddedExtent.height)
        let pad = Double(padding)
        let ow = Double(originalExtent.width)
        let oh = Double(originalExtent.height)

        // Vision coordinates are normalized (0-1). Convert bbox to padded pixel space,
        // subtract padding, then normalize to original image space.

        // In our coordinate system, y is top-left origin (0 = top)
        let pxX = obs.boundingBox.x * pw
        let pxY = obs.boundingBox.y * ph
        let pxW = obs.boundingBox.width * pw
        let pxH = obs.boundingBox.height * ph

        let origX = (pxX - pad) / ow
        let origY = (pxY - pad) / oh
        let origW = pxW / ow
        let origH = pxH / oh

        // Skip if center is outside the original image area
        let centerX = origX + origW / 2
        let centerY = origY + origH / 2
        guard centerX >= 0 && centerX <= 1 && centerY >= 0 && centerY <= 1 else { return nil }

        return Observation(
            text: obs.text,
            confidence: obs.confidence,
            boundingBox: BoundingBox(
                x: max(0, origX),
                y: max(0, origY),
                width: min(origW, 1.0 - max(0, origX)),
                height: min(origH, 1.0 - max(0, origY))
            )
        )
    }

    private static func runRecognition(
        ciImage: CIImage,
        languages: [String],
        mode: RecognitionMode,
        minConfidence: Float,
        languageCorrection: Bool = true
    ) throws -> [Observation] {
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = languages
        request.recognitionLevel = mode == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.0

        do {
            try handler.perform([request])
        } catch {
            throw CLIError.ocrFailed("OCR failed: \(error.localizedDescription)")
        }

        guard let results = request.results else {
            return []
        }

        var observations: [Observation] = []
        for vnObservation in results {
            guard let candidate = vnObservation.topCandidates(1).first else { continue }
            guard candidate.confidence >= minConfidence else { continue }

            let vnBBox = vnObservation.boundingBox
            let outputY = 1.0 - (vnBBox.origin.y + vnBBox.height)
            let boundingBox = BoundingBox(
                x: vnBBox.origin.x,
                y: outputY,
                width: vnBBox.width,
                height: vnBBox.height
            )

            observations.append(Observation(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: boundingBox
            ))
        }

        return observations
    }

    private static func isSupplementalNumericToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.contains(where: \.isNumber) else { return false }

        let allowedScalars = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.,:%/+-€$£¥ ")
        guard trimmed.unicodeScalars.allSatisfy(allowedScalars.contains) else {
            return false
        }

        let significantCharacters = trimmed.filter { !$0.isWhitespace }
        guard !significantCharacters.isEmpty else { return false }

        let digitCount = significantCharacters.filter(\.isNumber).count
        let ratio = Double(digitCount) / Double(significantCharacters.count)

        return ratio >= 0.3
    }

    private static func refineTextObservations(
        from image: CIImage,
        observations: [Observation],
        languages: [String],
        mode: RecognitionMode,
        minConfidence: Float
    ) throws -> [Observation] {
        var refined = observations

        for index in observations.indices {
            let observation = observations[index]
            guard shouldRefineTextObservation(observation) else { continue }

            let region = expandedRegion(
                around: observation.boundingBox,
                horizontalPaddingFactor: 0.18,
                verticalPaddingFactor: 0.55,
                minimumHorizontalPadding: 0.018,
                minimumVerticalPadding: 0.008
            )
            guard let cropRect = cropRect(for: region, extent: image.extent) else { continue }

            let candidates = try bestLocalRecognition(
                baseImage: image.cropped(to: cropRect),
                scales: refinementScales(for: observation),
                languages: languages,
                mode: mode,
                minConfidence: max(0.15, minConfidence * 0.75),
                languageCorrection: true,
                filter: isTextRefinementToken(_:)
            ).map { remapFromCroppedRegion($0, cropRegion: region) }

            guard let candidate = bestRefinedCandidate(for: observation, from: candidates) else { continue }
            guard shouldPreferRefinedText(candidate, over: observation) else { continue }

            refined[index] = candidate
        }

        return refined
    }

    private static func shouldRefineTextObservation(_ observation: Observation) -> Bool {
        guard observation.confidence < 0.9 else { return false }
        let trimmed = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 80 else { return false }
        guard trimmed.contains(where: \.isLetter) else { return false }
        guard !isSupplementalNumericToken(trimmed) else { return false }
        guard observation.boundingBox.height <= 0.05 else { return false }

        let aspectRatio = observation.boundingBox.width / max(observation.boundingBox.height, 0.0001)
        return aspectRatio >= 2.0
    }

    private static func expandedRegion(
        around boundingBox: BoundingBox,
        horizontalPaddingFactor: Double,
        verticalPaddingFactor: Double,
        minimumHorizontalPadding: Double,
        minimumVerticalPadding: Double
    ) -> NormalizedRegion {
        let horizontalPadding = max(boundingBox.width * horizontalPaddingFactor, minimumHorizontalPadding)
        let verticalPadding = max(boundingBox.height * verticalPaddingFactor, minimumVerticalPadding)

        let minX = max(0, boundingBox.x - horizontalPadding)
        let minY = max(0, boundingBox.y - verticalPadding)
        let maxX = min(1, boundingBox.x + boundingBox.width + horizontalPadding)
        let maxY = min(1, boundingBox.y + boundingBox.height + verticalPadding)

        return NormalizedRegion(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func refinementScales(for observation: Observation) -> [CGFloat] {
        if observation.boundingBox.height < 0.015 { return [5.0] }
        if observation.boundingBox.height < 0.025 { return [4.0] }
        return [3.0]
    }

    private static func isTextRefinementToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 100 else { return false }
        guard trimmed.contains(where: \.isLetter) else { return false }

        let allowed = CharacterSet(
            charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÜäöüß.,:%/+-€$£¥()&@'\"!?;:_ "
        )
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func bestRefinedCandidate(for observation: Observation, from candidates: [Observation]) -> Observation? {
        candidates
            .filter { candidate in
                candidate.boundingBox.width >= observation.boundingBox.width * 0.65
                    && candidate.boundingBox.height <= observation.boundingBox.height * 1.8
                    && centersAreClose(candidate.boundingBox, observation.boundingBox)
            }
            .max { lhs, rhs in
                refinementScore(lhs, against: observation) < refinementScore(rhs, against: observation)
            }
    }

    private static func centersAreClose(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Bool {
        let lhsCenterX = lhs.x + (lhs.width / 2)
        let lhsCenterY = lhs.y + (lhs.height / 2)
        let rhsCenterX = rhs.x + (rhs.width / 2)
        let rhsCenterY = rhs.y + (rhs.height / 2)

        return abs(lhsCenterX - rhsCenterX) <= max(rhs.width * 0.35, 0.03)
            && abs(lhsCenterY - rhsCenterY) <= max(rhs.height * 0.8, 0.02)
    }

    private static func refinementScore(_ candidate: Observation, against original: Observation) -> Double {
        let overlap = intersectionOverUnion(candidate.boundingBox, original.boundingBox)
        let similarity = normalizedEditSimilarity(candidate.text, original.text)
        let lengthGain = Double(max(0, candidate.text.count - original.text.count)) * 0.04

        return (Double(candidate.confidence) * 1.5) + overlap + similarity + lengthGain
    }

    private static func shouldPreferRefinedText(_ candidate: Observation, over original: Observation) -> Bool {
        if normalizeToken(candidate.text) == normalizeToken(original.text) {
            return candidate.confidence > original.confidence
        }

        let similarity = normalizedEditSimilarity(candidate.text, original.text)
        let lengthGain = candidate.text.count - original.text.count

        if similarity >= 0.82 && candidate.confidence + 0.05 >= original.confidence && lengthGain >= 0 {
            return true
        }

        return similarity >= 0.68
            && candidate.confidence + 0.1 >= original.confidence
            && lengthGain >= 1
    }

    private static func normalizedEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsChars = Array(normalizeToken(lhs))
        let rhsChars = Array(normalizeToken(rhs))

        guard !lhsChars.isEmpty || !rhsChars.isEmpty else { return 1 }
        let distance = levenshteinDistance(lhsChars, rhsChars)
        let maxLength = max(lhsChars.count, rhsChars.count)
        guard maxLength > 0 else { return 1 }

        return 1.0 - (Double(distance) / Double(maxLength))
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)

        for (i, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = i + 1

            for (j, right) in rhs.enumerated() {
                let substitutionCost = left == right ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + substitutionCost
                )
            }

            previous = current
        }

        return previous[rhs.count]
    }

    private static func mergeSupplementalObservation(
        _ extra: Observation,
        into observations: inout [Observation],
        allowAppend: Bool
    ) {
        guard let index = observations.firstIndex(where: { existing in
            observationsOverlap(existing, extra)
        }) else {
            if allowAppend {
                observations.append(extra)
            }
            return
        }

        let existing = observations[index]
        guard shouldPreferSupplemental(extra, over: existing) else { return }
        observations[index] = extra
    }

    private static func shouldPreferSupplemental(_ extra: Observation, over existing: Observation) -> Bool {
        if normalizeToken(extra.text) == normalizeToken(existing.text) {
            return extra.confidence > existing.confidence
        }

        guard isSupplementalNumericToken(existing.text) else {
            return false
        }

        let iou = intersectionOverUnion(existing.boundingBox, extra.boundingBox)
        if iou > 0.7 && extra.text.count > existing.text.count && extra.confidence >= existing.confidence {
            return true
        }

        return false
    }

    private static func observationsOverlap(_ lhs: Observation, _ rhs: Observation) -> Bool {
        let xDelta = abs(lhs.boundingBox.x - rhs.boundingBox.x)
        let yDelta = abs(lhs.boundingBox.y - rhs.boundingBox.y)
        let iou = intersectionOverUnion(lhs.boundingBox, rhs.boundingBox)

        return iou > 0.35 || (xDelta < 0.03 && yDelta < 0.02)
    }

    private static func normalizeToken(_ text: String) -> String {
        text
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    private static func intersectionOverUnion(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Double {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)

        let intersectionWidth = max(0, right - left)
        let intersectionHeight = max(0, bottom - top)
        let intersectionArea = intersectionWidth * intersectionHeight

        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        let unionArea = lhsArea + rhsArea - intersectionArea

        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    private static func recoverStructuredRegions(
        from image: CIImage,
        regions: [ObservationLayout.StructuredRegion],
        languages: [String],
        mode: RecognitionMode,
        minConfidence: Float
    ) throws -> [Observation] {
        var merged: [Observation] = []

        for region in regions {
            let regionObservations = try recoverDenseRegion(
                from: image,
                region: region,
                languages: languages,
                mode: mode,
                minConfidence: minConfidence
            )

            for observation in regionObservations {
                mergeSupplementalObservation(observation, into: &merged, allowAppend: false)
            }

            let cellObservations = try recoverStructuredCells(
                from: image,
                region: region,
                minConfidence: minConfidence
            )

            for observation in cellObservations {
                mergeSupplementalObservation(observation, into: &merged, allowAppend: true)
            }
        }

        return merged
    }

    private static func recoverDenseRegion(
        from image: CIImage,
        region: ObservationLayout.StructuredRegion,
        languages: [String],
        mode: RecognitionMode,
        minConfidence: Float
    ) throws -> [Observation] {
        let normalized = NormalizedRegion(
            x: region.minX,
            y: region.minY,
            width: region.maxX - region.minX,
            height: region.maxY - region.minY
        )

        guard let cropRect = cropRect(for: normalized, extent: image.extent) else { return [] }

        let scale = regionScale(for: region)
        let recovered = try bestLocalRecognition(
            baseImage: image.cropped(to: cropRect),
            scales: [scale],
            languages: languages,
            mode: mode,
            minConfidence: max(0.15, minConfidence * 0.8),
            languageCorrection: false
        ) { _ in true }

        return recovered
            .map { remapFromCroppedRegion($0, cropRegion: normalized) }
            .filter { observation in
                observation.boundingBox.height <= max(region.averageCellHeight * 2.2, 0.04)
            }
    }

    private static func recoverStructuredCells(
        from image: CIImage,
        region: ObservationLayout.StructuredRegion,
        minConfidence: Float
    ) throws -> [Observation] {
        let xBounds = cellXBounds(from: region)
        guard xBounds.count >= 2 else { return [] }

        var recovered: [Observation] = []
        for row in region.rows {
            let rowTop = max(region.minY, row.minY - row.averageHeight * 0.35)
            let rowBottom = min(region.maxY, row.maxY + row.averageHeight * 0.35)

            for bound in xBounds {
                let cellRegion = NormalizedRegion(
                    x: bound.lowerBound,
                    y: rowTop,
                    width: bound.upperBound - bound.lowerBound,
                    height: rowBottom - rowTop
                )

                guard cellRegion.width > 0.01, cellRegion.height > 0.004 else { continue }
                guard shouldRefineCell(cellRegion, row: row, averageCellWidth: region.averageCellWidth) else { continue }
                guard let cropRect = cropRect(for: cellRegion, extent: image.extent) else { continue }

                let observations = try bestLocalRecognition(
                    baseImage: image.cropped(to: cropRect),
                    scales: [6.0],
                    languages: ["en-US"],
                    mode: .accurate,
                    minConfidence: max(0.12, minConfidence * 0.6),
                    languageCorrection: false,
                    filter: isCompactCellToken(_:)
                )

                for observation in observations {
                    guard isCompactCellToken(observation.text) else { continue }
                    recovered.append(remapFromCroppedRegion(observation, cropRegion: cellRegion))
                }
            }
        }

        return recovered
    }

    private static func cellXBounds(from region: ObservationLayout.StructuredRegion) -> [ClosedRange<Double>] {
        guard region.columnAnchors.count >= 2 else { return [] }

        var bounds: [ClosedRange<Double>] = []
        for index in region.columnAnchors.indices {
            let leftAnchor = region.columnAnchors[index]
            let rightAnchor = index + 1 < region.columnAnchors.count ? region.columnAnchors[index + 1] : region.maxX
            let previousAnchor = index > 0 ? region.columnAnchors[index - 1] : region.minX

            let lower = max(region.minX, leftAnchor - ((leftAnchor - previousAnchor) * 0.18))
            let upper = min(region.maxX, rightAnchor - ((rightAnchor - leftAnchor) * 0.08))

            if upper - lower > 0.012 {
                bounds.append(lower...upper)
            }
        }

        return bounds
    }

    private static func shouldRefineCell(
        _ cellRegion: NormalizedRegion,
        row: ObservationLayout.RowCluster,
        averageCellWidth: Double
    ) -> Bool {
        let nearby = row.observations.filter { observation in
            observation.boundingBox.x < cellRegion.x + cellRegion.width
                && (observation.boundingBox.x + observation.boundingBox.width) > cellRegion.x
        }

        if nearby.isEmpty {
            return true
        }

        let hasSmallObservation = nearby.contains { $0.boundingBox.height <= row.averageHeight * 1.2 }
        let narrowCell = cellRegion.width <= max(averageCellWidth * 1.8, 0.08)
        return hasSmallObservation && narrowCell
    }

    private static func isCompactCellToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return false }

        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.,:%/+-€$£¥() ")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return false }

        let alnumCount = trimmed.filter { $0.isLetter || $0.isNumber }.count
        return alnumCount > 0
    }

    private static func cropRect(for region: NormalizedRegion, extent: CGRect) -> CGRect? {
        guard region.width > 0, region.height > 0 else { return nil }

        let x = extent.minX + (region.x * extent.width)
        let y = extent.minY + ((1.0 - region.y - region.height) * extent.height)
        let width = region.width * extent.width
        let height = region.height * extent.height

        guard width > 1, height > 1 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func remapFromCroppedRegion(_ observation: Observation, cropRegion: NormalizedRegion) -> Observation {
        Observation(
            text: observation.text,
            confidence: observation.confidence,
            boundingBox: BoundingBox(
                x: cropRegion.x + (observation.boundingBox.x * cropRegion.width),
                y: cropRegion.y + (observation.boundingBox.y * cropRegion.height),
                width: observation.boundingBox.width * cropRegion.width,
                height: observation.boundingBox.height * cropRegion.height
            )
        )
    }

    private static func regionScale(for region: ObservationLayout.StructuredRegion) -> CGFloat {
        if region.averageCellHeight < 0.018 { return 5.0 }
        if region.averageCellHeight < 0.028 { return 4.0 }
        return 3.0
    }

    private enum LocalImageVariant: CaseIterable {
        case original
        case balanced
        case crisp
    }

    private static func bestLocalRecognition(
        baseImage: CIImage,
        scales: [CGFloat],
        languages: [String],
        mode: RecognitionMode,
        minConfidence: Float,
        languageCorrection: Bool,
        filter: (String) -> Bool
    ) throws -> [Observation] {
        var bestObservations: [Observation] = []
        var bestScore = -Double.infinity

        for scale in scales {
            let upscaled = baseImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let observations = try runRecognition(
                ciImage: upscaled,
                languages: languages,
                mode: mode,
                minConfidence: minConfidence,
                languageCorrection: languageCorrection
            ).filter { filter($0.text) }

            let score = scoreLocalRecognition(observations)
            if score > bestScore {
                bestScore = score
                bestObservations = observations
            }
        }

        // Only try enhanced variant if original produced no results
        if bestObservations.isEmpty {
            let enhanced = applyLocalVariant(.balanced, to: baseImage)
            for scale in scales {
                let upscaled = enhanced.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let observations = try runRecognition(
                    ciImage: upscaled,
                    languages: languages,
                    mode: mode,
                    minConfidence: minConfidence,
                    languageCorrection: languageCorrection
                ).filter { filter($0.text) }

                let score = scoreLocalRecognition(observations)
                if score > bestScore {
                    bestScore = score
                    bestObservations = observations
                }
            }
        }

        return bestObservations
    }

    private static func applyLocalVariant(_ variant: LocalImageVariant, to image: CIImage) -> CIImage {
        switch variant {
        case .original:
            return image
        case .balanced:
            let grayscale = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.35
            ])
            return grayscale.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputIntensityKey: 0.7,
                kCIInputRadiusKey: 1.2
            ])
        case .crisp:
            let grayscale = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.7,
                kCIInputBrightnessKey: 0.02
            ])
            return grayscale.applyingFilter("CIGammaAdjust", parameters: [
                "inputPower": 0.82
            ])
        }
    }

    private static func scoreLocalRecognition(_ observations: [Observation]) -> Double {
        guard !observations.isEmpty else { return -Double.infinity }

        let confidenceScore = observations.reduce(0.0) { $0 + Double($1.confidence) }
        let lengthScore = Double(observations.reduce(0) { $0 + $1.text.count }) * 0.02
        let countScore = Double(observations.count) * 0.15

        return confidenceScore + lengthScore + countScore
    }
}
