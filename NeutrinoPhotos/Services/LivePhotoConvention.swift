import AVFoundation
import Foundation

// The platform's one convention for Live Photos — `neutrino/agent_docs/live-photos.md`:
//
// 1. The still carries `motionPhoto` and `device.liveVideoFileID`, the clip's Drive file.
// 2. The clip is registered as a photo too, with its own `motionPhoto`.
// 3. A clip some still claims is never shown on its own.
// 4. Metadata is merged into the record (`PATCH`), never written whole, so nobody erases a key
//    another client wrote.
//
// This file holds the pieces of that which are pure enough to test without a server or PhotoKit.

// MARK: - Pairing

enum LivePhotoPairing {

    /// The photo ids of the videos in `items` that some still claims as its Live Photo motion.
    ///
    /// Claimed, in order: a still's ``MediaDeviceFacts/liveVideoFileID`` names the video's file;
    /// or the two carry the same ``MotionPhotoFacts/contentIdentifier``. The web also falls back to
    /// matching filename stems, for libraries it imported before the link existed — not done here:
    /// this app has never stored a clip under its still's name, and the web writes the link for
    /// every pair it makes that way, so it arrives here as a `liveVideoFileID`.
    static func claimedClipIDs(in items: [MediaItem]) -> Set<String> {
        var linkedFiles = Set<String>()
        var contentIdentifiers = Set<String>()
        for item in items where item.kind == .photo {
            if let file = item.liveVideoFileID { linkedFiles.insert(file) }
            if let identifier = item.motionContentIdentifier { contentIdentifiers.insert(identifier) }
        }
        guard !linkedFiles.isEmpty || !contentIdentifiers.isEmpty else { return [] }

        var claimed = Set<String>()
        for item in items where item.kind == .video {
            if linkedFiles.contains(item.fileID) {
                claimed.insert(item.id)
            } else if let identifier = item.motionContentIdentifier,
                      contentIdentifiers.contains(identifier) {
                claimed.insert(item.id)
            }
        }
        return claimed
    }
}

// MARK: - Merge patches

/// Any JSON value — the body of a JSON Merge Patch, which needs an explicit `null` (remove the
/// key) that a synthesized `Encodable` never writes.
enum JSONValue: Encodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers as integers, so a width reads back as `4032`, not `4032.0`.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The JSON shape of any `Encodable`, as this app's API client would send it.
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = JSONValue(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(foundation value: Any) {
        switch value {
        case let number as NSNumber:
            // `JSONSerialization` hands booleans back as NSNumber too; tell them apart by type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(foundation:)))
        default: self = .null
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
}

extension MediaMetadata {

    /// This record as a merge patch: every key it holds, plus a `null` for each of `removing` —
    /// dotted paths such as `exif.gpsLatitude` — so the server drops what this write means to take
    /// away, and keeps every key this app has never heard of.
    func mergePatch(removing paths: [String] = []) throws -> JSONValue {
        var patch = try JSONValue(encoding: self)
        for path in paths {
            patch = patch.settingNull(at: path.split(separator: ".").map(String.init))
        }
        return patch
    }

    /// The paths that hold where a photograph was taken — nulled when location is not published,
    /// so a record that once carried coordinates stops carrying them, as a whole-document write did.
    static let locationPaths = ["exif.gpsLatitude", "exif.gpsLongitude"]
}

private extension JSONValue {
    func settingNull(at path: [String]) -> JSONValue {
        guard let key = path.first else { return .null }
        var object: [String: JSONValue]
        if case .object(let existing) = self { object = existing } else { object = [:] }
        object[key] = path.count == 1 ? .null : (object[key] ?? .object([:])).settingNull(at: Array(path.dropFirst()))
        return .object(object)
    }
}

// MARK: - Reading a clip

enum LivePhotoClipReader {

    /// What a Live Photo's clip says about itself: Apple's content identifier, and where in the
    /// clip the still was taken. Either is nil when the file doesn't carry it; never throws — a
    /// clip that can't be read is still a clip, and classified by PhotoKit regardless.
    static func motionPhoto(ofClipAt url: URL) async -> MotionPhotoFacts {
        let asset = AVURLAsset(url: url)
        return .livePhoto(contentIdentifier: await contentIdentifier(of: asset),
                          stillImageTime: await stillImageTime(of: asset))
    }

    static func contentIdentifier(of asset: AVURLAsset) async -> String? {
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items where item.identifier == .quickTimeMetadataContentIdentifier
            || (item.key as? String) == "com.apple.quicktime.content.identifier" {
            if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }

    /// The start of the timed-metadata sample holding `com.apple.quicktime.still-image-time`.
    static func stillImageTime(of asset: AVURLAsset) async -> Double? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata) else { return nil }
        for track in tracks {
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            defer { reader.cancelReading() }
            while let group = adaptor.nextTimedMetadataGroup() {
                let marks = group.items.contains {
                    $0.identifier?.rawValue.hasSuffix("com.apple.quicktime.still-image-time") == true
                        || ($0.key as? String) == "com.apple.quicktime.still-image-time"
                }
                if marks {
                    let seconds = group.timeRange.start.seconds
                    return seconds.isFinite ? seconds : nil
                }
            }
        }
        return nil
    }
}
