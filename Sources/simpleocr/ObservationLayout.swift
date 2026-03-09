import Foundation

enum ObservationLayout {
    struct RowCluster {
        var observations: [Observation]
        var centerY: Double
        var averageHeight: Double
        var averageWidth: Double
        var minY: Double
        var maxY: Double
        var minX: Double
        var maxX: Double

        var height: Double { maxY - minY }
        var width: Double { maxX - minX }

        mutating func append(_ observation: Observation) {
            observations.append(observation)

            let count = Double(observations.count)
            let center = observation.boundingBox.y + (observation.boundingBox.height / 2)
            centerY = ((centerY * (count - 1)) + center) / count
            averageHeight = ((averageHeight * (count - 1)) + observation.boundingBox.height) / count
            averageWidth = ((averageWidth * (count - 1)) + observation.boundingBox.width) / count
            minY = min(minY, observation.boundingBox.y)
            maxY = max(maxY, observation.boundingBox.y + observation.boundingBox.height)
            minX = min(minX, observation.boundingBox.x)
            maxX = max(maxX, observation.boundingBox.x + observation.boundingBox.width)
        }
    }

    struct StructuredRegion {
        let rows: [RowCluster]
        let columnAnchors: [Double]
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double
        let averageCellHeight: Double
        let averageCellWidth: Double
    }

    struct CellCluster {
        let columnIndex: Int
        let boundingBox: BoundingBox
        let observations: [Observation]

        var text: String {
            observations
                .sorted { lhs, rhs in
                    if abs(lhs.boundingBox.x - rhs.boundingBox.x) <= 0.002 {
                        return lhs.boundingBox.y < rhs.boundingBox.y
                    }
                    return lhs.boundingBox.x < rhs.boundingBox.x
                }
                .map(\.text)
                .joined(separator: " ")
        }

        var averageConfidence: Double {
            guard !observations.isEmpty else { return 0 }
            return observations.reduce(0.0) { $0 + Double($1.confidence) } / Double(observations.count)
        }

        var minConfidence: Double {
            observations.map { Double($0.confidence) }.min() ?? 0
        }

        var maxConfidence: Double {
            observations.map { Double($0.confidence) }.max() ?? 0
        }
    }

    static func ordered(_ observations: [Observation]) -> [Observation] {
        observations.sorted { lhs, rhs in
            if abs(lhs.boundingBox.y - rhs.boundingBox.y) <= adaptiveRowTolerance(lhs, rhs) {
                if abs(lhs.boundingBox.x - rhs.boundingBox.x) <= 0.002 {
                    return lhs.boundingBox.y < rhs.boundingBox.y
                }
                return lhs.boundingBox.x < rhs.boundingBox.x
            }
            return lhs.boundingBox.y < rhs.boundingBox.y
        }
    }

    static func clusterRows(_ observations: [Observation]) -> [[Observation]] {
        clusteredRows(observations).map(\.observations)
    }

    static func clusteredRows(_ observations: [Observation]) -> [RowCluster] {
        let seedOrder = observations.sorted { lhs, rhs in
            let lhsCenter = lhs.boundingBox.y + (lhs.boundingBox.height / 2)
            let rhsCenter = rhs.boundingBox.y + (rhs.boundingBox.height / 2)

            if abs(lhsCenter - rhsCenter) <= 0.002 {
                return lhs.boundingBox.x < rhs.boundingBox.x
            }
            return lhsCenter < rhsCenter
        }

        var rows: [RowCluster] = []

        for observation in seedOrder {
            let center = observation.boundingBox.y + (observation.boundingBox.height / 2)

            if let rowIndex = rows.firstIndex(where: { row in
                let heightScale = max(row.averageHeight, observation.boundingBox.height)
                let verticalTolerance = max(0.004, min(0.012, heightScale * 0.55))
                let overlapsVertically =
                    observation.boundingBox.y <= row.maxY + verticalTolerance
                    && (observation.boundingBox.y + observation.boundingBox.height) >= row.minY - verticalTolerance

                return abs(row.centerY - center) <= verticalTolerance || overlapsVertically
            }) {
                rows[rowIndex].append(observation)
            } else {
                rows.append(RowCluster(
                    observations: [observation],
                    centerY: center,
                    averageHeight: observation.boundingBox.height,
                    averageWidth: observation.boundingBox.width,
                    minY: observation.boundingBox.y,
                    maxY: observation.boundingBox.y + observation.boundingBox.height,
                    minX: observation.boundingBox.x,
                    maxX: observation.boundingBox.x + observation.boundingBox.width
                ))
            }
        }

        return rows
            .sorted { lhs, rhs in lhs.centerY < rhs.centerY }
            .map { row in
                var sortedRow = row
                sortedRow.observations.sort { lhs, rhs in
                    if abs(lhs.boundingBox.x - rhs.boundingBox.x) <= 0.002 {
                        return lhs.boundingBox.y < rhs.boundingBox.y
                    }
                    return lhs.boundingBox.x < rhs.boundingBox.x
                }
                return sortedRow
            }
    }

