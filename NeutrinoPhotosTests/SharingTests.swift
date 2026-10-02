import XCTest
@testable import NeutrinoPhotos

// MARK: - PhotoExporterTests

@MainActor
final class PhotoExporterTests: XCTestCase {

    private struct NoKey: LocalizedError {
        var errorDescription: String? { "No encryption key found." }
    }

    private var exporters: [PhotoExporter] = []

    override func tearDown() async throws {
        exporters.forEach { $0.cleanUp() }
        exporters = []
    }

    private func makeExporter(_ fetch: @escaping PhotoExporter.Fetch) -> PhotoExporter {
        let exporter = PhotoExporter(fetch: fetch)
        exporters.append(exporter)
        return exporter
    }

    func testEachItemBecomesAFileNamedAsTheUserNamedIt() async throws {
        let exporter = makeExporter { item in .data(Data(item.id.utf8)) }

        let result = await exporter.export([
            Fixture.item(id: "a", fileName: "Beach.jpg"),
            Fixture.item(id: "b", fileName: "Dinner.jpg"),
        ])

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["Beach.jpg", "Dinner.jpg"])
        XCTAssertEqual(try Data(contentsOf: result.urls[0]), Data("a".utf8),
                       "the decrypted bytes, exactly")
        XCTAssertEqual(result.failedCount, 0)
    }

    func testTwoFilesWithTheSameNameDoNotOverwriteEachOther() async {
        let exporter = makeExporter { item in .data(Data(item.id.utf8)) }

        let result = await exporter.export([
            Fixture.item(id: "a", fileName: "IMG_0001.JPG"),
            Fixture.item(id: "b", fileName: "img_0001.jpg"),
            Fixture.item(id: "c", fileName: "IMG_0001.JPG"),
        ])

        XCTAssertEqual(result.urls.map(\.lastPathComponent),
                       ["IMG_0001.JPG", "img_0001 2.jpg", "IMG_0001 3.JPG"])
    }

    func testAVideoIsCopiedFromItsDecryptedFileNotRead() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-source-\(UUID().uuidString).mov")
        try Data(repeating: 7, count: 64).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let exporter = makeExporter { _ in .file(source) }

        let result = await exporter.export([Fixture.item(fileName: "Clip.mov", mimeType: "video/quicktime")])

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.urls.first)).count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the viewer's cached copy stays where it was")
    }

    func testOneFailureLeavesTheRestToShareAndSaysWhy() async {
        let exporter = makeExporter { item in
            if item.id == "locked" { throw NoKey() }
            return .data(Data())
        }

        let result = await exporter.export([
            Fixture.item(id: "a", fileName: "a.jpg"),
            Fixture.item(id: "locked", fileName: "b.jpg"),
            Fixture.item(id: "c", fileName: "c.jpg"),
        ])

        XCTAssertEqual(result.urls.count, 2)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.firstError, "No encryption key found.")
    }

    func testProgressCountsEveryItem() async {
        let exporter = makeExporter { _ in .data(Data()) }
        var reported: [Int] = []

        _ = await exporter.export((0..<3).map { Fixture.item(id: "p\($0)", fileName: "p\($0).jpg") }) {
            reported.append($0)
        }

        XCTAssertEqual(reported, [1, 2, 3])
    }

    func testCleaningUpRemovesEveryDecryptedFile() async {
        let exporter = makeExporter { _ in .data(Data(repeating: 1, count: 10)) }
        let result = await exporter.export([Fixture.item(fileName: "a.jpg")])

        exporter.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: exporter.directory.path),
                       "decrypted photos must not linger in tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.urls[0].path))
    }

    func testANameThatCouldEscapeTheDirectoryIsMadeSafe() {
        var taken = Set<String>()

        XCTAssertEqual(PhotoExporter.uniqueName(for: "../../evil.jpg", taken: &taken), "Photo.._.._evil.jpg")
        XCTAssertEqual(PhotoExporter.uniqueName(for: "", taken: &taken), "Photo")
    }
}

// MARK: - PhotoLinkRouterTests

@MainActor
final class PhotoLinkRouterTests: XCTestCase {

    func testAPhotoLinkIsAcceptedWithAndWithoutWww() {
        XCTAssertEqual(PhotoLinkRouter.fileID(from: URL(string: "https://www.getneutrino.app/open/photo/f-123")!),
                       "f-123")
        XCTAssertEqual(PhotoLinkRouter.fileID(from: URL(string: "https://getneutrino.app/open/photo/f-123")!),
                       "f-123")
    }

    func testOtherLinksAreNotOurs() {
        let others = [
            "https://www.getneutrino.app/open/slide/f-123",   // another app's kind
            "http://www.getneutrino.app/open/photo/f-123",    // not https
            "https://evil.example/open/photo/f-123",           // not a Neutrino host
            "https://www.getneutrino.app/open/photo/",         // no id
            "https://www.getneutrino.app/open/photo/a/b",      // too deep
            "file:///tmp/key.json",                            // a key file
        ]
        for link in others {
            XCTAssertNil(PhotoLinkRouter.fileID(from: URL(string: link)!), link)
        }
    }

    func testTheRouterHoldsALinkUntilItIsConsumed() {
        let sut = PhotoLinkRouter()

        XCTAssertTrue(sut.handle(URL(string: "https://www.getneutrino.app/open/photo/f-9")!))
        XCTAssertEqual(sut.pendingFileID, "f-9")
        XCTAssertEqual(sut.consume(), "f-9")
        XCTAssertNil(sut.pendingFileID, "a photo already opening is not opened twice")
    }

    func testAKeyFileIsLeftForTheKeyFileHandler() {
        let sut = PhotoLinkRouter()

        XCTAssertFalse(sut.handle(URL(fileURLWithPath: "/tmp/neutrino-key.json")))
        XCTAssertNil(sut.pendingFileID)
    }

    func testBuiltLinksParseBack() throws {
        let url = try XCTUnwrap(PhotoLinkRouter.url(forFileID: "f-42"))

        XCTAssertEqual(url.absoluteString, "https://www.getneutrino.app/open/photo/f-42")
        XCTAssertEqual(PhotoLinkRouter.fileID(from: url), "f-42")
        XCTAssertNil(PhotoLinkRouter.url(forFileID: "  "))
    }
}
