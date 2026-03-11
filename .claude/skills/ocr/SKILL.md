---
name: ocr
description: Run local OCR on an image file using simpleocr. Use when the user wants to extract text from an image, read a screenshot, analyze a document, or get structured data from a photo.
argument-hint: <image-path> [--format plain|text|json|table-json]
allowed-tools: Bash(simpleocr *)
---

Run OCR on the specified image using `simpleocr`.

**Important:** `simpleocr` only works on macOS (it uses Apple's Vision framework). If the user is not on macOS, inform them that this skill is not available on their platform.

## Usage

```
/ocr <image-path> [options]
```

## Steps

1. Run: `simpleocr $ARGUMENTS`
   - If no `--format` is specified, use `--format plain` (best for LLM consumption).
   - If the command fails with "command not found", tell the user to install simpleocr via `brew install tobilg/simpleocr/simpleocr`.
2. Show the OCR output.
3. Briefly summarize what was recognized (number of text blocks, document type if obvious, any tables detected).

## Available formats

- `plain` — one line per text element, sorted top-to-bottom then left-to-right (default, best for LLMs)
- `text` — same as plain but with normalized `[y=,x=]` coordinates prepended
- `json` — full JSON with observations, bounding boxes, confidence scores, and structured regions
- `table-json` — JSON with only table-like structured regions and row/cell data

## Additional options

- `--lang <codes>` — comma-separated language codes (default: `de-DE,en-US`)
- `--mode fast` — faster but less accurate recognition
- `--pii` — redact personally identifiable information
- `--min-confidence <val>` — minimum confidence threshold 0.0-1.0 (default: 0.3)
- `--error-format json` — machine-readable error output

## Examples

```
/ocr screenshot.png
/ocr invoice.pdf --format json
/ocr photo.heic --format table-json --lang en-US
/ocr receipt.jpg --pii --format plain
```
