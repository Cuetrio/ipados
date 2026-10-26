import XCTest

/// Exercises the Editor through the real UI on a simulator. Every position is derived from the
/// canvas frame, so the tests do not depend on one iPad's screen size. Each test starts and ends
/// with an empty Library, so notes from other tests never mix in.
final class CornellNoteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["新規ノート"].waitForExistence(timeout: 10))
        deleteAllNotes()

        app.buttons["新規ノート"].tap()
        XCTAssertTrue(waitUntil { self.notes.count == 1 }, "The new note must appear in the Library")
        notes.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["取り消す"].waitForExistence(timeout: 10))
        XCTAssertEqual(strokeCount, "線 0 本", "The new note must start blank")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        guard let app else { return }
        if app.buttons["ライブラリ"].exists {
            app.buttons["ライブラリ"].tap()
        }
        if app.buttons["新規ノート"].waitForExistence(timeout: 10) {
            deleteAllNotes()
        }
    }

    func testAppStaysInLandscapeWhenTheDeviceTurnsToPortrait() {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        let screen = XCUIScreen.main.screenshot().image.size
        XCTAssertGreaterThan(screen.width, screen.height, "The screen must stay landscape")
        XCTAssertGreaterThan(canvas.frame.width, canvas.frame.height, "The Editor page must stay landscape")
    }

    func testToolPickerIsShownWithPenSelected() {
        let palette = app.otherElements["Drawing-Palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 10), "The standard tool picker must appear in the Editor")
        let pen = palette.buttons["Pen"]
        XCTAssertTrue(pen.exists)
        XCTAssertTrue(pen.isSelected, "The initial tool is the pen")
        XCTAssertTrue(palette.buttons["Eraser"].exists)
        // The default pen color adapts to the appearance (black in light, white in dark).
        XCTAssertTrue(palette.buttons.matching(NSPredicate(format: "label IN {'Black', 'White'}")).allElementsBoundByIndex.contains { $0.isSelected })
        XCTAssertFalse(app.buttons["取り消す"].isEnabled, "A newly opened note has no drawing history")
        XCTAssertFalse(app.buttons["やり直す"].isEnabled)
    }

    func testUndoAndRedoRemoveAndRestoreTheLastStroke() {
        let lineY = pageY(0.28)
        drawLine(y: lineY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.sampleX, aroundY: lineY).isEmpty }, "The stroke must be drawn")
        XCTAssertTrue(app.buttons["取り消す"].isEnabled)
        XCTAssertTrue(waitUntil { self.strokeCount == "線 1 本" })

        // The simulator sometimes keeps showing a stroke that undo removed, so check the drawing
        // itself rather than the screen.
        app.buttons["取り消す"].tap()
        XCTAssertTrue(waitUntil { self.strokeCount == "線 0 本" }, "Undo must remove the stroke")
        XCTAssertTrue(app.buttons["やり直す"].isEnabled)

        app.buttons["やり直す"].tap()
        XCTAssertTrue(waitUntil { self.strokeCount == "線 1 本" }, "Redo must restore the stroke")
        XCTAssertFalse(app.buttons["やり直す"].isEnabled)
    }

    func testEraserRemovesOnlyTheRubbedPartAndUndoRestoresIt() {
        let lineY = pageY(0.36)
        drawLine(y: lineY)
        XCTAssertTrue(waitUntil { self.strokeCount == "線 1 本" })

        // Like a paint eraser, rubbing across the middle removes only that part of the line.
        app.otherElements["Drawing-Palette"].buttons["Eraser"].tap()
        drag(from: point(sampleX, lineY - 30), to: point(sampleX, lineY + 30))
        XCTAssertTrue(waitUntil { self.inkPixels(atX: self.sampleX, aroundY: lineY).isEmpty }, "The rubbed part must disappear")
        XCTAssertTrue(waitUntil { self.strokeCount == "線 2 本" }, "The line must split into the two parts outside the rubbed area")
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.lineStartX + 50, aroundY: lineY).isEmpty }, "The left part must remain")
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.lineEndX - 50, aroundY: lineY).isEmpty }, "The right part must remain")

        app.buttons["取り消す"].tap()
        XCTAssertTrue(waitUntil { self.strokeCount == "線 1 本" }, "Undo must restore the whole line")
    }

    func testSelectedColorAppliesToTheNextStroke() {
        let palette = app.otherElements["Drawing-Palette"]
        palette.buttons["Red"].tap()
        XCTAssertTrue(palette.buttons["Red"].isSelected)
        let lineY = pageY(0.44)
        drawLine(y: lineY)

        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.sampleX, aroundY: lineY).isEmpty }, "The red stroke must be drawn")
        let pixels = inkPixels(atX: sampleX, aroundY: lineY)
        let reddest = pixels.max { $0.red - $0.green < $1.red - $1.green }!
        XCTAssertGreaterThan(reddest.red, 150)
        XCTAssertLessThan(reddest.green, 110)
        XCTAssertLessThan(reddest.blue, 110)
    }

    func testDrawingIsSavedAndTitleTypingKeepsFocus() {
        drawLine(y: pageY(0.52))
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.staticTexts["Saved"].exists && !self.app.buttons["保存"].isEnabled },
                      "The stroke must be autosaved")

        let title = app.textFields["ノートのタイトル"]
        title.tap()
        title.typeText("Tools")
        XCTAssertEqual(title.value as? String, "Tools", "The canvas must not take focus from the title field")
    }

    func testSelectedWeightAppliesToTheNextStroke() {
        let lightY = pageY(0.20)
        drawLine(y: lightY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.sampleX, aroundY: lightY).isEmpty })
        let lightThickness = inkPixels(atX: sampleX, aroundY: lightY, span: 30).count

        let palette = app.otherElements["Drawing-Palette"]
        palette.buttons["Pen"].tap()
        let heaviest = app.buttons.matching(NSPredicate(format: "label == 'Weight' AND value == 'Very Heavy'")).firstMatch
        XCTAssertTrue(heaviest.waitForExistence(timeout: 5), "Tapping the selected pen must show weight choices")
        heaviest.tap()
        XCTAssertTrue(heaviest.isSelected)
        app.otherElements["PopoverDismissRegion"].tap()

        let heavyY = pageY(0.66)
        drawLine(y: heavyY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.sampleX, aroundY: heavyY).isEmpty })
        let heavyThickness = inkPixels(atX: sampleX, aroundY: heavyY, span: 30).count
        // The pen narrows with fast finger strokes, so compare thickness rather than a fixed ratio.
        XCTAssertGreaterThan(heavyThickness, lightThickness, "Very Heavy (\(heavyThickness)px) must be thicker than Light (\(lightThickness)px)")
    }

    func testPinchZoomsInkTogetherWithTheCornellBackground() {
        let lineY = pageY(0.28)
        drawLine(y: lineY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.sampleX, aroundY: lineY).isEmpty })
        let before = screenLayout()
        XCTAssertGreaterThan(before.inkLeft, before.dividerX, "The stroke starts in the Notes area")

        canvas.pinch(withScale: 2.0, velocity: 1.0)
        sleep(1)
        let after = screenLayout()
        XCTAssertGreaterThan(after.inkRight - after.inkLeft, (before.inkRight - before.inkLeft) * 1.3, "Pinch must zoom the canvas")
        XCTAssertGreaterThan(after.inkLeft, after.dividerX, "The background must zoom with the ink, keeping the stroke in the Notes area")
    }

    func testTwoFingerPinchDoesNotDraw() {
        canvas.pinch(withScale: 2.0, velocity: 1.0)
        sleep(1)
        XCTAssertEqual(strokeCount, "線 0 本", "A two-finger gesture must not add a stroke")
        XCTAssertFalse(app.buttons["取り消す"].isEnabled)
    }

    /// Runs in whichever appearance the simulator uses; run once with the simulator set to dark
    /// (`xcrun simctl ui <device> appearance dark`) to cover both.
    func testCornellBackgroundMatchesTheSystemAppearance() {
        let emptyY = pageY(0.60)
        let screen = screenPixels()
        // The title area uses the system background, so the page must match it in either appearance.
        let systemBackground = screen.darkness(canvas.frame.midX, canvas.frame.minY - 8)
        XCTAssertLessThan(abs(pageColor(atY: emptyY) - systemBackground), 20, "The page must use the system background color")
        XCTAssertNotNil(dividerX(atY: emptyY), "The Cue/Notes divider must be visible")
    }

    // MARK: - Helpers

    private var notes: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '無題のノート'"))
    }

    private var canvas: XCUIElement {
        app.descendants(matching: .any)["note-canvas"]
    }

    private var strokeCount: String? {
        canvas.value as? String
    }

    /// Positions are fractions of the canvas, so they stay inside the Notes area on any iPad.
    private var lineStartX: CGFloat { canvas.frame.minX + canvas.frame.width * 0.38 }
    private var lineEndX: CGFloat { canvas.frame.minX + canvas.frame.width * 0.80 }
    private var sampleX: CGFloat { canvas.frame.minX + canvas.frame.width * 0.59 }

    private func pageY(_ fraction: CGFloat) -> CGFloat {
        canvas.frame.minY + canvas.frame.height * fraction
    }

    /// Every note row, whatever its title; tests that rename a note must still clean it up.
    /// The empty-Library placeholder is also a cell, but it has no button.
    private var libraryRows: XCUIElementQuery {
        app.collectionViews.firstMatch.cells.containing(.button, identifier: nil)
    }

    private func deleteAllNotes(file: StaticString = #filePath, line: UInt = #line) {
        var remaining = 50
        while libraryRows.count > 0 && remaining > 0 {
            remaining -= 1
            let before = libraryRows.count
            libraryRows.element(boundBy: 0).swipeLeft()
            app.buttons["削除"].firstMatch.tap()
            let confirm = app.alerts.buttons["削除"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a note asks for confirmation", file: file, line: line)
            confirm.tap()
            XCTAssertTrue(waitUntil { self.libraryRows.count < before }, "The note must be deleted", file: file, line: line)
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func drag(from start: XCUICoordinate, to end: XCUICoordinate) {
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func drawLine(y: CGFloat) {
        drag(from: point(lineStartX, y), to: point(lineEndX, y))
    }

    private struct Layout { let inkLeft: CGFloat; let inkRight: CGFloat; let dividerX: CGFloat }

    /// Finds the drawn line and the Cornell divider on screen, in points.
    private func screenLayout(file: StaticString = #filePath, line: UInt = #line) -> Layout {
        let frame = canvas.frame
        let screen = screenPixels()
        let page = screen.pagePixel(in: frame, y: frame.minY + frame.height * 0.6)
        var inkY: CGFloat?
        for y in stride(from: frame.minY + 5, to: frame.minY + frame.height * 0.77, by: 1)
        where screen.isInk(sampleX, y, page: page) {
            inkY = y
            break
        }
        guard let inkY else { XCTFail("No ink found", file: file, line: line); return Layout(inkLeft: 0, inkRight: 0, dividerX: 0) }
        // Follow the continuous stroke from the sample point, so page lines on the same row
        // (such as the divider, which is brighter in dark appearance) are not taken as ink.
        var inkLeft = sampleX, inkRight = sampleX
        while inkLeft - 1 > frame.minX && screen.isInk(inkLeft - 1, inkY, page: page) { inkLeft -= 1 }
        while inkRight + 1 < frame.maxX && screen.isInk(inkRight + 1, inkY, page: page) { inkRight += 1 }
        let rowY = min(inkY + frame.height * 0.1, frame.minY + frame.height * 0.75)
        return Layout(inkLeft: inkLeft, inkRight: inkRight, dividerX: dividerX(atY: rowY, in: screen) ?? 0)
    }

    /// The first line right of the canvas edge that differs clearly from the page color.
    private func dividerX(atY y: CGFloat, in screen: ScreenPixels? = nil) -> CGFloat? {
        let screen = screen ?? screenPixels()
        let frame = canvas.frame
        let page = screen.darkness(frame.minX + frame.width * 0.15, y)
        return stride(from: frame.minX + 8, to: frame.maxX - 8, by: 1).first {
            abs(screen.darkness($0, y) - page) > 25
        }
    }

    /// The page brightness at the left edge of the Cue column, away from labels and ink.
    private func pageColor(atY y: CGFloat) -> Int {
        let frame = canvas.frame
        return screenPixels().darkness(frame.minX + frame.width * 0.15, y)
    }

    private struct Pixel { let red: Int; let green: Int; let blue: Int }

    /// An upright RGBA copy of the screen. Screenshots arrive in the device's portrait pixel
    /// layout with an orientation flag, so they are redrawn in the app's landscape orientation.
    private struct ScreenPixels {
        let bytes: [UInt8]
        let width: Int
        let scale: CGFloat

        func pixel(_ x: CGFloat, _ y: CGFloat) -> Pixel {
            let offset = (Int(y * scale) * width + Int(x * scale)) * 4
            return Pixel(red: Int(bytes[offset]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset + 2]))
        }

        /// The empty page color, sampled in the Cue column away from labels and ink.
        func pagePixel(in frame: CGRect, y: CGFloat) -> Pixel {
            pixel(frame.minX + frame.width * 0.15, y)
        }

        /// Ink differs strongly from the page in at least one channel, in light or dark appearance.
        /// The faint Cornell lines stay below this threshold.
        func isInk(_ x: CGFloat, _ y: CGFloat, page: Pixel) -> Bool {
            let p = pixel(x, y)
            return max(abs(p.red - page.red), abs(p.green - page.green), abs(p.blue - page.blue)) > 80
        }

        func darkness(_ x: CGFloat, _ y: CGFloat) -> Int {
            let p = pixel(x, y)
            return min(p.red, p.green, p.blue)
        }
    }

    private func screenPixels() -> ScreenPixels {
        let image = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        let cgImage = upright.cgImage!
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return ScreenPixels(bytes: bytes, width: width, scale: image.scale)
    }

    /// Pixels in a short vertical scan that differ clearly from the page background.
    private func inkPixels(atX x: CGFloat, aroundY y: CGFloat, span: CGFloat = 12) -> [Pixel] {
        let screen = screenPixels()
        let page = screen.pagePixel(in: canvas.frame, y: y)
        return stride(from: y - span, through: y + span, by: 0.5)
            .filter { screen.isInk(x, $0, page: page) }
            .map { screen.pixel(x, $0) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }
}