    static func structuredRegions(_ observations: [Observation]) -> [StructuredRegion] {
        let rows = structureRows(observations)
        guard rows.count >= 2 else { return [] }

        let candidateRows = rows.filter { row in
            row.observations.count >= 3 && row.averageHeight <= 0.05
        }

        guard candidateRows.count >= 2 else { return [] }

        let rowMap = Dictionary(uniqueKeysWithValues: candidateRows.map { ($0.minY, $0) })
        var runs: [[RowCluster]] = []
        var currentRun: [RowCluster] = []

        for row in rows {
            guard let candidate = rowMap[row.minY] else {
                if currentRun.count >= 2 {
                    runs.append(currentRun)
                }
                currentRun = []
                continue
            }

            if let last = currentRun.last {
                let gap = candidate.minY - last.maxY
                let gapTolerance = max(0.01, min(0.05, (candidate.averageHeight + last.averageHeight) * 2.2))
                if gap > gapTolerance {
                    if currentRun.count >= 2 {
                        runs.append(currentRun)
                    }
                    currentRun = []
                }
            }

            currentRun.append(candidate)
        }

        if currentRun.count >= 2 {
            runs.append(currentRun)
        }

        return runs.compactMap { run in
            let minX = max(0, run.map(\.minX).min()! - 0.01)
            let maxX = min(1, run.map(\.maxX).max()! + 0.01)
            let minY = max(0, run.map(\.minY).min()! - 0.005)
            let maxY = min(1, run.map(\.maxY).max()! + 0.005)

            let totalObservations = Double(run.reduce(0) { $0 + $1.observations.count })
            let avgHeight = run.reduce(0.0) { $0 + ($1.averageHeight * Double($1.observations.count)) } / totalObservations
            let avgWidth = run.reduce(0.0) { $0 + ($1.averageWidth * Double($1.observations.count)) } / totalObservations
            let anchors = refineColumnAnchors(
                inferColumnAnchors(in: run),
                rows: run,
                minX: minX,
                maxX: maxX,
                averageCellWidth: avgWidth
            )
            guard anchors.count >= 2 else { return nil }

            return StructuredRegion(
                rows: run,
                columnAnchors: anchors,
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                averageCellHeight: avgHeight,
                averageCellWidth: avgWidth
            )
        }
    }

    static func cellClusters(in region: StructuredRegion) -> [[CellCluster]] {
        let xBounds = xBounds(from: region)
        guard !xBounds.isEmpty else { return [] }

        return region.rows.map { row in
            let rowTop = max(region.minY, row.minY - row.averageHeight * 0.35)
            let rowBottom = min(region.maxY, row.maxY + row.averageHeight * 0.35)

            return xBounds.enumerated().map { index, bound in
                let cellObservations = row.observations
                    .filter { observation in
                        let centerX = observation.boundingBox.x + (observation.boundingBox.width / 2)
                        return centerX >= bound.lowerBound && centerX <= bound.upperBound
                    }

                return CellCluster(
                    columnIndex: index,
                    boundingBox: BoundingBox(
                        x: bound.lowerBound,
                        y: rowTop,
                        width: bound.upperBound - bound.lowerBound,
                        height: rowBottom - rowTop
                    ),
                    observations: cellObservations
                )
            }
        }
    }

    static func xBounds(from region: StructuredRegion) -> [ClosedRange<Double>] {
        xBounds(anchors: region.columnAnchors, minX: region.minX, maxX: region.maxX)
    }

    private static func inferColumnAnchors(in rows: [RowCluster]) -> [Double] {
        struct AnchorBin {
            var values: [Double]
            var support: Set<Int>

            mutating func append(value: Double, rowIndex: Int) {
                values.append(value)
                support.insert(rowIndex)
            }

            var center: Double {
                values.reduce(0, +) / Double(values.count)
            }
        }

        var bins: [AnchorBin] = []

        for (rowIndex, row) in rows.enumerated() {
            for observation in row.observations {
                let x = observation.boundingBox.x
                let tolerance = max(0.012, min(0.03, observation.boundingBox.width * 0.9))

                if let binIndex = bins.firstIndex(where: { abs($0.center - x) <= tolerance }) {
                    bins[binIndex].append(value: x, rowIndex: rowIndex)
                } else {
                    bins.append(AnchorBin(values: [x], support: [rowIndex]))
                }
            }
        }

        let minSupport = max(2, Int(ceil(Double(rows.count) * 0.45)))

        return bins
            .filter { $0.support.count >= minSupport }
            .map(\.center)
            .sorted()
    }

