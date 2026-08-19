import Foundation
import Sodium

// MARK: - MediaCrypto

/// The primitives every encrypted photograph goes through, with no networking and no actor
/// attached, so they can be called from a background task and asserted directly in tests.
///
/// ## The wire format
///
/// ```
/// [24-byte secretstream header][chunk 0][chunk 1]…[chunk n, tagged FINAL]
/// ```
///
/// Each chunk is a `crypto_secretstream_xchacha20poly1305` push of exactly `chunkSize` plaintext
/// bytes — the last one being whatever is left — and costs 17 bytes of tag and MAC. A file small
/// enough to fit in one chunk therefore comes out **byte-for-byte identical** to the single-push
/// format the web client writes in `e2e-crypto/src/crypto.ts`, which is what makes a photograph
/// uploaded here openable there.
///
/// ## Why the chunk size has to travel with the file
///
/// It cannot be inferred. A reader handed `[header][A][B]` has no way to tell it apart from a single
/// push of `A‖B`'s length, and guessing wrong fails authentication rather than reading short — so
/// the framing is written into the file's *encrypted metadata* as `chunkSize`, and a file without
/// that field is one push. The web client's `decryptMetadata` returns an open record and its callers
/// read only `name` and `mimeType`, so the extra field passes through their code untouched. That
/// also means: **a multi-chunk file is not readable by today's web client.** Anything that has to
/// open on the web goes up one-shot; ``encryptStream(from:to:dek:chunkSize:)`` is for the originals
/// too large to hold in memory, which are Epic 8's videos rather than Epic 3's photographs.
///
/// ## What is never held whole
///
/// The streaming pair reads and writes through file handles, so peak memory is one chunk of
/// plaintext plus one of ciphertext regardless of how large the file is. The one-shot pair is the
/// opposite by construction and is for metadata, thumbnails, and originals of a few megabytes.
enum MediaCrypto {

    // MARK: - Constants

    private static let sodium = Sodium()

    /// The secretstream header, which prefixes every ciphertext Neutrino writes.
    static let headerBytes = SecretStream.XChaCha20Poly1305.HeaderBytes

    /// The per-chunk overhead: a tag byte plus a 16-byte Poly1305 MAC.
    static let chunkOverheadBytes = SecretStream.XChaCha20Poly1305.ABytes

    /// 1 MiB of plaintext per chunk — about 2 MiB of peak memory for the pair of buffers, and only
    /// ten thousand chunks for a 10 GB video, so neither the memory nor the per-chunk overhead
    /// (0.0016% at this size) is the thing that hurts.
    static let defaultChunkSize = 1 << 20

    // MARK: - Keys

    /// A fresh 32-byte data encryption key.
    ///
    /// Generated per file rather than derived from anything: that is what the web client does, and
    /// the two have to agree. It is sealed to the account's identity key and stored beside the file;
    /// the account key is what makes it recoverable, not a derivation path.
    static func newDEK() -> Bytes {
        sodium.secretStream.xchacha20poly1305.key()
    }

