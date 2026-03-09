# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Build (debug) — uses local cache paths to avoid global cache writes
./scripts/build-local.sh

# Build (release)
./scripts/build-local.sh -c release

# Plain swift build works too if your toolchain/SDK match
swift build

# Run all tests
swift test

# Run a single test class
swift test --filter simpleocrTests.CLITests

# Run a single test method
swift test --filter simpleocrTests.CLITests/testParseReturnsHelpCommand

# Run the built binary
.build/debug/simpleocr <image-path> [options]
```

## Architecture

macOS CLI tool that performs OCR via Apple's Vision framework. Zero external dependencies — only system frameworks (Vision, CoreGraphics, CoreText, ImageIO, CoreImage, NaturalLanguage).

**Data flow:** `main.swift` → `CLI.parse()` → `CLI.resolve()` → `OCREngine.performOCR()` → output stage

- `CLI.swift` — Argument parsing (`parse`) and validation (`resolve`), returns typed `CLICommand`/`CLIConfiguration`. Also contains `execute()` which orchestrates the full pipeline.
- `OCREngine.swift` — Multi-pass Vision OCR. Pads images with 5% white borders (CIImage compositing) to catch edge text. Runs supplemental passes at 2-3x scale for small images to recover missed digits. Refines text observations by cropping and re-recognizing at multiple scales/image variants (original, grayscale+contrast, crisp).
- `ObservationLayout.swift` — Spatial analysis. Clusters observations into rows by y-coordinate tolerance, detects table-like structured regions (≥2 rows with ≥3 columns), infers column anchors from x-position consensus across rows.
- `OutputFormatter.swift` — Produces `text` (spatial coordinates + text), `json` (full observations + structured regions), or `table-json` (structured regions only) output.
- `PDFGenerator.swift` — Generates PDF using CoreGraphics/CoreText (no AppKit). Text-only PDF or image+invisible-text-overlay PDF. Uses row-based font sizing: groups observations by y-tolerance, computes median height, width consensus from 8+ char observations.
- `PIIRedactor.swift` — Three-layer redaction: NLTagger (personal/org names), NSDataDetector (phone/email/address), regex (IBAN, credit cards, tax IDs, SSN).
- `Models.swift` — All data types. Internal coordinate system uses top-left origin with normalized (0-1) coordinates. Vision's bottom-left origin is converted in `OCREngine.runRecognition()`.

**Coordinate systems:** Vision (bottom-left, normalized 0-1) → internal `BoundingBox` (top-left, normalized 0-1) → CoreGraphics (bottom-left, pixel coordinates in PDFGenerator).

## Testing

Tests are in `Tests/simpleocrTests/` using XCTest, guarded by `#if canImport(XCTest)`. Test files cover CLI parsing, output formatting, PII redaction, and structure heuristics. OCR tests that need Vision framework only run on macOS with actual image files.

## Release

Pushing a `v*` tag triggers `.github/workflows/release.yml` which builds on `macos-14` and publishes `simpleocr-macos-arm64.tar.gz` to GitHub Releases.
