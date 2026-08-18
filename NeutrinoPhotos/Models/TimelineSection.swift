import Foundation

// MARK: - TimelineGrouping

/// How densely the timeline is grouped — the Photos app's Days / Months / Years switch.
enum TimelineGrouping: String, CaseIterable, Identifiable, Codable {
    case day
    case month
    case year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day:   return "Days"
        case .month: return "Months"
        case .year:  return "Years"
        }
    }

    /// The calendar components that decide whether two photographs share a section.
    var components: Set<Calendar.Component> {
        switch self {
        case .day:   return [.year, .month, .day]
        case .month: return [.year, .month]
        case .year:  return [.year]
        }
    }

    /// How many columns the grid uses at this density. Zooming out shows more, smaller pictures,
    /// which is what makes Years navigable at all on a phone.
    var columnCount: Int {
        switch self {
        case .day:   return 3
        case .month: return 4
        case .year:  return 5
        }
    }
}

// MARK: - TimelineSection

/// A run of library items that share a day, month, or year, newest first.
///
/// Grouping is pure and lives here rather than in the view so it can be asserted directly: a
/// section boundary that lands an hour out — the classic UTC-versus-local mistake with capture
/// dates — is invisible in a screenshot and obvious in a test.
struct TimelineSection: Identifiable, Hashable {

    // MARK: - Properties

    /// Stable across reloads: derived from the grouping and the section's start instant, so
    /// SwiftUI keeps scroll position when the library refreshes underneath it.
    let id: String
    /// The first instant of the day, month, or year this section covers.
    let start: Date
    /// "Today", "12 August 2026", "August 2026", "2026".
    let title: String
    let items: [MediaItem]

    // MARK: - Grouping

    /// Groups `items` into sections, newest first, by their ``MediaItem/timelineDate``.
    ///
    /// - Parameters:
    ///   - calendar: supplied so tests can pin the time zone. The default is the device's, which is
    ///     the right answer for a photo library: a picture taken at 11pm belongs to the evening the
    ///     photographer remembers, not to the UTC day it happened to fall in.
    ///   - now: what "Today" and "Yesterday" are relative to.
    static func sections(from items: [MediaItem],
                         grouping: TimelineGrouping,
                         calendar: Calendar = .current,
                         now: Date = Date()) -> [TimelineSection] {
        var buckets: [Date: [MediaItem]] = [:]
        for item in items {
            let components = calendar.dateComponents(grouping.components, from: item.timelineDate)
            guard let start = calendar.date(from: components) else { continue }
            buckets[start, default: []].append(item)
        }

        return buckets
            .map { start, bucketItems in
                TimelineSection(
                    id: "\(grouping.rawValue)-\(start.timeIntervalSince1970)",
                    start: start,
                    title: title(for: start, grouping: grouping, calendar: calendar, now: now),
                    // Newest first inside a section too, so the first picture under "Today" is the
                    // most recent one rather than whatever order the server answered in.
                    items: bucketItems.sorted { $0.timelineDate > $1.timelineDate }
                )
            }
            .sorted { $0.start > $1.start }
    }

    // MARK: - Titles

    static func title(for start: Date,
                      grouping: TimelineGrouping,
                      calendar: Calendar = .current,
                      now: Date = Date()) -> String {
        switch grouping {
        case .day:
            // Compared against `now` rather than through `isDateInToday`, which reads the system
            // clock in the *device's* zone: with a calendar pinned to another zone — a test, or a
            // library being browsed in a zone the user has left — that labels the wrong day.
            if calendar.isDate(start, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(start, inSameDayAs: yesterday) {
                return "Yesterday"
            }
            // The year is dropped for the current year — every heading carrying "2026" in 2026 is
            // noise, and the sections are in order anyway.
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            let formatter = sameYear ? dayThisYearFormatter : dayFormatter
            return formatter.string(from: start, in: calendar)
        case .month:
            return monthFormatter.string(from: start, in: calendar)
        case .year:
            return yearFormatter.string(from: start, in: calendar)
        }
    }

    // MARK: - Formatters

    /// Built from a template rather than a literal pattern so the order of day and month follows
    /// the reader's locale — "12 August" here, "August 12" there.
    private static let dayFormatter = TemplateFormatter("dMMMMyyyy")
    private static let dayThisYearFormatter = TemplateFormatter("dMMMM")
    private static let monthFormatter = TemplateFormatter("MMMMyyyy")
    private static let yearFormatter = TemplateFormatter("yyyy")
}

// MARK: - TemplateFormatter

/// A locale-aware date formatter that takes its time zone from the calendar it is asked to format
/// with, so a test can pin the zone without reaching into a shared formatter's state.
private struct TemplateFormatter {

    private let template: String

    init(_ template: String) {
        self.template = template
    }

    func string(from date: Date, in calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
