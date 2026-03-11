import Foundation

let version = "0.1.3"

let supportedExtensions: Set<String> = [
    "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "bmp", "gif"
]

let usage = """
Usage: simpleocr <image-path> [options]
       simpleocr - [options]              (read image from stdin)

Arguments:
  image-path              Path to input image file (use "-" for stdin)

Options:
  --lang <codes>          Comma-separated language codes (default: de-DE,en-US)
  --mode <level>          Recognition level: accurate or fast (default: accurate)
  --format <type>         Output format: plain, text, json, table-json, pdf-text, or pdf-image (default: text)
  --output <path>         Output file path for PDF formats (defaults to input name with .pdf)
  --min-confidence <val>  Minimum confidence threshold (default: 0.3)
  --pii                   Redact personally identifiable information from output
  --error-format <type>   Error output format: text or json (default: text)
  --describe-formats      Describe available output formats and exit
  --version               Print version and exit
  --help, -h              Print this help and exit
"""

let formatDescriptions = """
Available output formats:

  plain       Plain text output, one line per recognized text element, sorted
              top-to-bottom then left-to-right. Best for feeding into LLMs or
              other text processing tools.
              Example:
                Firmenname
                Ihr Partner in Sachen Dienstleistungen!

  text        Spatially-aware text with normalized coordinates (y,x) prepended
              to each line. Useful when position matters.
              Example:
                [y=0.08,x=0.06] Firmenname
                [y=0.11,x=0.06] Ihr Partner in Sachen Dienstleistungen!

  json        Full JSON output with all observations, bounding boxes, confidence
              scores, and inferred structured regions. Includes image metadata.
              Schema: { source, image_size, language_hints, recognition_level,
                        pii_redacted, observations[], structured_regions[] }

  table-json  JSON output containing only inferred table-like structured regions
              with row/cell structure derived from spatial layout analysis.
              Schema: { source, image_size, language_hints, recognition_level,
                        pii_redacted, tables[] }

  pdf-text    Generates a PDF with rendered OCR text only. Writes to --output
              path or defaults to input filename with .pdf extension.

  pdf-image   Generates a PDF with the original image and an invisible text
              overlay for search and copy/paste. Writes to --output path or
              defaults to input filename with .pdf extension.

Exit codes:
  0  Success
  1  Invalid arguments or file not found
  2  Unsupported image format
  3  OCR processing failed
  4  PDF generation failed
"""

enum ErrorFormat: String {
    case text
    case json
}

struct CLIConfiguration: Equatable {
    let imagePath: String
    let languages: [String]
    let mode: RecognitionMode
    let outputFormat: OutputFormat
    let minConfidence: Float
    let redactPII: Bool
    let outputPath: String?
    let errorFormat: ErrorFormat
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
    case describeFormats
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
        var errorFormat: ErrorFormat = .text

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]

            switch arg {
            case "--help", "-h":
                return .help

            case "--version":
                return .version

            case "--describe-formats":
                return .describeFormats

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
                        message: "Error: --format must be 'plain', 'text', 'json', 'table-json', 'pdf-text', or 'pdf-image'",
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

            case "--error-format":
                index += 1
                guard index < arguments.count else {
                    throw CLIUserError(message: "Error: --error-format requires a value", exitCode: 1)
                }
                guard let parsedErrorFormat = ErrorFormat(rawValue: arguments[index]) else {
                    throw CLIUserError(message: "Error: --error-format must be 'text' or 'json'", exitCode: 1)
                }
                errorFormat = parsedErrorFormat

            default:
                if arg.hasPrefix("-") && arg != "-" {
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
            outputPath: outputPath,
            errorFormat: errorFormat
        ))
    }

    static func resolve(configuration: CLIConfiguration) throws -> ResolvedCLIConfiguration {
        let expandedPath: String
        let fileURL: URL

        if configuration.imagePath == "-" {
            // Read image data from stdin and write to a temp file
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            guard !stdinData.isEmpty else {
                throw CLIUserError(message: "Error: No data received on stdin", exitCode: 1)
            }
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("simpleocr-stdin-\(ProcessInfo.processInfo.processIdentifier).png")
            try stdinData.write(to: tempURL)
            expandedPath = tempURL.path
            fileURL = tempURL
        } else {
            expandedPath = NSString(string: configuration.imagePath).expandingTildeInPath
            fileURL = URL(fileURLWithPath: expandedPath)

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
        }

        let outputPath: String?
        if configuration.outputFormat.isPDF && configuration.outputPath == nil {
            if configuration.imagePath == "-" {
                throw CLIUserError(
                    message: "Error: --output is required when reading from stdin with PDF format",
                    exitCode: 1
                )
            }
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
        // Pre-scan for --error-format to use it in error handling
        let useJSONErrors: Bool = {
            guard let idx = arguments.firstIndex(of: "--error-format"),
                  idx + 1 < arguments.count else { return false }
            return arguments[idx + 1] == "json"
        }()

        do {
            let command = try parse(arguments: arguments)
            switch command {
            case .help:
                stdout(usage)
                return 0

            case .version:
                stdout("simpleocr \(version)")
                return 0

            case .describeFormats:
                stdout(formatDescriptions)
                return 0

            case .run(let configuration):
                let resolved = try resolve(configuration: configuration)
                var result = try OCREngine.performOCR(
                    on: resolved.fileURL,
                    languages: resolved.languages,
                    mode: resolved.mode,
                    minConfidence: resolved.minConfidence,
                    outputFormat: resolved.outputFormat
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
            if useJSONErrors {
                stderr(jsonError(error.message, code: error.exitCode))
            } else {
                stderr(error.message)
            }
            return error.exitCode
        } catch let error as CLIError {
            if useJSONErrors {
                stderr(jsonError(error.message, code: error.exitCode))
            } else {
                stderr("Error: \(error.message)")
            }
            return error.exitCode
        } catch {
            if useJSONErrors {
                stderr(jsonError(error.localizedDescription, code: 3))
            } else {
                stderr("Error: \(error.localizedDescription)")
            }
            return 3
        }
    }

    private static func jsonError(_ message: String, code: Int32) -> String {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{\"error\":\"\(escaped)\",\"code\":\(code)}"
    }
}
