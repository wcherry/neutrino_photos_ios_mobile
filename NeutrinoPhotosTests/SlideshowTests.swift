import XCTest
import UIKit
@testable import NeutrinoPhotos

// MARK: - SlideshowControllerTests

@MainActor
final class SlideshowControllerTests: XCTestCase {

    private struct LoadFailed: LocalizedError {
        var errorDescription: String? { "No key on this device." }
    }

    private var display: ExternalDisplayService!
    private var loaded: [String] = []

    override func setUp() async throws {
        display = ExternalDisplayService()
        loaded = []
    }

    private func items(_ count: Int) -> [MediaItem] {
        (0..<count).map { Fixture.item(id: "p\($0)", fileID: "f\($0)") }
    }

    private func makeController(count: Int = 5,
                                startID: String? = nil,
                                interval: TimeInterval = 5,
                                placeholder: @escaping SlideshowController.Placeholder = { _ in nil },
                                loader: SlideshowController.Loader? = nil) -> SlideshowController {
        SlideshowController(
            items: items(count), startID: startID, interval: interval, transition: .slide,
            display: display, placeholder: placeholder,
            loader: loader ?? { [weak self] item in
                self?.loaded.append(item.id)
                return UIImage()
            }
        )
    }

    // MARK: - Moving

    func testStartsOnTheChosenPhotoOrTheFirst() {
        XCTAssertEqual(makeController(startID: "p3").index, 3)
        XCTAssertEqual(makeController(startID: "missing").index, 0)
        XCTAssertEqual(makeController().index, 0)
    }

    func testNextWrapsFromTheLastPhotoToTheFirst() {
        let sut = makeController(count: 3, startID: "p2")

        sut.next()

        XCTAssertEqual(sut.index, 0, "a slideshow loops rather than stopping on a black screen")
        XCTAssertTrue(sut.isAdvancing)
    }

    func testPreviousWrapsFromTheFirstPhotoToTheLast() {
        let sut = makeController(count: 3)

        sut.previous()

        XCTAssertEqual(sut.index, 2)
        XCTAssertFalse(sut.isAdvancing, "stepping back plays a directional transition backwards")
    }

    func testAnAlbumOfOneHasNoNextPhoto() {
        let sut = makeController(count: 1)

        XCTAssertNil(sut.nextItem)
        sut.next()
        XCTAssertEqual(sut.index, 0)
    }

    func testNextItemIsTheFollowingPhoto() {
        XCTAssertEqual(makeController(count: 3, startID: "p2").nextItem?.id, "p0")
    }

    // MARK: - Auto-advance

    func testAutoAdvanceMovesOnAfterTheInterval() async {
        let sut = makeController(interval: 0.01)

        await sut.autoAdvance()

        XCTAssertEqual(sut.index, 1)
    }

    func testAutoAdvanceDoesNothingWhilePaused() async {
        let sut = makeController(interval: 0.01)
        sut.isPlaying = false

        await sut.autoAdvance()

        XCTAssertEqual(sut.index, 0)
    }

    func testAPauseDuringTheCountdownStopsTheAdvance() async {
        let sut = makeController(interval: 0.2)
        let countdown = Task { await sut.autoAdvance() }
        // Into the sleep, so the pause lands mid-countdown rather than before it starts.
        await Task.yield()

        sut.isPlaying = false
        await countdown.value

        XCTAssertEqual(sut.index, 0)
    }

    // MARK: - Loading

    func testTheWindowIsCurrentThenNextThenPrevious() {
        XCTAssertEqual(makeController(count: 5, startID: "p0").windowIndices, [0, 1, 4])
        XCTAssertEqual(makeController(count: 2).windowIndices, [0, 1])
        XCTAssertEqual(makeController(count: 1).windowIndices, [0])
    }

    func testLoadingFetchesTheCurrentPhotoFirst() async {
        let sut = makeController(count: 5, startID: "p2")

        await sut.loadWindow()

        XCTAssertEqual(loaded, ["p2", "p3", "p1"])
        XCTAssertEqual(Set(sut.images.keys), ["p1", "p2", "p3"])
    }

    func testMovingOnDropsPicturesOutsideTheWindow() async {
        let sut = makeController(count: 6, startID: "p1")
        await sut.loadWindow()

        sut.next()
        sut.next()
        await sut.loadWindow()

        XCTAssertEqual(Set(sut.images.keys), ["p2", "p3", "p4"],
                       "an album of thousands must not keep every preview it has shown")
    }

