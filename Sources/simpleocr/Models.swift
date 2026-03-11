import Foundation

struct BoundingBox {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct Observation {
    let text: String
    let confidence: Float
    let boundingBox: BoundingBox
}

struct ImageSize {
    let width: Int
    let height: Int
}

struct OCRResult {
    let observations: [Observation]
    let imageSize: ImageSize
    let structuredRegions: [ObservationLayout.StructuredRegion]

    init(observations: [Observation], imageSize: ImageSize, structuredRegions: [ObservationLayout.StructuredRegion] = []) {
        self.observations = observations
        self.imageSize = imageSize
        self.structuredRegions = structuredRegions
    }
}

enum RecognitionMode: String {
    case accurate
    case fast
}

enum OutputFormat: String {
    case plain
    case text
    case json
    case tableJSON = "table-json"
    case pdfText = "pdf-text"
    case pdfImage = "pdf-image"

    var isPDF: Bool { self == .pdfText || self == .pdfImage }
}

enum CLIError: Error {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case ocrFailed(String)
    case pdfGenerationFailed(String)

    var exitCode: Int32 {
        switch self {
        case .fileNotFound: return 1
        case .unsupportedFormat: return 2
        case .ocrFailed: return 3
        case .pdfGenerationFailed: return 4
        }
    }

    var message: String {
        switch self {
        case .fileNotFound(let msg): return msg
        case .unsupportedFormat(let msg): return msg
        case .ocrFailed(let msg): return msg
        case .pdfGenerationFailed(let msg): return msg
        }
    }
}

// MARK: - JSON Output Types

struct JSONBoundingBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }
}

struct JSONObservation: Codable {
    let text: String
    let confidence: Double
    let boundingBox: JSONBoundingBox

    enum CodingKeys: String, CodingKey {
        case text
        case confidence
        case boundingBox = "bounding_box"
    }
}

struct JSONImageSize: Codable {
    let width: Int
    let height: Int
}

struct JSONStructuredCell: Codable {
    let columnIndex: Int
    let text: String
    let observationCount: Int
    let averageConfidence: Double
    let minConfidence: Double
    let maxConfidence: Double
    let boundingBox: JSONBoundingBox

    enum CodingKeys: String, CodingKey {
        case columnIndex = "column_index"
        case text
        case observationCount = "observation_count"
        case averageConfidence = "average_confidence"
        case minConfidence = "min_confidence"
        case maxConfidence = "max_confidence"
        case boundingBox = "bounding_box"
    }
}

struct JSONStructuredRow: Codable {
    let boundingBox: JSONBoundingBox
    let cellCount: Int
    let averageConfidence: Double
    let minConfidence: Double
    let maxConfidence: Double
    let cells: [JSONStructuredCell]

    enum CodingKeys: String, CodingKey {
        case boundingBox = "bounding_box"
        case cellCount = "cell_count"
        case averageConfidence = "average_confidence"
        case minConfidence = "min_confidence"
        case maxConfidence = "max_confidence"
        case cells
    }
}

struct JSONStructuredRegion: Codable {
    let boundingBox: JSONBoundingBox
    let rowCount: Int
    let columnAnchors: [Double]
    let averageConfidence: Double
    let minConfidence: Double
    let maxConfidence: Double
    let rows: [JSONStructuredRow]

    enum CodingKeys: String, CodingKey {
        case boundingBox = "bounding_box"
        case rowCount = "row_count"
        case columnAnchors = "column_anchors"
        case averageConfidence = "average_confidence"
        case minConfidence = "min_confidence"
        case maxConfidence = "max_confidence"
        case rows
    }
}

struct JSONOutput: Codable {
    let source: String
    let imageSize: JSONImageSize
    let languageHints: [String]
    let recognitionLevel: String
    let piiRedacted: Bool
    let observations: [JSONObservation]
    let structuredRegions: [JSONStructuredRegion]

    enum CodingKeys: String, CodingKey {
        case source
        case imageSize = "image_size"
        case languageHints = "language_hints"
        case recognitionLevel = "recognition_level"
        case piiRedacted = "pii_redacted"
        case observations
        case structuredRegions = "structured_regions"
    }
}

struct JSONTableOutput: Codable {
    let source: String
    let imageSize: JSONImageSize
    let languageHints: [String]
    let recognitionLevel: String
    let piiRedacted: Bool
    let tables: [JSONStructuredRegion]

    enum CodingKeys: String, CodingKey {
        case source
        case imageSize = "image_size"
        case languageHints = "language_hints"
        case recognitionLevel = "recognition_level"
        case piiRedacted = "pii_redacted"
        case tables
    }
}
