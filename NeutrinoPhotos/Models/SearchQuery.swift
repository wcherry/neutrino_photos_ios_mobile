import Foundation

// MARK: - SearchQuery

/// What somebody typed into Search, taken apart into the filters it names and the text left over.
///
/// "june 2024 videos" is a date, a kind and no text; "iPhone 15 Pro" is text only; "canon 2023" is
/// both. Parsing happens once per keystroke, and what is not recognised as a filter is matched
/// against the library as text — so a word this does not know is never thrown away, only searched
/// for.
///
/// Dates are read in the forms people actually type ("2023", "June 2024", "jun", "last week",
/// "2024-06-01") rather than in a syntax they would have to learn.
struct SearchQuery: Equatable {

    /// The words that were not a filter, lowercased and single-spaced.
    var text: String = ""
    /// Items whose timeline date falls in this range.
    var dateRange: DateInterval?
    /// Items from this month in *any* year — "june" on its own, which is how somebody asks for
    /// every summer at once.
    var monthOfAnyYear: Int?
    var kind: MediaItem.Kind?
    var favoritesOnly = false

    /// True when nothing at all was asked for.
    var isEmpty: Bool {
        text.isEmpty && dateRange == nil && monthOfAnyYear == nil && kind == nil && !favoritesOnly
    }

    /// The free text split into words, for matching each on its own.
    var words: [String] {
        text.split(separator: " ").map(String.init)
    }

    // MARK: - Parsing

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        let tokens = raw.lowercased()
            .components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
        var leftover: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil

            // Two-word relative dates first, so "last week" is not read as the text "last" and a
            // stray "week".
            if let next, let range = relativeRange(token, next, now: now, calendar: calendar) {
                query.dateRange = range
                index += 2
                continue
            }
            if let range = relativeRange(token, now: now, calendar: calendar) {
                query.dateRange = range
                index += 1
                continue
            }

            if let month = monthNumber(token) {
                // "june 2024", or "june" alone for every June.
                if let next, let year = year(next) {
                    query.dateRange = monthRange(year: year, month: month, calendar: calendar)
                    query.monthOfAnyYear = nil
                    index += 2
                } else {
                    query.monthOfAnyYear = month
                    query.dateRange = nil
                    index += 1
                }
                continue
            }

            if let year = year(token) {
                // "2024 june" reads the same as "june 2024".
                if let next, let month = monthNumber(next) {
                    query.dateRange = monthRange(year: year, month: month, calendar: calendar)
                    index += 2
                } else {
                    query.dateRange = yearRange(year, calendar: calendar)
                    index += 1
                }
                query.monthOfAnyYear = nil
                continue
            }

            if let range = isoRange(token, calendar: calendar) {
                query.dateRange = range
                query.monthOfAnyYear = nil
                index += 1
                continue
            }

            switch token {
            case "video", "videos":
                query.kind = .video
            case "photo", "photos", "picture", "pictures":
                query.kind = .photo
            case "favorite", "favorites", "favourite", "favourites", "starred", "loved":
                query.favoritesOnly = true
            default:
                leftover.append(token)
            }
            index += 1
        }

        query.text = leftover.joined(separator: " ")
        return query
    }

    // MARK: - Dates

    private static let months: [String: Int] = {
        var result: [String: Int] = [:]
        let names = ["january", "february", "march", "april", "may", "june", "july", "august",
                     "september", "october", "november", "december"]
        for (offset, name) in names.enumerated() {
            result[name] = offset + 1
            result[String(name.prefix(3))] = offset + 1
        }
        result["sept"] = 9
        return result
    }()

    static func monthNumber(_ token: String) -> Int? {
        months[token.trimmingCharacters(in: CharacterSet(charactersIn: "."))]
    }

    /// A four-digit year a photograph could plausibly be from. Narrower than "any four digits" so
    /// that searching for a file called 4032 does not ask for the year 4032.
    static func year(_ token: String) -> Int? {
        guard token.count == 4, let value = Int(token), (1826...2200).contains(value) else {
            return nil
        }
        return value
    }

    static func yearRange(_ year: Int, calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return nil
        }
        return calendar.dateInterval(of: .year, for: start)
    }

    static func monthRange(year: Int, month: Int, calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return nil
        }
        return calendar.dateInterval(of: .month, for: start)
    }

    /// "2024-06-01" is that day; "2024-06" is that month.
    private static func isoRange(_ token: String, calendar: Calendar) -> DateInterval? {
        let parts = token.split(separator: "-").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              let year = year(parts[0]),
              let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        if parts.count == 2 { return monthRange(year: year, month: month, calendar: calendar) }
        guard let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day else { return nil }
        return calendar.dateInterval(of: .day, for: date)
    }

    private static func relativeRange(_ token: String, now: Date,
                                      calendar: Calendar) -> DateInterval? {
        switch token {
        case "today":
            return calendar.dateInterval(of: .day, for: now)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: now)
                .flatMap { calendar.dateInterval(of: .day, for: $0) }
        default:
            return nil
        }
    }

    /// "this week", "last month", "last year" — calendar periods, not rolling windows: "last
    /// week" on a Wednesday is the whole of the previous week, which is what people mean by it.
    private static func relativeRange(_ first: String, _ second: String, now: Date,
                                      calendar: Calendar) -> DateInterval? {
        let component: Calendar.Component
        switch second {
        case "week":  component = .weekOfYear
        case "month": component = .month
        case "year":  component = .year
        default:      return nil
        }
        let offset: Int
        switch first {
        case "this": offset = 0
        case "last", "past", "previous": offset = -1
        default: return nil
        }
        guard let anchor = calendar.date(byAdding: component, value: offset, to: now) else {
            return nil
        }
        return calendar.dateInterval(of: component, for: anchor)
    }
}