    func testAPhotoAlreadyLoadedIsNotFetchedAgain() async {
        let sut = makeController(count: 5)
        await sut.loadWindow()
        loaded = []

        sut.next()
        await sut.loadWindow()

        XCTAssertEqual(loaded, ["p2"], "only the photo newly in the window is fetched")
    }

    func testAFailureIsReportedAndTheFrameSaysSo() async {
        let sut = makeController(count: 3, loader: { _ in throw LoadFailed() })

        await sut.loadWindow()

        XCTAssertEqual(sut.failures["p0"], "No key on this device.")
        XCTAssertTrue(sut.frame.isUnavailable)
        XCTAssertTrue(display.frame == nil, "not presenting yet, so nothing is sent")
    }

    func testAFailureAfterAThumbnailKeepsTheThumbnail() async {
        let thumbnail = UIImage()
        let sut = makeController(count: 3, placeholder: { _ in thumbnail },
                                 loader: { _ in throw LoadFailed() })

        await sut.loadWindow()

        XCTAssertTrue(sut.frame.image === thumbnail)
        XCTAssertFalse(sut.frame.isUnavailable, "a thumbnail is still a photo worth showing")
    }

    // MARK: - External display

    func testStartingSendsTheCurrentPhotoToTheDisplay() async {
        let sut = makeController(count: 3, startID: "p1")

        sut.start()
        XCTAssertTrue(display.isPresenting)
        XCTAssertEqual(display.frame?.itemID, "p1")
        XCTAssertNil(display.frame?.image)

        await sut.loadWindow()
        XCTAssertNotNil(display.frame?.image, "the picture follows once it has loaded")
    }

    func testMovingSendsTheNewPhotoAndItsDirection() {
        let sut = makeController(count: 3)
        sut.start()

        sut.previous()

        XCTAssertEqual(display.frame?.itemID, "p2")
        XCTAssertFalse(display.isAdvancing)
    }

    func testChangingTheTransitionReachesTheDisplay() {
        let sut = makeController()
        sut.start()

        sut.transition = .zoom

        XCTAssertEqual(display.transition, .zoom)
    }

    func testStoppingReturnsTheDisplayToStandby() {
        let sut = makeController()
        sut.start()

        sut.stop()

        XCTAssertFalse(display.isPresenting)
        XCTAssertNil(display.frame)
    }
}

// MARK: - SlideshowAdjustmentTests

@MainActor
final class SlideshowAdjustmentTests: XCTestCase {

    private var display: ExternalDisplayService!

    override func setUp() async throws {
        display = ExternalDisplayService()
    }

    private func makeController() -> SlideshowController {
        let sut = SlideshowController(
            items: (0..<3).map { Fixture.item(id: "p\($0)", fileID: "f\($0)") },
            interval: 5, transition: .dissolve, display: display,
            placeholder: { _ in nil }, loader: { _ in UIImage() }
        )
        sut.start()
        return sut
    }

    // MARK: - The model

    func testZoomIsKeptWithinItsRange() {
        XCTAssertEqual(PhotoAdjustment(scale: 0.2).clamped().scale, 1)
        XCTAssertEqual(PhotoAdjustment(scale: 40).clamped().scale, 5)
    }

    func testPanIsKeptInsideThePhotograph() {
        // At 2× the photograph is twice its fitted size, so it overhangs by half of that size on
        // each side.
        let clamped = PhotoAdjustment(scale: 2, pan: CGSize(width: 3, height: -3)).clamped()

        XCTAssertEqual(clamped.pan, CGSize(width: 0.5, height: -0.5))
    }

    func testThereIsNothingToPanToAtFittedSize() {
        XCTAssertEqual(PhotoAdjustment(scale: 1, pan: CGSize(width: 0.4, height: 0.1)).clamped().pan,
                       .zero)
    }

    func testPanMeansTheSameOnAnyScreen() {
        // A quarter of the photograph is 50 points on a phone and 480 on a television.
        let adjustment = PhotoAdjustment(scale: 2, pan: CGSize(width: 0.25, height: 0))

        XCTAssertEqual(adjustment.offset(fitted: CGSize(width: 200, height: 150)).width, 50)
        XCTAssertEqual(adjustment.offset(fitted: CGSize(width: 1920, height: 1440)).width, 480)
    }

    func testFittingKeepsTheAspectRatio() {
        let fitted = PhotoAdjustment.fittedSize(of: CGSize(width: 4000, height: 3000),
                                                in: CGSize(width: 1920, height: 1080))

        XCTAssertEqual(fitted.width, 1440, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 1080, accuracy: 0.001)
    }

    // MARK: - The controller

