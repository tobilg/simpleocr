import Foundation
import NaturalLanguage

enum PIIRedactor {
    static func redact(_ text: String) -> String {
        var redacted = text

        // 1. NLTagger: redact personal names, place names, organization names
        redacted = redactNamedEntities(redacted)

        // 2. NSDataDetector: redact phone numbers, emails, URLs, addresses, dates
        redacted = redactDataDetectorMatches(redacted)

        // 3. Regex: redact IBANs, credit card numbers, German tax IDs
        redacted = redactPatterns(redacted)

        return redacted
    }

    static func redact(observations: [Observation]) -> [Observation] {
        observations.map { obs in
            Observation(text: redact(obs.text), confidence: obs.confidence, boundingBox: obs.boundingBox)
        }
    }

    // MARK: - Named Entity Recognition

    private static func redactNamedEntities(_ text: String) -> String {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var ranges: [Range<String.Index>] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag = tag,
               tag == .personalName || tag == .organizationName {
                ranges.append(range)
            }
            return true
        }

        return replaceRanges(in: text, ranges: ranges, placeholder: "[REDACTED]")
    }

    // MARK: - NSDataDetector

    private static func redactDataDetectorMatches(_ text: String) -> String {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .link, .address]

        guard let detector = try? NSDataDetector(types: types.rawValue) else {
            return text
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)

        var ranges: [Range<String.Index>] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }

            switch match.resultType {
            case .phoneNumber:
                ranges.append(range)
            case .link:
                if let url = match.url, url.scheme == "mailto" {
                    ranges.append(range)
                }
            case .address:
                ranges.append(range)
            default:
                break
            }
        }

        return replaceRanges(in: text, ranges: ranges, placeholder: "[REDACTED]")
    }

    // MARK: - Regex Patterns

    private static let patterns: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            // IBAN (2 letter country code + 2 check digits + up to 30 alphanumeric, with optional spaces)
            (#"[A-Z]{2}\d{2}[\s]?[\dA-Z]{4}[\s]?(?:[\dA-Z]{4}[\s]?){1,7}[\dA-Z]{1,4}"#, "[IBAN]"),
            // Credit card numbers (13-19 digits, optionally separated by spaces or dashes)
            (#"\b(?:\d[\s-]?){13,19}\b"#, "[CREDIT_CARD]"),
            // German tax ID (Steuer-ID: 11 digits)
            (#"\b\d{2}\s?\d{3}\s?\d{3}\s?\d{3}\b"#, "[TAX_ID]"),
            // SSN (US: XXX-XX-XXXX)
            (#"\b\d{3}-\d{2}-\d{4}\b"#, "[SSN]"),
        ]

        return defs.compactMap { pattern, placeholder in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return (regex, placeholder)
        }
    }()

    private static func redactPatterns(_ text: String) -> String {
        var result = text

        for (regex, placeholder) in patterns {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)
            // Process in reverse order to preserve ranges
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: placeholder)
            }
        }

        return result
    }

    // MARK: - Helpers

    private static func replaceRanges(in text: String, ranges: [Range<String.Index>], placeholder: String) -> String {
        guard !ranges.isEmpty else { return text }

        // Sort ranges in reverse order so replacements don't invalidate indices
        let sorted = ranges.sorted { $0.lowerBound > $1.lowerBound }

        var result = text
        for range in sorted {
            result.replaceSubrange(range, with: placeholder)
        }
        return result
    }
}
