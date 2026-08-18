import Foundation

// MARK: - DriveDate

/// Parses the timestamp formats the Neutrino APIs emit.
///
/// The server is not consistent about this, because different endpoints serialize different Rust
/// types. Drive's file and folder payloads carry `NaiveDateTime` — no zone, microsecond precision
/// (`2026-07-30T14:25:36.123456`). The Photos endpoints call `to_rfc3339()`, which adds a zone and
/// up to nine fractional digits (`2026-07-30T14:25:36.123456789+00:00`).
///
/// Rather than listing a `DateFormatter` per shape and hoping the first match wins, the input is
/// split into date-time / fraction / zone, the fraction normalized to milliseconds, and the result
/// parsed with exactly one formatter. Zone-less timestamps are read as UTC, which is what the
/// server means by them.
enum DriveDate {

    // MARK: - Parsing

    static func date(from raw: String) -> Date? {
        // "2026-07-30T14:25:36" is 19 characters; anything shorter can't be a timestamp.
        guard raw.count >= 19 else { return nil }

        var body = raw
        var zone = ""

        if body.hasSuffix("Z") || body.hasSuffix("z") {
            zone = "Z"
            body.removeLast()
        } else if let offsetStart = body.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  body.distance(from: body.startIndex, to: offsetStart) > 10 {
            // Guarded past index 10 so the hyphens in the date itself aren't mistaken for a zone.
            zone = String(body[offsetStart...])
            body = String(body[..<offsetStart])
        }

        var fraction = "000"
        if let dot = body.firstIndex(of: ".") {
            let digits = body[body.index(after: dot)...]
            guard digits.allSatisfy(\.isNumber) else { return nil }
            // Sub-millisecond precision is discarded; Date can't represent it usefully and
            // nothing in the app compares timestamps that finely.
            fraction = String((digits + "000").prefix(3))
            body = String(body[..<dot])
        }

        let normalized = body + "." + fraction + zone
        return (zone.isEmpty ? naiveFormatter : zonedFormatter).date(from: normalized)
    }

    // MARK: - Formatting

    /// The shape `POST /api/v1/photos` parses a capture date out of.
    ///
    /// The server reads it with `chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S")`,
    /// which accepts *exactly* that: no fractional seconds, no zone suffix. An ISO 8601 string with
    /// either would silently fail to parse and the photo would be filed under its upload time
    /// instead of the moment it was taken — so this formatter, not `ISO8601DateFormatter`.
    static func naiveUTCString(from date: Date) -> String {
        naiveWriteFormatter.string(from: date)
    }

    // MARK: - Decoding

    /// A `JSONDecoder` that reads every Neutrino timestamp shape. Not shared as a single instance
    /// because callers differ in their key strategies.
    static func makeDecoder(convertFromSnakeCase: Bool = false,
                            onFailure: ((String) -> Void)? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        if convertFromSnakeCase {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = DriveDate.date(from: raw) else {
                onFailure?(raw)
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Cannot parse date: \(raw)"
                ))
            }
            return date
        }
        return decoder
    }

    // MARK: - Formatters

    private static let zonedFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX")
    private static let naiveFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS")
    private static let naiveWriteFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ss")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }
}