    func testAdjustingReachesTheDisplay() {
        let sut = makeController()

        sut.zoom(by: 2)
        sut.adjust { $0.pan = CGSize(width: 0.1, height: 0.2) }
        sut.flipHorizontally()

        XCTAssertEqual(display.adjustment,
                       PhotoAdjustment(scale: 2, pan: CGSize(width: 0.1, height: 0.2),
                                       isFlippedHorizontally: true))
    }

    func testAdjustingPausesTheSlideshow() {
        let sut = makeController()

        sut.flipVertically()

        XCTAssertFalse(sut.isPlaying, "the clock must not move on from a photo somebody is studying")
    }

    func testDoubleTapZoomsInAndBackOut() {
        let sut = makeController()

        sut.toggleZoom()
        XCTAssertEqual(sut.adjustment.scale, 2.5)

        sut.toggleZoom()
        XCTAssertEqual(sut.adjustment.scale, 1)
    }

    func testZoomingBackOutRecentresThePhoto() {
        let sut = makeController()
        sut.zoom(by: 3)
        sut.adjust { $0.pan = CGSize(width: 0.5, height: 0.5) }

        sut.zoom(by: 1 / 3)

        XCTAssertEqual(sut.adjustment.pan, .zero)
    }

    func testResetPutsEverythingBack() {
        let sut = makeController()
        sut.zoom(by: 2)
        sut.flipHorizontally()

        sut.resetAdjustment()

        XCTAssertTrue(sut.adjustment.isIdentity)
        XCTAssertTrue(display.adjustment.isIdentity)
    }

    func testTheNextPhotoStartsUnadjusted() {
        let sut = makeController()
        sut.zoom(by: 2)
        sut.flipVertically()

        sut.next()

        XCTAssertTrue(sut.adjustment.isIdentity)
        XCTAssertTrue(display.adjustment.isIdentity)
    }

    func testASharperPictureKeepsTheZoom() async {
        let sut = makeController()
        sut.zoom(by: 2)

        await sut.loadWindow()

        XCTAssertEqual(display.adjustment.scale, 2,
                       "the preview replacing the thumbnail is the same photo, still zoomed")
    }
}

// MARK: - ExternalDisplayServiceTests

@MainActor
final class ExternalDisplayServiceTests: XCTestCase {

    func testConnectionIsTracked() {
        let sut = ExternalDisplayService()

        sut.displayDidConnect()
        XCTAssertTrue(sut.isConnected)

        sut.displayDidDisconnect()
        XCTAssertFalse(sut.isConnected)
    }

    func testAFrameOutsideASlideshowIsIgnored() {
        let sut = ExternalDisplayService()

        sut.show(SlideshowFrame(itemID: "p0", image: nil, isUnavailable: false), isAdvancing: true)

        XCTAssertNil(sut.frame, "the display stays on its standby screen")
    }

    func testEachSlideshowIsANewSession() {
        let sut = ExternalDisplayService()
        sut.begin(transition: .dissolve)
        let first = sut.sessionID
        sut.end()

        sut.begin(transition: .dissolve)

        XCTAssertNotEqual(sut.sessionID, first)
    }

    func testASharperPictureOfTheSamePhotoIsAChange() {
        let thumbnail = UIImage(), preview = UIImage()

        XCTAssertNotEqual(SlideshowFrame(itemID: "p0", image: thumbnail, isUnavailable: false),
                          SlideshowFrame(itemID: "p0", image: preview, isUnavailable: false))
        XCTAssertEqual(SlideshowFrame(itemID: "p0", image: preview, isUnavailable: false),
                       SlideshowFrame(itemID: "p0", image: preview, isUnavailable: false))
    }
}

// MARK: - SlideshowSettingsTests

@MainActor
final class SlideshowSettingsTests: XCTestCase {

    func testDefaultsToFiveSecondsAndDissolve() {
        let sut = AppSettings(defaults: makeTemporaryDefaults())

        XCTAssertEqual(sut.slideshowInterval, 5)
        XCTAssertEqual(sut.slideshowTransition, .dissolve)
    }

    func testThePaceAndTransitionAreRemembered() {
        let defaults = makeTemporaryDefaults()
        let sut = AppSettings(defaults: defaults)

        sut.slideshowInterval = 12
        sut.slideshowTransition = .slide

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.slideshowInterval, 12)
        XCTAssertEqual(reloaded.slideshowTransition, .slide)
    }

    func testAStoredIntervalOutsideTheRangeIsClamped() {
        let defaults = makeTemporaryDefaults()
        defaults.set(0.0, forKey: AppSettings.Keys.slideshowInterval)

        XCTAssertEqual(AppSettings(defaults: defaults).slideshowInterval,
                       AppSettings.slideshowIntervalRange.lowerBound)
    }
}
