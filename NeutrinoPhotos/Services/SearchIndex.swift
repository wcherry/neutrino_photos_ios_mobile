import Foundation

// MARK: - SearchIndex

/// The library, prepared for searching on this device.
///
/// Built from ``PhotoLibraryService/allItems`` — which the local database hydrates before the
/// network answers — so search works on a plane exactly as it does at home. Nothing is sent
/// anywhere: the server could not search most of this anyway, since the title and caption a person
/// writes are the only text about a photograph it has never seen.
///
/// ## Why an array scan
///
/// Every field a search can match is lowercased once, here, when the library changes, and a query
/// is then a pass over plain strings. On a 50,000-photo library that is tens of milliseconds — well
/// inside Epic 11's 500 ms budget, and `SearchIndexTests` holds it there. A full-text engine would
/// buy ranking subtleties this screen does not need at the price of a second copy of the library
/// to keep in step with the first.
///
/// ## Ranking
///
/// 1. The file name, exactly — somebody who types `IMG_4021.HEIC` wants that photograph, first.
/// 2. A file name that starts with the text.
/// 3. The whole text inside one field — "iPhone 15 Pro" in the camera, not "iPhone" in one place
///    and "15" in a file name.
/// 4. Every word somewhere — only when nothing matched better, so a precise query is not diluted
///    by loose matches.
///
/// Newest first within each.
struct SearchIndex {

    // MARK: - Entry

    struct Entry {
        let item: MediaItem
        let fileName: String
        let displayName: String
        /// Each searchable field on its own, lowercased: name, title, caption, camera, lens, type.
        let fields: [String]
        /// Every field joined, for the word-by-word fallback.
        let haystack: String
        /// "Apple iPhone 15 Pro", as the user would want it suggested back to them.
        let camera: String?
        let lens: String?
    }

    let entries: [Entry]

    // MARK: - Building

    init(items: [MediaItem]) {
        entries = items.map(Self.entry(for:))
    }

    private static func entry(for item: MediaItem) -> Entry {
        let exif = item.metadata?.exif
        let camera = Self.cameraName(make: exif?.make, model: exif?.model)
        var fields: [String] = [item.fileName, item.displayName]
        if let title = item.metadata?.title { fields.append(title) }
        if let caption = item.metadata?.caption { fields.append(caption) }
        if let camera { fields.append(camera) }
        if let model = exif?.model { fields.append(model) }
        if let lens = exif?.lensModel { fields.append(lens) }
        fields.append(item.mimeType)
        if let format = item.metadata?.format { fields.append(format) }
        fields.append(contentsOf: Self.kindWords(for: item))

        let lowered = fields.map { $0.lowercased() }
        return Entry(item: item,
                     fileName: item.fileName.lowercased(),
                     displayName: item.displayName.lowercased(),
                     fields: lowered,
                     haystack: lowered.joined(separator: " "),
                     camera: camera,
                     lens: exif?.lensModel)
    }

    /// "Apple iPhone 15 Pro" — or just the model where it already names its maker, as "Canon EOS
    /// R5" does, so the make is not said twice.
    static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces)
        let model = model?.trimmingCharacters(in: .whitespaces)
        switch (make, model) {
        case let (make?, model?) where !make.isEmpty && !model.isEmpty:
            return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (_, model?) where !model.isEmpty:
            return model
        case let (make?, _) where !make.isEmpty:
            return make
        default:
            return nil
        }
    }

    /// The words a person might use for what an item *is*, beyond its MIME type.
    private static func kindWords(for item: MediaItem) -> [String] {
        var words: [String] = []
        if item.isLivePhoto { words.append("live photo") }
        if item.isRAW { words.append("raw") }
        for subtype in item.metadata?.device?.subtypes ?? [] {
            switch subtype {
            case "screenshot": words.append("screenshot")
            case "panorama":   words.append("panorama")
            case "portrait":   words.append("portrait")
            case "hdr":        words.append("hdr")
            case "slowMotion": words.append("slow motion slo-mo")
            case "timelapse":  words.append("time-lapse timelapse")
            default:           words.append(subtype)
            }
        }
        return words
    }

    // MARK: - Searching

    /// The items matching `query`, best first.
    func search(_ query: SearchQuery, calendar: Calendar = .current) -> [MediaItem] {
        guard !query.isEmpty else { return [] }
        let text = query.text
        let words = query.words

        var ranked: [(rank: Int, item: MediaItem)] = []
        var bestRank = Int.max

        for entry in entries where passesFilters(entry.item, query, calendar: calendar) {
            let rank: Int
            if text.isEmpty {
                rank = 0
            } else if entry.fileName == text || entry.displayName == text {
                rank = 0
            } else if entry.fileName.hasPrefix(text) {
                rank = 1
            } else if entry.fields.contains(where: { $0.contains(text) }) {
                rank = 2
            } else if words.count > 1, words.allSatisfy({ entry.haystack.contains($0) }) {
                rank = 3
            } else {
                continue
            }
            bestRank = min(bestRank, rank)
            ranked.append((rank, entry.item))
        }

        // The loose word-by-word matches only count when nothing matched properly.
        if bestRank < 3 { ranked.removeAll { $0.rank == 3 } }

        return ranked.sorted(by: Self.isRankedBefore).map(\.item)
    }

    private static func isRankedBefore(_ lhs: (rank: Int, item: MediaItem),
                                       _ rhs: (rank: Int, item: MediaItem)) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.item.timelineDate > rhs.item.timelineDate
    }

    private func passesFilters(_ item: MediaItem, _ query: SearchQuery,
                               calendar: Calendar) -> Bool {
        if let kind = query.kind, item.kind != kind { return false }
        if query.favoritesOnly, !item.isStarred { return false }
        if let range = query.dateRange {
            // Half-open, so a photograph taken at midnight on 1 July is July's and not June's too.
            let date = item.timelineDate
            guard date >= range.start, date < range.end else { return false }
        }
        if let month = query.monthOfAnyYear,
           calendar.component(.month, from: item.timelineDate) != month {
            return false
        }
        return true
    }

    // MARK: - Suggestions

    /// Cameras in the library, most-used first — offered as one-tap searches.
    func cameras(limit: Int = 6) -> [String] {
        mostCommon(entries.compactMap(\.camera), limit: limit)
    }

    /// Years the library has photographs from, newest first.
    func years(calendar: Calendar = .current) -> [Int] {
        Set(entries.map { calendar.component(.year, from: $0.item.timelineDate) })
            .sorted(by: >)
    }

    /// Completions for what has been typed so far: cameras, lenses and years that contain it.
    func completions(for text: String, limit: Int = 8, calendar: Calendar = .current) -> [String] {
        let needle = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let candidates = mostCommon(entries.compactMap(\.camera), limit: 50)
            + mostCommon(entries.compactMap(\.lens), limit: 50)
            + years(calendar: calendar).map(String.init)
        var seen = Set<String>()
        return candidates
            .filter { $0.lowercased().contains(needle) && $0.lowercased() != needle }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }

    private func mostCommon(_ values: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }
}