    /// Seals `dek` to a Curve25519 public key with `crypto_box_seal`, returning base64url.
    static func seal(dek: Bytes, toPublicKey publicKey: Bytes) throws -> String {
        guard let sealed = sodium.box.seal(message: dek, recipientPublicKey: publicKey),
              let encoded = sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw MediaContentError.encryptionFailed
        }
        return encoded
    }

    /// Reverses ``seal(dek:toPublicKey:)`` with `crypto_box_seal_open`.
    static func openDEK(_ sealedBase64: String, publicKey: Bytes, secretKey: Bytes) throws -> Bytes {
        guard let sealed = sodium.utils.base642bin(sealedBase64, variant: .URLSAFE_NO_PADDING) else {
            throw MediaContentError.decryptionFailed
        }
        guard let dek: Bytes = sodium.box.open(anonymousCipherText: sealed,
                                               recipientPublicKey: publicKey,
                                               recipientSecretKey: secretKey) else {
            throw MediaContentError.decryptionFailed
        }
        return dek
    }

    // MARK: - One-shot

    /// Encrypts `plaintext` as a single push — the format the web client reads.
    ///
    /// For metadata, thumbnails, and originals small enough to hold twice over. Anything large
    /// enough that the answer is "it depends how much RAM the phone has" belongs in
    /// ``encryptStream(from:to:dek:chunkSize:)``.
    static func encrypt(_ plaintext: Bytes, dek: Bytes) throws -> Data {
        guard let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: dek) else {
            throw MediaContentError.encryptionFailed
        }
        guard let ciphertext = stream.push(message: plaintext, tag: .FINAL) else {
            throw MediaContentError.encryptionFailed
        }
        return Data(stream.header() + ciphertext)
    }

    /// Decrypts bytes produced by ``encrypt(_:dek:)`` or by the web client.
    ///
    /// - Parameter chunkSize: the framing the file was written with, from its encrypted metadata.
    ///   Nil — the common case — means one push covering the whole file.
    static func decrypt(_ data: Data, dek: Bytes, chunkSize: Int? = nil) throws -> Bytes {
        guard data.count > headerBytes else {
            throw MediaContentError.decryptionFailed
        }
        let header = Bytes(data.prefix(headerBytes))
        let body = data.dropFirst(headerBytes)
        guard let pull = sodium.secretStream.xchacha20poly1305.initPull(secretKey: dek,
                                                                       header: header) else {
            throw MediaContentError.decryptionFailed
        }

        guard let chunkSize else {
            guard let (plaintext, tag) = pull.pull(cipherText: Bytes(body)), tag == .FINAL else {
                throw MediaContentError.decryptionFailed
            }
            return plaintext
        }

        var plaintext = Bytes()
        plaintext.reserveCapacity(body.count)
        var offset = body.startIndex
        var sawFinal = false
        while offset < body.endIndex {
            let end = body.index(offset, offsetBy: chunkSize + chunkOverheadBytes,
                                 limitedBy: body.endIndex) ?? body.endIndex
            guard let (chunk, tag) = pull.pull(cipherText: Bytes(body[offset..<end])) else {
                throw MediaContentError.decryptionFailed
            }
            plaintext.append(contentsOf: chunk)
            offset = end
            if tag == .FINAL { sawFinal = true; break }
        }
        // A stream that ran out of bytes without a FINAL tag was truncated. Each chunk
        // authenticates itself, so nothing else would have complained.
        guard sawFinal, offset == body.endIndex else {
            throw MediaContentError.decryptionFailed
        }
        return plaintext
    }

    // MARK: - Streaming

    /// Encrypts a file into another file, holding one chunk at a time.
    ///
    /// - Returns: the chunk size the file was written with, to be recorded in its encrypted metadata
    ///   — a caller that drops it has written a file nothing can read back.
    @discardableResult
    static func encryptStream(from source: URL, to destination: URL, dek: Bytes,
                              chunkSize: Int = defaultChunkSize) throws -> Int {
        precondition(chunkSize > 0, "chunk size must be positive")

        guard let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: dek) else {
            throw MediaContentError.encryptionFailed
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw MediaContentError.encryptionFailed
        }
        defer { try? output.close() }

        try write(stream.header(), to: output)

        // One chunk is read *ahead* of the one being written, because the FINAL tag has to go on the
        // last chunk and "last" is only known once the read after it comes back empty. Without the
        // lookahead an empty final read would produce a stream with no FINAL tag at all, which the
        // reader is right to reject as truncated.
        var pending = try read(chunkSize, from: input)
        repeat {
            let next = try read(chunkSize, from: input)
            let tag: SecretStream.XChaCha20Poly1305.Tag = next.isEmpty ? .FINAL : .MESSAGE
            guard let ciphertext = stream.push(message: pending, tag: tag) else {
                throw MediaContentError.encryptionFailed
            }
            try write(ciphertext, to: output)
            pending = next
        } while !pending.isEmpty

        return chunkSize
    }

    /// Decrypts a file written by ``encryptStream(from:to:dek:chunkSize:)``, holding one chunk at a
    /// time. `chunkSize` must be the value that encryption returned.
    static func decryptStream(from source: URL, to destination: URL, dek: Bytes,
                              chunkSize: Int = defaultChunkSize) throws {
        precondition(chunkSize > 0, "chunk size must be positive")

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        let header = try read(headerBytes, from: input)
        guard header.count == headerBytes,
              let pull = sodium.secretStream.xchacha20poly1305.initPull(secretKey: dek,
                                                                       header: header) else {
            throw MediaContentError.decryptionFailed
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw MediaContentError.decryptionFailed
        }
        defer { try? output.close() }

        var sawFinal = false
        while true {
            let ciphertext = try read(chunkSize + chunkOverheadBytes, from: input)
            if ciphertext.isEmpty { break }
            guard let (plaintext, tag) = pull.pull(cipherText: ciphertext) else {
                throw MediaContentError.decryptionFailed
            }
            try write(plaintext, to: output)
            if tag == .FINAL { sawFinal = true; break }
        }
        guard sawFinal else {
            // The file ended before the stream did. Every chunk authenticated, so this is the only
            // check that catches a download cut short.
            throw MediaContentError.decryptionFailed
        }
    }

    // MARK: - Metadata

    /// The plaintext of a file's `encrypted_metadata` blob.
    struct Metadata: Equatable {
        let name: String
        let mimeType: String
        /// The framing the content was written with; nil for a single push.
        let chunkSize: Int?
    }

    /// Encrypts `{ name, mimeType }` with the DEK, matching the web client's `encryptMetadata()`.
    ///
    /// `chunkSize` is added only when the content was actually chunked, so an ordinary photograph's
    /// metadata blob stays exactly the shape the web client writes.
    static func encryptMetadata(name: String, mimeType: String, chunkSize: Int? = nil,
                                dek: Bytes) throws -> String {
        var fields: [String: Any] = ["name": name, "mimeType": mimeType]
        if let chunkSize { fields["chunkSize"] = chunkSize }
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let encoded = sodium.utils.bin2base64(Bytes(try encrypt(Bytes(json), dek: dek)),
                                                    variant: .URLSAFE_NO_PADDING) else {
            throw MediaContentError.encryptionFailed
        }
        return encoded
    }

    /// Reverses ``encryptMetadata(name:mimeType:chunkSize:dek:)``.
    static func decryptMetadata(_ encoded: String, dek: Bytes) throws -> Metadata {
        guard let raw = sodium.utils.base642bin(encoded, variant: .URLSAFE_NO_PADDING) else {
            throw MediaContentError.decryptionFailed
        }
        let json = try decrypt(Data(raw), dek: dek)
        guard let fields = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any] else {
            throw MediaContentError.decryptionFailed
        }
        return Metadata(name: fields["name"] as? String ?? "",
                        mimeType: fields["mimeType"] as? String ?? "application/octet-stream",
                        chunkSize: fields["chunkSize"] as? Int)
    }

    // MARK: - File handles

    /// Reads exactly `count` bytes, or fewer only at end of file.
    ///
    /// `read(upToCount:)` is allowed to return a short read before the end, and a short read here
    /// would split a chunk across two `pull` calls — each of which would then fail authentication.
    /// So it is called until the buffer is full or the file is exhausted.
    private static func read(_ count: Int, from handle: FileHandle) throws -> Bytes {
        var buffer = Bytes()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            guard let data = try handle.read(upToCount: count - buffer.count), !data.isEmpty else {
                break
            }
            buffer.append(contentsOf: data)
        }
        return buffer
    }

    private static func write(_ bytes: Bytes, to handle: FileHandle) throws {
        guard !bytes.isEmpty else { return }
        try handle.write(contentsOf: Data(bytes))
    }
}
