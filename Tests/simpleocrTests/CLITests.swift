#if canImport(XCTest)
import Foundation
import XCTest
@testable import simpleocr

final class CLITests: XCTestCase {
    func testParseReturnsHelpCommand() throws {
        XCTAssertEqual(try CLI.parse(arguments: ["--help"]), .help)
    }

    func testParseReturnsVersionCommand() throws {
        XCTAssertEqual(try CLI.parse(arguments: ["--version"]), .version)
    }

    func testParseBuildsConfiguration() throws {
        let command = try CLI.parse(arguments: [
            "invoice.png",
            "--lang", "en-US,de-DE",
            "--mode", "fast",
            "--format", "json",
            "--min-confidence", "0.8",
            "--pii"
        ])

        XCTAssertEqual(command, .run(CLIConfiguration(
            imagePath: "invoice.png",
            languages: ["en-US", "de-DE"],
            mode: .fast,
            outputFormat: .json,
            minConfidence: 0.8,
            redactPII: true,
            outputPath: nil,
            errorFormat: .text
        )))
    }

    func testParseAcceptsTableJSONFormat() throws {
        let command = try CLI.parse(arguments: [
            "invoice.png",
            "--format", "table-json"
        ])

        XCTAssertEqual(command, .run(CLIConfiguration(
            imagePath: "invoice.png",
            languages: ["de-DE", "en-US"],
            mode: .accurate,
            outputFormat: .tableJSON,
            minConfidence: 0.3,
            redactPII: false,
            outputPath: nil,
            errorFormat: .text
        )))
    }

    func testParseRejectsOutOfRangeMinConfidence() {
        XCTAssertThrowsError(try CLI.parse(arguments: ["invoice.png", "--min-confidence", "1.5"])) { error in
            let userError = try XCTUnwrap(error as? CLIUserError)
            XCTAssertEqual(userError.exitCode, 1)
            XCTAssertEqual(userError.message, "Error: --min-confidence must be between 0.0 and 1.0")
        }
    }

    func testParseRejectsUnknownOption() {
        XCTAssertThrowsError(try CLI.parse(arguments: ["invoice.png", "--bogus"])) { error in
            let userError = try XCTUnwrap(error as? CLIUserError)
            XCTAssertEqual(userError.exitCode, 1)
            XCTAssertEqual(userError.message, "Error: Unknown option '--bogus'")
        }
    }

    func testResolveDefaultsPdfOutputPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("scan.png")
        FileManager.default.createFile(atPath: inputURL.path, contents: Data())

        let resolved = try CLI.resolve(configuration: CLIConfiguration(
            imagePath: inputURL.path,
            languages: ["de-DE", "en-US"],
            mode: .accurate,
            outputFormat: .pdfImage,
            minConfidence: 0.3,
            redactPII: false,
            outputPath: nil,
            errorFormat: .text
        ))

        XCTAssertEqual(resolved.outputPath, tempDir.appendingPathComponent("scan.pdf").path)
    }

    func testResolveRejectsUnsupportedExtension() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: inputURL.path, contents: Data("hello".utf8))

        XCTAssertThrowsError(try CLI.resolve(configuration: CLIConfiguration(
            imagePath: inputURL.path,
            languages: ["en-US"],
            mode: .accurate,
            outputFormat: .text,
            minConfidence: 0.3,
            redactPII: false,
            outputPath: nil,
            errorFormat: .text
        ))) { error in
            let userError = try XCTUnwrap(error as? CLIUserError)
            XCTAssertEqual(userError.exitCode, 2)
            XCTAssertTrue(userError.message.contains("Unsupported image format '.txt'"))
        }
    }
}
#endif
