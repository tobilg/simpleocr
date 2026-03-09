import Foundation

let version = "0.1.0"

let supportedExtensions: Set<String> = [
    "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "bmp", "gif"
]

let usage = """
Usage: simpleocr <image-path> [options]

Arguments:
  image-path              Path to input image file

Options:
  --lang <codes>          Comma-separated language codes (default: de-DE,en-US)
  --mode <level>          Recognition level: accurate or fast (default: accurate)
  --format <type>         Output format: text, json, table-json, pdf-text, or pdf-image (default: text)
  --output <path>         Output file path for PDF formats (defaults to input name with .pdf)
  --min-confidence <val>  Minimum confidence threshold (default: 0.3)
  --pii                   Redact personally identifiable information from output
  --version               Print version and exit
  --help, -h              Print this help and exit
"""

struct CLIConfiguration: Equatable {
    let imagePath: String
    let languages: [String]
    let mode: RecognitionMode
    let outputFormat: OutputFormat
    let minConfidence: Float
    let redactPII: Bool
    let outputPath: String?
}

struct ResolvedCLIConfiguration: Equatable {
    let expandedPath: String
    let fileURL: URL
    let languages: [String]
    let mode: RecognitionMode
    let outputFormat: OutputFormat
    let minConfidence: Float
    let redactPII: Bool
    let outputPath: String?
}

enum CLICommand: Equatable {
    case help
    case version
    case run(CLIConfiguration)
}

struct CLIUserError: Error {
    let message: String
    let exitCode: Int32
}

func printError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}

enum CLI {
    static func parse(arguments: [String]) throws -> CLICommand {
        var imagePath: String?
        var languages = ["de-DE", "en-US"]
        var mode: RecognitionMode = .accurate
        var outputFormat: OutputFormat = .text
        var minConfidence: Float = 0.3
        var redactPII = false
        var outputPath: String?

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]

            switch arg {
            case "--help", "-h":
                return .help

            case "--version":
                return .version

            case "--lang":
                index += 1
                guard index < arguments.count else {
                    throw CLIUserError(message: "Error: --lang requires a value", exitCode: 1)
                }

                languages = arguments[index].split(separator: ",").map(String.init)
                guard !languages.isEmpty else {
                    throw CLIUserError(message: "Error: --lang requires at least one language code", exitCode: 1)
                }

            case "--mode":
                index += 1
                guard index < arguments.count else {
                    throw CLIUserError(message: "Error: --mode requires a value", exitCode: 1)
                }
                guard let parsedMode = RecognitionMode(rawValue: arguments[index]) else {
                    throw CLIUserError(message: "Error: --mode must be 'accurate' or 'fast'", exitCode: 1)
                }
                mode = parsedMode

            case "--format":
                index += 1
                guard index < arguments.count else {
                    throw CLIUserError(message: "Error: --format requires a value", exitCode: 1)
                }
                guard let parsedFormat = OutputFormat(rawValue: arguments[index]) else {
                    throw CLIUserError(
                        message: "Error: --format must be 'text', 'json', 'table-json', 'pdf-text', or 'pdf-image'",
                        exitCode: 1
                    )
                }
                outputFormat = parsedFormat

            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIUserError(message: "Error: --output requires a value", exitCode: 1)
                }
                outputPath = arguments[index]

            case "--min-confidence":
                index += 1
                guard index < arguments.count else {
                    throw CLIUserError(message: "Error: --min-confidence requires a value", exitCode: 1)
                }
                guard let parsedConfidence = Float(arguments[index]) else {
                    throw CLIUserError(message: "Error: --min-confidence must be a number", exitCode: 1)
                }
                guard (0...1).contains(parsedConfidence) else {
                    throw CLIUserError(message: "Error: --min-confidence must be between 0.0 and 1.0", exitCode: 1)
                }
                minConfidence = parsedConfidence

            case "--pii":
                redactPII = true

