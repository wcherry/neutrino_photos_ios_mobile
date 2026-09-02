import XCTest
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoPhotos

// MARK: - DeviceSessionServiceTests

/// Listing the account's devices and revoking one.
@MainActor
final class DeviceSessionServiceTests: XCTestCase {

    private var sut: DeviceSessionService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        sut = DeviceSessionService(api: APIClient(session: MockURLProtocol.makeSession()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        DeviceIdentity.setDeviceName(nil)
        sut = nil
        super.tearDown()
    }

    // MARK: - Listing

    func testLoadsSessionsFromTheAuthEndpoint() async {
        MockURLProtocol.respond(json: Self.listingJSON)

        await sut.load()

        XCTAssertEqual(sut.sessions.count, 2)
        XCTAssertEqual(MockURLProtocol.request { _ in true }?.url?.path, "/api/v1/auth/sessions")
    }

    func testTimestampsAreParsedFromTheZonelessShapeTheEndpointEmits() async throws {
        MockURLProtocol.respond(json: Self.listingJSON)

        await sut.load()

        // `SessionResponse` serializes `NaiveDateTime` — no zone — which is exactly the shape
        // `ISO8601DateFormatter` refuses and `DriveDate` exists to read.
        let session = try XCTUnwrap(sut.sessions.first { $0.id == "session-a" })
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 12
        components.hour = 9; components.minute = 30; components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        XCTAssertEqual(session.createdAt, Calendar(identifier: .gregorian).date(from: components))
    }

    func testTheMostRecentlyUsedDeviceIsFirst() async {
        MockURLProtocol.respond(json: Self.listingJSON)

        await sut.load()

        // The device in the user's hand should not be buried under ones they last used in March.
        XCTAssertEqual(sut.sessions.first?.id, "session-b")
    }

    func testANeverUsedSessionFallsBackToWhenItWasCreated() async throws {
        MockURLProtocol.respond(json: """
        {"sessions":[
          {"id":"never","deviceName":"Spare iPad","userAgent":null,"ipAddress":null,
           "createdAt":"2026-08-18T12:00:00","lastUsedAt":null}
        ]}
        """)

        await sut.load()

        // Sorting on `lastUsedAt` alone would drop it to the bottom regardless of how new it is.
        XCTAssertEqual(sut.sessions.first?.id, "never")
        XCTAssertNil(sut.sessions.first?.lastUsedAt)
    }

    func testAnUnnamedDeviceStillHasSomethingToShow() async {
        MockURLProtocol.respond(json: """
        {"sessions":[
          {"id":"x","deviceName":null,"userAgent":null,"ipAddress":null,
           "createdAt":"2026-08-18T12:00:00","lastUsedAt":null}
        ]}
        """)

        await sut.load()

        XCTAssertEqual(sut.sessions.first?.displayName, "Unnamed device")
    }

    func testAFailedLoadIsReportedRatherThanShownAsAnEmptyAccount() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        await sut.load()

        XCTAssertNotNil(sut.error)
        XCTAssertTrue(sut.sessions.isEmpty)
    }

    // MARK: - This device

    func testThisDeviceIsIdentifiedByTheNameItRegisteredUnder() async {
        // There is no marker on the wire for "this is you" and the token carries no session id, so
        // the name sent in `X-Device-Name` at login is the only thing the two ends share.
        DeviceIdentity.setDeviceName("Test Phone")
        MockURLProtocol.respond(json: """
        {"sessions":[
          {"id":"mine","deviceName":"Test Phone","userAgent":null,"ipAddress":null,
           "createdAt":"2026-08-18T12:00:00","lastUsedAt":null},
          {"id":"theirs","deviceName":"Someone Else's iPad","userAgent":null,"ipAddress":null,
           "createdAt":"2026-08-18T12:00:00","lastUsedAt":null}
        ]}
        """)

        await sut.load()

        XCTAssertTrue(sut.sessions.contains { sut.isCurrentDevice($0) && $0.id == "mine" })
        XCTAssertFalse(sut.sessions.contains { sut.isCurrentDevice($0) && $0.id == "theirs" })
    }

    // MARK: - Revoking

    func testRevokingDeletesTheSessionAndDropsItFromTheList() async {
        MockURLProtocol.respond(json: Self.listingJSON)
        await sut.load()
        MockURLProtocol.respond(json: "", statusCode: 204)

        await sut.revoke(id: "session-a")

        XCTAssertFalse(sut.sessions.contains { $0.id == "session-a" })
        let request = MockURLProtocol.request { $0.httpMethod == "DELETE" }
        XCTAssertEqual(request?.url?.path, "/api/v1/auth/sessions/session-a")
    }

    func testAFailedRevokeLeavesTheDeviceListed() async {
        MockURLProtocol.respond(json: Self.listingJSON)
        await sut.load()
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        await sut.revoke(id: "session-a")

        // Removing it locally on a failure would tell the user a device was signed out when it
        // was not — the one outcome worse than the error.
        XCTAssertTrue(sut.sessions.contains { $0.id == "session-a" })
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Fixtures

    private static let listingJSON = """
    {"sessions":[
      {"id":"session-a","deviceName":"Old iPhone — Neutrino Photos","userAgent":"NeutrinoPhotos/1.0",
       "ipAddress":"203.0.113.0","createdAt":"2026-08-12T09:30:00","lastUsedAt":"2026-08-13T09:30:00"},
      {"id":"session-b","deviceName":"iPad — Neutrino Photos","userAgent":null,
       "ipAddress":null,"createdAt":"2026-08-01T09:30:00","lastUsedAt":"2026-08-18T08:00:00"}
    ]}
    """
}
