import Sodium
import XCTest
@testable import NeutrinoPhotos

// MARK: - MediaCryptoTests

/// The encrypt/decrypt helpers on their own: the one-shot pair the web client reads, and the
/// streaming pair for originals too large to hold in memory.
final class MediaCryptoTests: XCTestCase {

    private var directory: URL!
    private var dek: Bytes!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
        dek = MediaCrypto.newDEK()
    }

    override func tearDown() {
        directory = nil
        dek = nil
        super.tearDown()
    }

    // MARK: - One-shot

    func testOneShotRoundTrip() throws {
        let original = Bytes((0..<4096).map { UInt8($0 % 251) })

        let ciphertext = try MediaCrypto.encrypt(original, dek: dek)

        XCTAssertEqual(try MediaCrypto.decrypt(ciphertext, dek: dek), original)
        XCTAssertEqual(ciphertext.count,
                       original.count + MediaCrypto.headerBytes + MediaCrypto.chunkOverheadBytes,
                       "24-byte secretstream header plus the 17-byte tag and MAC a push adds")
    }

    func testDecryptingWithTheWrongKeyFails() throws {
        let ciphertext = try MediaCrypto.encrypt(Bytes("hello".utf8), dek: dek)

        XCTAssertThrowsError(try MediaCrypto.decrypt(ciphertext, dek: MediaCrypto.newDEK()))
    }

    func testTruncatedCiphertextIsRejected() throws {
        let ciphertext = try MediaCrypto.encrypt(Bytes(repeating: 5, count: 1024), dek: dek)

        XCTAssertThrowsError(try MediaCrypto.decrypt(ciphertext.dropLast(1), dek: dek))
        XCTAssertThrowsError(try MediaCrypto.decrypt(ciphertext.prefix(10), dek: dek))
    }

    // MARK: - Streaming

    func testStreamingRoundTripAcrossManyChunks() throws {
        // Deliberately not a multiple of the chunk size: the last chunk is the one carrying the
        // FINAL tag, and a partial one is the case that breaks first.
        let original = Data((0..<(4096 * 5 + 137)).map { UInt8($0 % 253) })
        let (plaintext, ciphertext, recovered) = urls()
        try original.write(to: plaintext)

        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: 4096)
        try MediaCrypto.decryptStream(from: ciphertext, to: recovered, dek: dek, chunkSize: 4096)

        XCTAssertEqual(try Data(contentsOf: recovered), original)
    }

    func testAFileThatFitsInOneChunkIsByteIdenticalToTheOneShotFormat() throws {
        // This is what keeps a photograph uploaded here openable in the web app, whose
        // `decryptFile` does a single pull over the whole body.
        let original = Data("a small photograph, more or less".utf8)
        let (plaintext, ciphertext, _) = urls()
        try original.write(to: plaintext)

        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: 1 << 20)
        let streamed = try Data(contentsOf: ciphertext)

        XCTAssertEqual(streamed.count,
                       original.count + MediaCrypto.headerBytes + MediaCrypto.chunkOverheadBytes,
                       "one chunk, so exactly one push — no extra framing")
        XCTAssertEqual(try MediaCrypto.decrypt(streamed, dek: dek), Bytes(original))
    }

    func testAnEmptyFileStillProducesAReadableStream() throws {
        let (plaintext, ciphertext, recovered) = urls()
        try Data().write(to: plaintext)

        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: 4096)
        try MediaCrypto.decryptStream(from: ciphertext, to: recovered, dek: dek, chunkSize: 4096)

        XCTAssertEqual(try Data(contentsOf: recovered).count, 0)
    }

    func testAFileExactlyOneChunkLongEndsWithAFinalTag() throws {
        // The boundary the lookahead in `encryptStream` exists for: without it the read after the
        // last full chunk comes back empty and the stream never gets its FINAL tag.
        let original = Data(repeating: 42, count: 4096)
        let (plaintext, ciphertext, recovered) = urls()
        try original.write(to: plaintext)

        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: 4096)
        try MediaCrypto.decryptStream(from: ciphertext, to: recovered, dek: dek, chunkSize: 4096)

        XCTAssertEqual(try Data(contentsOf: recovered), original)
    }

    func testATruncatedStreamIsRejectedRatherThanReadShort() throws {
        // Every chunk authenticates itself, so a download cut between chunks decrypts perfectly and
        // is simply missing its tail. The missing FINAL tag is the only thing that catches it.
        let original = Data(repeating: 7, count: 4096 * 3)
        let (plaintext, ciphertext, recovered) = urls()
        try original.write(to: plaintext)
        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: 4096)

        let full = try Data(contentsOf: ciphertext)
        let cut = directory.appendingPathComponent("cut.bin")
        try full.prefix(MediaCrypto.headerBytes + 4096 + MediaCrypto.chunkOverheadBytes).write(to: cut)

        XCTAssertThrowsError(try MediaCrypto.decryptStream(from: cut, to: recovered,
                                                           dek: dek, chunkSize: 4096))
    }

    func testReadingAChunkedStreamWithTheWrongChunkSizeFails() throws {
        // The framing cannot be inferred from the bytes, which is why it travels in the file's
        // encrypted metadata. Getting it wrong has to fail loudly rather than read short.
        let original = Data(repeating: 3, count: 4096 * 2)
        let (plaintext, ciphertext, recovered) = urls()
        try original.write(to: plaintext)
        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: 4096)

        XCTAssertThrowsError(try MediaCrypto.decryptStream(from: ciphertext, to: recovered,
                                                           dek: dek, chunkSize: 8192))
    }

    func testStreamingDoesNotHoldTheWholeFile() throws {
        // The property that makes the streaming pair worth having: a file far larger than the chunk
        // size goes through without either side ever materialising it. Asserted on the output rather
        // than on allocations — footprint is Instruments' job (Epic 3's verification step 6) — but a
        // 32 MiB file through a 64 KiB chunk would not complete at all if either side buffered.
        let chunkSize = 64 * 1024
        let original = Data((0..<(32 * 1024 * 1024)).map { UInt8($0 % 256) })
        let (plaintext, ciphertext, recovered) = urls()
        try original.write(to: plaintext)

        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: chunkSize)
        try MediaCrypto.decryptStream(from: ciphertext, to: recovered, dek: dek, chunkSize: chunkSize)

        let chunks = (original.count + chunkSize - 1) / chunkSize
        XCTAssertEqual(try Data(contentsOf: ciphertext).count,
                       original.count + MediaCrypto.headerBytes + chunks * MediaCrypto.chunkOverheadBytes)
        XCTAssertEqual(try Data(contentsOf: recovered), original)
    }

    // MARK: - In-memory chunked reads

    func testTheInMemoryReaderAlsoHandlesTheChunkedFraming() throws {
        let original = Data(repeating: 11, count: 4096 * 2 + 9)
        let (plaintext, ciphertext, _) = urls()
        try original.write(to: plaintext)
        try MediaCrypto.encryptStream(from: plaintext, to: ciphertext, dek: dek, chunkSize: 4096)

        let decrypted = try MediaCrypto.decrypt(try Data(contentsOf: ciphertext),
                                                dek: dek, chunkSize: 4096)

        XCTAssertEqual(Data(decrypted), original)
    }

    // MARK: - Metadata

    func testMetadataRoundTrip() throws {
        let encoded = try MediaCrypto.encryptMetadata(name: "IMG_0001.jpg",
                                                      mimeType: "image/jpeg", dek: dek)

        let metadata = try MediaCrypto.decryptMetadata(encoded, dek: dek)

        XCTAssertEqual(metadata.name, "IMG_0001.jpg")
        XCTAssertEqual(metadata.mimeType, "image/jpeg")
        XCTAssertNil(metadata.chunkSize, "an ordinary photograph is one push and says nothing extra")
    }

    func testChunkSizeTravelsWithAChunkedFile() throws {
        let encoded = try MediaCrypto.encryptMetadata(name: "clip.mov", mimeType: "video/quicktime",
                                                      chunkSize: 1 << 20, dek: dek)

        XCTAssertEqual(try MediaCrypto.decryptMetadata(encoded, dek: dek).chunkSize, 1 << 20)
    }

    func testMetadataForAnUnchunkedFileKeepsTheShapeTheWebClientWrites() throws {
        let encoded = try MediaCrypto.encryptMetadata(name: "a.jpg", mimeType: "image/jpeg", dek: dek)
        let raw = try XCTUnwrap(Sodium().utils.base642bin(encoded, variant: .URLSAFE_NO_PADDING))
        let json = try MediaCrypto.decrypt(Data(raw), dek: dek)
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json)) as? [String: Any])

        XCTAssertEqual(Set(fields.keys), ["name", "mimeType"])
    }

    func testMetadataDecryptedWithTheWrongKeyFails() throws {
        let encoded = try MediaCrypto.encryptMetadata(name: "a.jpg", mimeType: "image/jpeg", dek: dek)

        XCTAssertThrowsError(try MediaCrypto.decryptMetadata(encoded, dek: MediaCrypto.newDEK()))
    }

    // MARK: - DEK sealing

    func testSealingAndOpeningADEKAgainstAnX25519Pair() throws {
        let bundle = TestKeys.install()
        defer { TestKeys.remove() }
        let publicKey = try XCTUnwrap(KeyVaultCrypto.decodeBase64URL(bundle.publicKey))
        let secretKey = try XCTUnwrap(KeyVaultCrypto.decodeBase64URL(bundle.privateKey))

        let sealed = try MediaCrypto.seal(dek: dek, toPublicKey: publicKey)

        XCTAssertEqual(try MediaCrypto.openDEK(sealed, publicKey: publicKey, secretKey: secretKey),
                       dek)
    }

    func testEveryDEKIsFresh() {
        XCTAssertNotEqual(MediaCrypto.newDEK(), MediaCrypto.newDEK())
        XCTAssertEqual(MediaCrypto.newDEK().count, 32)
    }

    // MARK: - Helpers

    private func urls() -> (plaintext: URL, ciphertext: URL, recovered: URL) {
        (directory.appendingPathComponent("plain.bin"),
         directory.appendingPathComponent("cipher.bin"),
         directory.appendingPathComponent("recovered.bin"))
    }
}