            default:
                if arg.hasPrefix("-") {
                    throw CLIUserError(message: "Error: Unknown option '\(arg)'", exitCode: 1)
                }
                if imagePath == nil {
                    imagePath = arg
                } else {
                    throw CLIUserError(message: "Error: Unexpected argument '\(arg)'", exitCode: 1)
                }
            }

            index += 1
        }

        guard let imagePath else {
            throw CLIUserError(message: usage, exitCode: 1)
        }

        return .run(CLIConfiguration(
            imagePath: imagePath,
            languages: languages,
            mode: mode,
            outputFormat: outputFormat,
            minConfidence: minConfidence,
            redactPII: redactPII,
            outputPath: outputPath
        ))
    }

    static func resolve(configuration: CLIConfiguration) throws -> ResolvedCLIConfiguration {
        let expandedPath = NSString(string: configuration.imagePath).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.isReadableFile(atPath: expandedPath) else {
            throw CLIUserError(
                message: "Error: File not found or unreadable: \(configuration.imagePath)",
                exitCode: 1
            )
        }

        let ext = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw CLIUserError(
                message: "Error: Unsupported image format '.\(ext)'. Supported: jpg, jpeg, png, tiff, tif, heic, heif, bmp, gif",
                exitCode: 2
            )
        }

        let outputPath: String?
        if configuration.outputFormat.isPDF && configuration.outputPath == nil {
            outputPath = URL(fileURLWithPath: expandedPath)
                .deletingPathExtension()
                .appendingPathExtension("pdf").path
        } else {
            outputPath = configuration.outputPath
        }

        return ResolvedCLIConfiguration(
            expandedPath: expandedPath,
            fileURL: fileURL,
            languages: configuration.languages,
            mode: configuration.mode,
            outputFormat: configuration.outputFormat,
            minConfidence: configuration.minConfidence,
            redactPII: configuration.redactPII,
            outputPath: outputPath
        )
    }

    static func execute(
        arguments: [String],
        stdout: (String) -> Void = { Swift.print($0) },
        stderr: (String) -> Void = printError
    ) -> Int32 {
        do {
            let command = try parse(arguments: arguments)
            switch command {
            case .help:
                stdout(usage)
                return 0

            case .version:
                stdout("simpleocr \(version)")
                return 0

            case .run(let configuration):
                let resolved = try resolve(configuration: configuration)
                var result = try OCREngine.performOCR(
                    on: resolved.fileURL,
                    languages: resolved.languages,
                    mode: resolved.mode,
                    minConfidence: resolved.minConfidence
                )

                if resolved.redactPII {
                    result = OCRResult(
                        observations: PIIRedactor.redact(observations: result.observations),
                        imageSize: result.imageSize,
                        structuredRegions: result.structuredRegions
                    )
                }

                if resolved.outputFormat.isPDF {
                    let pdfData: Data
                    switch resolved.outputFormat {
                    case .pdfText:
                        pdfData = try PDFGenerator.generateTextPDF(result: result)
                    case .pdfImage:
                        pdfData = try PDFGenerator.generateImagePDF(result: result, imageURL: resolved.fileURL)
                    default:
                        fatalError("Unreachable")
                    }

                    do {
                        try pdfData.write(to: URL(fileURLWithPath: resolved.outputPath!))
                    } catch {
                        throw CLIError.pdfGenerationFailed("Failed to write PDF: \(error.localizedDescription)")
                    }
                    stderr("PDF written to: \(resolved.outputPath!)")
                } else {
                    let output = try OutputFormatter.format(
                        result: result,
                        as: resolved.outputFormat,
                        source: resolved.expandedPath,
                        languages: resolved.languages,
                        mode: resolved.mode,
                        piiRedacted: resolved.redactPII
                    )
                    stdout(output)
                }

                return 0
            }
        } catch let error as CLIUserError {
            stderr(error.message)
            return error.exitCode
        } catch let error as CLIError {
            stderr("Error: \(error.message)")
            return error.exitCode
        } catch {
            stderr("Error: \(error.localizedDescription)")
            return 3
        }
    }
}
