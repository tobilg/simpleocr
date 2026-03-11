# simpleocr

`simpleocr` is a macOS OCR CLI written in Swift for image-to-text workflows in local AI pipelines, meaning no data has to be send to the model providers.

It uses Apple's Vision framework, has no third-party dependencies, and is designed to produce output that is easy to pipe into downstream LLM or automation steps.

## Features

- OCR for local image files on macOS
- Spatially aware plain-text output for LLM consumption
- Structured JSON output with normalized bounding boxes
- Table-focused JSON output derived from generic layout heuristics
- Searchable PDF generation:
  - `pdf-text`: text-only PDF
  - `pdf-image`: original image plus invisible text layer
- Optional PII redaction for recognized text
- No network dependency and no cloud OCR service

## Requirements

- macOS 13 or newer

## Install

```bash
brew install tobilg/simpleocr/simpleocr
```

## Usage

```bash
simpleocr <image-path> [options]
simpleocr - [options]              # read image from stdin
```

### Arguments

- `image-path`: path to the input image file (use `-` to read from stdin)

### Options

- `--lang <codes>`: comma-separated language codes, default `de-DE,en-US`
- `--mode <level>`: `accurate` or `fast`, default `accurate`
- `--format <type>`: `plain`, `text`, `json`, `table-json`, `pdf-text`, or `pdf-image`, default `text`
- `--output <path>`: output file path for PDF formats; defaults to the input basename with `.pdf`
- `--min-confidence <val>`: minimum confidence threshold between `0.0` and `1.0`, default `0.3`
- `--pii`: redact personally identifiable information from recognized text
- `--error-format <type>`: error output format: `text` or `json`, default `text`
- `--describe-formats`: describe available output formats and exit
- `--version`: print version and exit
- `--help`, `-h`: print help and exit

### Supported Input Formats

- `jpg`, `jpeg`
- `png`
- `tiff`, `tif`
- `heic`, `heif`
- `bmp`
- `gif`

## Examples

Basic OCR (plain text, best for LLMs):

```bash
simpleocr examples/example-bill.png --format plain
```

OCR with spatial coordinates:

```bash
simpleocr examples/example-bill.png
```

JSON output:

```bash
simpleocr examples/example-bill.png --format json
```

Table-focused JSON output:

```bash
simpleocr examples/example-bill.png --format table-json
```

Fast mode with German-first language hints:

```bash
simpleocr examples/example-bill.png --lang de-DE,en-US --mode fast
```

Generate a searchable image PDF:

```bash
simpleocr examples/example-bill.png --format pdf-image --output bill-searchable.pdf
```

Redact PII before returning text:

```bash
simpleocr examples/example-bill.png --pii
```

Read image from stdin:

```bash
cat screenshot.png | simpleocr - --format plain
```

JSON errors for programmatic consumption:

```bash
simpleocr missing.png --error-format json
# stderr: {"error":"Error: File not found or unreadable: missing.png","code":1}
```

Describe available output formats:

```bash
simpleocr --describe-formats
```

## Output Formats

### `plain`

Plain text output, one line per recognized text element, sorted top-to-bottom then left-to-right. Best for feeding into LLMs or other text processing tools.

Example:

```text
Muster GmbH
Industriestrasse 42, 80331 Munchen
```

### `text`

Spatially-aware text with normalized coordinates (y,x) prepended to each line. Useful when position matters.

Example:

```text
[y=0.08,x=0.06] Muster GmbH
[y=0.11,x=0.06] Industriestrasse 42, 80331 Munchen
```

### `json`

Returns document metadata, recognized observations, and inferred structured regions:

```json
{
  "image_size": {
    "height": 3508,
    "width": 2480
  },
  "language_hints": [
    "de-DE",
    "en-US"
  ],
  "observations": [
    {
      "bounding_box": {
        "height": 0.03,
        "width": 0.22,
        "x": 0.06,
        "y": 0.08
      },
      "confidence": 0.98,
      "text": "Muster GmbH"
    }
  ],
  "pii_redacted": false,
  "recognition_level": "accurate",
  "source": "invoice.png"
}
```

### `table-json`

Returns only inferred table-like regions with row and cell structure derived from geometry:

```json
{
  "image_size": {
    "height": 1161,
    "width": 796
  },
  "language_hints": [
    "de-DE",
    "en-US"
  ],
  "pii_redacted": false,
  "recognition_level": "accurate",
  "source": "example-bill.png",
  "tables": [
    {
      "column_anchors": [0.1, 0.14, 0.49, 0.59, 0.74, 0.82],
      "row_count": 2
    }
  ]
}
```

### `pdf-text`

Creates a PDF page containing rendered OCR text only.

### `pdf-image`

Creates a PDF containing the original image with an invisible text layer for search and copy/paste.

## Claude Code Skill

This repo includes a [Claude Code](https://claude.ai/claude-code) skill that lets coding agents run OCR directly:

```
/ocr examples/example-bill.png
/ocr screenshot.png --format json
```

The skill is defined in `.claude/skills/ocr/SKILL.md` and is available automatically when Claude Code is used in this project.

To use the skill in other projects, install it to your personal skills directory:

```bash
mkdir -p ~/.claude/skills/ocr
curl -fsSL https://raw.githubusercontent.com/tobilg/simpleocr/main/.claude/skills/ocr/SKILL.md -o ~/.claude/skills/ocr/SKILL.md
```

## Development

### Build from source

Use the wrapper script so SwiftPM and Clang caches stay inside the repository:

```bash
./scripts/build-local.sh
```

Release build:

```bash
./scripts/build-local.sh -c release
```

## Troubleshooting

### Swift / SDK version mismatch

If you see an error like:

```text
this SDK is not supported by the compiler
```

your selected Swift toolchain and the active Apple SDK do not match. Fix it by:

1. installing a matching Xcode version
2. selecting the matching developer directory with `xcode-select`
3. rerunning `./scripts/build-local.sh`

### Sandbox cache warnings

The wrapper script exports local cache paths:

- `SWIFTPM_MODULECACHE_OVERRIDE=.build/module-cache`
- `CLANG_MODULE_CACHE_PATH=.build/clang-module-cache`

That avoids writing to global cache locations during local or sandboxed builds.
If plain `swift build` already works on your machine, you can keep using it.

## Project Layout

```text
Package.swift
README.md
.claude/skills/ocr/SKILL.md
Sources/simpleocr/main.swift
Sources/simpleocr/CLI.swift
Sources/simpleocr/Models.swift
Sources/simpleocr/ObservationLayout.swift
Sources/simpleocr/OCREngine.swift
Sources/simpleocr/OutputFormatter.swift
Sources/simpleocr/PDFGenerator.swift
Sources/simpleocr/PIIRedactor.swift
Tests/simpleocrTests/
requirements/ocr-cli-prd.md
examples/example-bill.png
```
