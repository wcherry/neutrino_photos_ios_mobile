import Foundation

// MARK: - MultipartFormBody

/// Builds the `multipart/form-data` payloads Drive's upload endpoint expects.
///
/// Drive's actix-multipart handler rejects a raw `application/octet-stream` body even where the
/// content is a single opaque blob, so an encrypted photograph has to be framed as a `file` part.
struct MultipartFormBody {

    // MARK: - Properties

    let boundary: String

    private var body = Data()

    /// The value for the request's `Content-Type` header.
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    // MARK: - Init

    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }

    // MARK: - Building

    /// Appends a scalar text field. A nil `value` is a no-op, so optional fields can be passed
    /// straight through without the caller branching.
    mutating func appendField(name: String, value: String?) {
        guard let value else { return }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n")
        append("\r\n")
        append(value)
        append("\r\n")
    }

    /// Appends a file part. `data` is written verbatim — it is ciphertext, never text.
    mutating func appendFile(name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n")
        append("\r\n")
        body.append(data)
        append("\r\n")
    }

    /// Closes the body with the terminating boundary and returns it.
    func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    // MARK: - Streaming

    /// Writes the finished body to `destination`, copying `fileURL` into the file part a block at a
    /// time rather than reading it into memory.
    ///
    /// The whole point of the large-file path. Everything else in a multipart body — the boundary,
    /// the field values, the part headers — is a few hundred bytes; the file is the file. Copying it
    /// through a fixed buffer means a ten-gigabyte upload costs one buffer, and `URLSession` then
    /// streams the result off disk rather than being handed it as `Data`.
    ///
    /// - Parameter fileURL: the bytes for the part. Ciphertext, in every caller here.
    func write(to destination: URL, filePart: FilePart, fileURL: URL) throws {
        var header = body
        header.append(Data("--\(boundary)\r\n".utf8))
        header.append(Data(
            "Content-Disposition: form-data; name=\"\(filePart.name)\"; filename=\"\(filePart.fileName)\"\r\n".utf8))
        header.append(Data("Content-Type: \(filePart.mimeType)\r\n\r\n".utf8))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw MultipartError.cannotWrite
        }
        defer { try? output.close() }
        try output.write(contentsOf: header)

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let block = try input.read(upToCount: Self.copyBufferSize), !block.isEmpty {
            try output.write(contentsOf: block)
        }

        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// The parts of a file part that are not the file.
    struct FilePart {
        let name: String
        let fileName: String
        let mimeType: String
    }

    enum MultipartError: LocalizedError {
        case cannotWrite

        var errorDescription: String? {
            switch self {
            case .cannotWrite: return "Could not stage the upload on this device."
            }
        }
    }

    /// 1 MiB, matching ``MediaCrypto/defaultChunkSize`` — the two copies run back to back on an
    /// upload and there is nothing to gain from them disagreeing.
    private static let copyBufferSize = 1 << 20

    // MARK: - Private

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
