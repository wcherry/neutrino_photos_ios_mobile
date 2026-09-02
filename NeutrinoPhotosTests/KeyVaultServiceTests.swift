import XCTest
import NeutrinoCrypto
@testable import NeutrinoPhotos

// MARK: - KeyVaultServiceTests

/// Fetching the vault, opening it, and what the app believes about this device afterwards.
///
/// Real HTTP against `MockURLProtocol` and real crypto against `WebVault` — an unlock that "works"
/// against a stubbed decryptor proves nothing about the one thing that has to hold, which is that
/// the password set on the web opens the key here.
@MainActor
final class KeyVaultServiceTests: XCTestCase {

    private var sut: KeyVaultService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.remove()
        sut = KeyVaultService(api: APIClient(session: MockURLProtocol.makeSession()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    // MARK: - Fetching

    func testFetchesTheVaultFromTheAuthEndpoint() async throws {
        MockURLProtocol.respond(data: WebVault.responseJSON())

        let vault = try await sut.fetchVault()

        XCTAssertEqual(vault?.publicKey, WebVault.publicKey)
        XCTAssertEqual(vault?.unlocks.count, 1)
        let request = MockURLProtocol.request { _ in true }
        XCTAssertEqual(request?.url?.path, "/api/v1/auth/keyvault")
    }

    func testTheParamsBlobSurvivesDecodingVerbatim() async throws {
        // `params` is a JSON *string* carrying `memoryKiB`. Decoded with a snake-case-converting
        // decoder it would come back mangled and the derivation would use the wrong memory cost —
        // the failure this asserts against is silent and only shows up as "wrong password".
        MockURLProtocol.respond(data: WebVault.responseJSON())

        let vault = try await sut.fetchVault()
        let params = try XCTUnwrap(vault?.unlocks.first?.params)
        let decoded = try JSONDecoder().decode(Argon2Params.self, from: Data(params.utf8))

        XCTAssertEqual(decoded.memoryKiB, 65536)
        XCTAssertEqual(decoded.iterations, 3)
    }

    func testAnAccountWithNoVaultAnswersNilRatherThanFailing() async throws {
        MockURLProtocol.respond(json: "{}", statusCode: 404)

        let vault = try await sut.fetchVault()

        XCTAssertNil(vault, "404 here is a fact about the account, not a failure")
    }

    // MARK: - Status

    func testAFreshDeviceWithAVaultIsLocked() async {
        MockURLProtocol.respond(data: WebVault.responseJSON())

        await sut.refresh()

        XCTAssertEqual(sut.status, .locked)
        XCTAssertFalse(sut.keyBelongsToAnotherAccount)
    }

    func testAnAccountWithNoVaultAndNoKeyIsReportedAsSuch() async {
        MockURLProtocol.respond(json: "{}", statusCode: 404)

        await sut.refresh()

        XCTAssertEqual(sut.status, .noVault)
    }

    func testAKeyFileImportedByHandCountsAsUnlockedEvenWithNoVault() async {
        // A pasted key bundle is a perfectly good key; the vault is one way to get one, not the
        // only way, and an account created before the vault existed has no other route.
        TestKeys.install()
        MockURLProtocol.respond(json: "{}", statusCode: 404)

        await sut.refresh()

        XCTAssertEqual(sut.status, .unlocked)
    }

    func testAKeyFromAnotherAccountIsNoticedRatherThanUsed() async {
        // Signing out and into a different account leaves the old key behind. Without this check
        // the symptom is every photograph failing to decrypt, one at a time, with no explanation.
        TestKeys.install()
        MockURLProtocol.respond(data: WebVault.responseJSON())

        await sut.refresh()

        XCTAssertEqual(sut.status, .locked)
        XCTAssertTrue(sut.keyBelongsToAnotherAccount)
    }

    func testAnUnreachableServerDoesNotLockADeviceThatHoldsItsKey() async {
        TestKeys.install()
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        await sut.refresh()

        XCTAssertEqual(sut.status, .unlocked,
                       "an unreachable server is not a reason to hide a library the user can browse")
    }

    func testAnUnreachableServerWithNoKeyIsReportedAsUnknownRatherThanNoVault() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        await sut.refresh()

        XCTAssertEqual(sut.status, .unreachable)
    }

    // MARK: - Unlocking

    func testUnlockingWithThePasswordStoresTheWebsIdentityKey() async throws {
        MockURLProtocol.route([
            ("/used", 204, Data()),
            ("/keyvault", 200, WebVault.responseJSON()),
        ])

        let bundle = try await sut.unlock(password: WebVault.password)

        XCTAssertEqual(bundle.publicKey, WebVault.publicKey)
        XCTAssertEqual(bundle.privateKey, WebVault.privateKey)
        XCTAssertEqual(KeyImportService.storedKeys()?.privateKey, WebVault.privateKey)
        XCTAssertEqual(sut.status, .unlocked)
    }

    func testTheUnwrappedKeyIsStoredWhereEveryOtherServiceAlreadyLooks() async throws {
        MockURLProtocol.route([
            ("/used", 204, Data()),
            ("/keyvault", 200, WebVault.responseJSON()),
        ])

        try await sut.unlock(password: WebVault.password)

        // The point of routing through `KeyImportService`: nothing downstream needs to know or care
        // which route the key arrived by.
        XCTAssertTrue(KeyImportService.hasStoredKeys())
        let content = MediaContentService(api: APIClient(session: MockURLProtocol.makeSession()))
        let dek = MediaCrypto.newDEK()
        let sealed = try content.sealDEK(dek)
        XCTAssertEqual(try content.unsealDEK(sealed.sealed, keyVersion: sealed.keyVersion), dek)
    }

    func testAWrongPasswordIsReportedAndStoresNothing() async {
        MockURLProtocol.respond(data: WebVault.responseJSON())

        do {
            try await sut.unlock(password: "wrong")
            XCTFail("expected the unlock to fail")
        } catch {
            XCTAssertEqual(error as? KeyVaultCryptoError, .decryptionFailed)
        }
        XCTAssertFalse(KeyImportService.hasStoredKeys())
        XCTAssertNotEqual(sut.status, .unlocked)
    }

    func testUnlockingWithARecoveryCodeUsesTheRecoveryBlob() async throws {
        MockURLProtocol.route([
            ("/used", 204, Data()),
            ("/keyvault", 200, WebVault.responseJSON(methods: ["password", "recovery"])),
        ])

        // The two blobs wrap the same master key, so the recovery path lands on the same identity —
        // and the code is typed lowercase and hyphenated, as it would be off a printed sheet.
        let bundle = try await sut.unlock(recoveryCode: WebVault.recoveryCode)

        XCTAssertEqual(bundle.publicKey, WebVault.publicKey)
        XCTAssertEqual(bundle.privateKey, WebVault.privateKey)
    }

    func testAMethodThatIsNotEnrolledSaysSoRatherThanFailingObscurely() async {
        MockURLProtocol.respond(data: WebVault.responseJSON(methods: ["password"]))

        do {
            try await sut.unlock(recoveryCode: "ABCD-EFGH")
            XCTFail("expected the missing method to be reported")
        } catch {
            XCTAssertEqual(error as? KeyVaultError, .methodNotEnrolled("recovery"))
        }
    }

    func testAPasskeyOnlyVaultReportsNoPasswordRatherThanAWrongOne() async {
        MockURLProtocol.respond(data: WebVault.responseJSON(methods: ["passkey"]))

        do {
            try await sut.unlock(password: "anything")
            XCTFail("expected the missing method to be reported")
        } catch {
            XCTAssertEqual(error as? KeyVaultError, .methodNotEnrolled("password"))
        }
    }

    func testUnlockingRecordsThatTheMethodWasUsed() async throws {
        MockURLProtocol.route([
            ("/used", 204, Data()),
            ("/keyvault", 200, WebVault.responseJSON()),
        ])

        try await sut.unlock(password: WebVault.password)

        // Fired after the unlock has already succeeded, so it is allowed to be late; poll rather
        // than assume it landed before the call returned.
        try await Self.eventually {
            MockURLProtocol.request { $0.url?.path.hasSuffix("/unlock-0/used") == true } != nil
        }
    }

    // MARK: - Locking

    func testLockingRemovesTheKeyButNotTheVault() async {
        MockURLProtocol.route([
            ("/used", 204, Data()),
            ("/keyvault", 200, WebVault.responseJSON()),
        ])
        _ = try? await sut.unlock(password: WebVault.password)

        sut.lock()

        XCTAssertFalse(KeyImportService.hasStoredKeys())
        XCTAssertEqual(sut.status, .locked, "the vault is still there — unlocking again is a password away")
    }

    // MARK: - Available methods

    func testPasskeysAreOnlyOfferedWhereTheOSCanPerformThem() async {
        MockURLProtocol.respond(data: WebVault.responseJSON(methods: ["password", "passkey"]))
        await sut.refresh()

        let methods = sut.availableMethods.map(\.method)

        // iOS 16 and 17 have passkeys but no `prf` extension. Offering an option that always fails
        // is worse than not offering it.
        XCTAssertTrue(methods.contains("password"))
        XCTAssertEqual(methods.contains("passkey"), PasskeyPRFAuthenticator.isSupported)
    }

    // MARK: - Helpers

    /// Polls `condition` briefly. For the fire-and-forget bookkeeping call, which is deliberately
    /// not awaited by the unlock it follows.
    private static func eventually(timeout: TimeInterval = 2,
                                   _ condition: @MainActor () -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}
