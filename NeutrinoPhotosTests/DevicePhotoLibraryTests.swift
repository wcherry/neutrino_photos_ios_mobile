import Photos
import XCTest
@testable import NeutrinoPhotos

// MARK: - DevicePhotoLibraryTests

/// The parts of the photo-library integration that can be tested without a photo library.
///
/// A simulator has no camera roll worth fetching from and `PHAsset` cannot be constructed, so what
/// is asserted here is everything the app *decides* — how an authorization status maps onto a state
/// the UI can act on, and what a build with no access falls back to. Everything downstream of the
/// framework is written against ``DeviceAsset``, a plain value, which is exactly why that type
/// exists; those assertions live in `MediaMetadataExtractorTests`.
///
/// The two manual verification steps that matter here — granting Limited, and denying outright —
/// are steps 5 and 6 of Epic 5, and they need a device.
@MainActor
final class DevicePhotoLibraryTests: XCTestCase {

    // MARK: - Access

    func testEveryAuthorizationStatusMapsOntoAStateTheUICanAct() {
        XCTAssertEqual(DevicePhotoLibrary.Access(.notDetermined), .notDetermined)
        XCTAssertEqual(DevicePhotoLibrary.Access(.authorized), .authorized)
        XCTAssertEqual(DevicePhotoLibrary.Access(.limited), .limited)
        XCTAssertEqual(DevicePhotoLibrary.Access(.denied), .denied)
        XCTAssertEqual(DevicePhotoLibrary.Access(.restricted), .restricted)
    }

    func testLimitedAccessIsUsableAndRestrictedIsNot() {
        // The distinction the whole screen turns on. A limited grant is a working state over fewer
        // items, not a failure — treating it as one would refuse to read the very photographs the
        // user just chose to share.
        XCTAssertTrue(DevicePhotoLibrary.Access.limited.isUsable)
        XCTAssertTrue(DevicePhotoLibrary.Access.authorized.isUsable)
        XCTAssertFalse(DevicePhotoLibrary.Access.denied.isUsable)
        XCTAssertFalse(DevicePhotoLibrary.Access.notDetermined.isUsable)
    }

    func testRestrictedIsNotFoldedIntoDenied() {
        // They look the same and need different advice: a denied grant is changed in Settings, and
        // a restricted one has no switch for the user to find at all. Sending somebody to Settings
        // to look for something that is not there is worse than saying so.
        XCTAssertNotEqual(DevicePhotoLibrary.Access.restricted, .denied)
        XCTAssertEqual(DevicePhotoLibrary.Access.restricted.displayName, "Restricted")
        XCTAssertEqual(DevicePhotoLibrary.Access.denied.displayName, "No access")
    }

    func testConstructingTheServiceReadsTheStandingAnswerAndPromptsForNothing() {
        // Built in the composition root on every launch, including a launch that never opens
        // Settings. If this prompted, every user would meet a photo-permission alert on first run
        // for a feature the app does not require.
        let sut = DevicePhotoLibrary()

        XCTAssertEqual(sut.access, DevicePhotoLibrary.Access(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)))
        XCTAssertNil(sut.itemCount, "nothing is counted until a screen asks for the number")
    }

    func testTheItemCountIsClearedWhenAccessIsNotUsable() {
        let sut = DevicePhotoLibrary()

        sut.refreshItemCount()

        // On a simulator with no grant this is nil; with one it is a number. Either way the
        // invariant holds: a count is only ever shown for a state that could produce one.
        if !sut.access.isUsable {
            XCTAssertNil(sut.itemCount)
        }
    }

    // MARK: - Naming

    func testAPairedVideoIsNamedForThePhotographItBelongsTo() {
        // Not an index — the file id travels in the photo record's metadata — but somebody browsing
        // the Live Photos folder in Drive has nothing else to go on.
        XCTAssertEqual(PhotosDriveService.livePhotoVideoName(forOriginal: "file-1"),
                       "file-1.live.mov")
    }

    func testTheLivePhotosFolderIsNotTheRenditionsFolder() {
        // Two subfolders, two reasons. A rendition in the root would show as a duplicate photograph;
        // a paired video in the root would show as a two-second clip of somebody's shoes in the
        // timeline, because `type=video` listings are root-scoped too.
        XCTAssertNotEqual(PhotosDriveService.livePhotosFolderName,
                          PhotosDriveService.renditionsFolderName)
    }

    // MARK: - Errors

    func testEveryFailureHasSomethingAUserCanRead() {
        for error in [DeviceLibraryError.notAuthorized, .assetUnavailable, .resourceUnavailable] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
