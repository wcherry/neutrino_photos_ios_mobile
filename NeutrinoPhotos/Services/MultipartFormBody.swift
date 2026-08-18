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

    // MARK: - Private

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