    private static func refineColumnAnchors(
        _ anchors: [Double],
        rows: [RowCluster],
        minX: Double,
        maxX: Double,
        averageCellWidth: Double
    ) -> [Double] {
        var refined = anchors.sorted()
        guard refined.count >= 2 else { return refined }

        var changed = true
        while changed {
            changed = false
            let bounds = xBounds(anchors: refined, minX: minX, maxX: maxX)

            for bound in bounds {
                let gapWidth = bound.upperBound - bound.lowerBound
                guard gapWidth >= max(averageCellWidth * 1.7, 0.12) else { continue }

                let clusters = centerClusters(in: rows, bound: bound, averageCellWidth: averageCellWidth)
                guard clusters.count >= 2 else { continue }

                for cluster in clusters.dropFirst() {
                    let candidate = cluster.center
                    guard candidate > bound.lowerBound + 0.03,
                          candidate < bound.upperBound - 0.03,
                          !refined.contains(where: { abs($0 - candidate) < 0.025 }) else {
                        continue
                    }

                    refined.append(candidate)
                    refined.sort()
                    changed = true
                }

                if changed {
                    break
                }
            }
        }

        return refined
    }

    private static func centerClusters(
        in rows: [RowCluster],
        bound: ClosedRange<Double>,
        averageCellWidth: Double
    ) -> [(center: Double, support: Int)] {
        struct CenterBin {
            var values: [Double]
            var support: Set<Int>

            mutating func append(_ value: Double, rowIndex: Int) {
                values.append(value)
                support.insert(rowIndex)
            }

            var center: Double {
                values.reduce(0, +) / Double(values.count)
            }
        }

        let tolerance = max(0.02, min(0.05, averageCellWidth * 0.9))
        var bins: [CenterBin] = []

        for (rowIndex, row) in rows.enumerated() {
            for observation in row.observations {
                let centerX = observation.boundingBox.x + (observation.boundingBox.width / 2)
                guard centerX >= bound.lowerBound && centerX <= bound.upperBound else { continue }

                if let binIndex = bins.firstIndex(where: { abs($0.center - centerX) <= tolerance }) {
                    bins[binIndex].append(centerX, rowIndex: rowIndex)
                } else {
                    bins.append(CenterBin(values: [centerX], support: [rowIndex]))
                }
            }
        }

        let minSupport = max(2, Int(ceil(Double(rows.count) * 0.4)))
        return bins
            .filter { $0.support.count >= minSupport }
            .map { ($0.center, $0.support.count) }
            .sorted { lhs, rhs in lhs.center < rhs.center }
    }

    private static func xBounds(
        anchors: [Double],
        minX: Double,
        maxX: Double
    ) -> [ClosedRange<Double>] {
        guard anchors.count >= 2 else { return [] }

        var bounds: [ClosedRange<Double>] = []
        for index in anchors.indices {
            let leftAnchor = anchors[index]
            let rightAnchor = index + 1 < anchors.count ? anchors[index + 1] : maxX
            let previousAnchor = index > 0 ? anchors[index - 1] : minX

            let lower = max(minX, leftAnchor - ((leftAnchor - previousAnchor) * 0.18))
            let upper = min(maxX, rightAnchor - ((rightAnchor - leftAnchor) * 0.08))

            if upper - lower > 0.012 {
                bounds.append(lower...upper)
            }
        }

        return bounds
    }

    private static func structureRows(_ observations: [Observation]) -> [RowCluster] {
        let seedOrder = observations.sorted { lhs, rhs in
            let lhsCenter = lhs.boundingBox.y + (lhs.boundingBox.height / 2)
            let rhsCenter = rhs.boundingBox.y + (rhs.boundingBox.height / 2)

            if abs(lhsCenter - rhsCenter) <= 0.0015 {
                return lhs.boundingBox.x < rhs.boundingBox.x
            }
            return lhsCenter < rhsCenter
        }

        var rows: [RowCluster] = []
        for observation in seedOrder {
            let center = observation.boundingBox.y + (observation.boundingBox.height / 2)

            if let rowIndex = rows.firstIndex(where: { row in
                let heightScale = max(row.averageHeight, observation.boundingBox.height)
                let verticalTolerance = max(0.0035, min(0.008, heightScale * 0.38))
                return abs(row.centerY - center) <= verticalTolerance
            }) {
                rows[rowIndex].append(observation)
            } else {
                rows.append(RowCluster(
                    observations: [observation],
                    centerY: center,
                    averageHeight: observation.boundingBox.height,
                    averageWidth: observation.boundingBox.width,
                    minY: observation.boundingBox.y,
                    maxY: observation.boundingBox.y + observation.boundingBox.height,
                    minX: observation.boundingBox.x,
                    maxX: observation.boundingBox.x + observation.boundingBox.width
                ))
            }
        }

        return rows.sorted { lhs, rhs in lhs.centerY < rhs.centerY }
    }

    private static func adaptiveRowTolerance(_ lhs: Observation, _ rhs: Observation) -> Double {
        let heightScale = max(lhs.boundingBox.height, rhs.boundingBox.height)
        return max(0.006, min(0.012, heightScale * 0.55))
    }
}
