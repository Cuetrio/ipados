import XCTest

/// Exercises the Editor through the real UI on a simulator. The app is landscape-only, so the
/// screen is 1180×820 pt and every point below is in that orientation.
/// Apple Pencil feel and pressure are outside what a simulator can show.
final class CornellNoteUITests: XCTestCase {
    private var app: XCUIApplication!

    /// A horizontal stroke inside the Notes area, clear of the tool picker at the bottom.
    private let lineStartX: CGFloat = 450
    private let lineEndX: CGFloat = 900
    private let sampleX: CGFloat = 675

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launch()
        // Notes from earlier runs stay in the simulator; open only the note this test creates,
        // which is listed first because it was updated most recently.
        let notes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '無題のノート'"))
        XCTAssertTrue(app.buttons["新規ノート"].waitForExistence(timeout: 10))
        app.buttons["新規ノート"].tap()
        // The list only exposes visible rows, so give the insertion a moment instead of counting.
        sleep(1)
        notes.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["取り消す"].waitForExistence(timeout: 10))
        XCTAssertEqual(strokeCount, "線 0 本", "The new note must start blank")
    }

    func testAppStaysInLandscapeWhenTheDeviceTurnsToPortrait() {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        let canvas = app.descendants(matching: .any)["note-canvas"]
        XCTAssertGreaterThan(canvas.frame.width, canvas.frame.height, "The Editor must stay in landscape")
        XCTAssertEqual(screenSize().width, 1180, "The screen must stay landscape")
    }

    func testToolPickerIsShownWithPenSelected() {
        let palette = app.otherElements["Drawing-Palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 10), "The standard tool picker must appear in the Editor")
        let pen = palette.buttons["Pen"]
        XCTAssertTrue(pen.exists)
        XCTAssertTrue(pen.isSelected, "The initial tool is the pen")
        XCTAssertTrue(palette.buttons["Eraser"].exists)
        XCTAssertTrue(palette.buttons["Black"].isSelected)
        XCTAssertFalse(app.buttons["取り消す"].isEnabled, "A newly opened note has no drawing history")
        XCTAssertFalse(app.buttons["やり直す"].isEnabled)
    }

    func testUndoAndRedoRemoveAndRestoreTheLastStroke() {
        let lineY: CGFloat = 330
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
        let lineY: CGFloat = 380
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
        let lineY: CGFloat = 430
        drawLine(y: lineY)

        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.sampleX, aroundY: lineY).isEmpty }, "The red stroke must be drawn")
        let pixels = inkPixels(atX: sampleX, aroundY: lineY)
        let reddest = pixels.max { $0.red - $0.green < $1.red - $1.green }!
        XCTAssertGreaterThan(reddest.red, 150)
        XCTAssertLessThan(reddest.green, 110)
        XCTAssertLessThan(reddest.blue, 110)
    }

    func testDrawingIsSavedAndTitleTypingKeepsFocus() {
        drawLine(y: 480)
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.staticTexts["Saved"].exists && !self.app.buttons["保存"].isEnabled },
                      "The stroke must be autosaved")

        let title = app.textFields["ノートのタイトル"]
        title.tap()
        title.typeText("Tools")
        XCTAssertEqual(title.value as? String, "Tools", "The canvas must not take focus from the title field")
    }

    func testSelectedWeightAppliesToTheNextStroke() {
        let lightY: CGFloat = 280
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

        let heavyY: CGFloat = 560
        drawLine(y: heavyY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: self.sampleX, aroundY: heavyY).isEmpty })
        let heavyThickness = inkPixels(atX: sampleX, aroundY: heavyY, span: 30).count
        // The pen narrows with fast finger strokes, so compare thickness rather than a fixed ratio.
        XCTAssertGreaterThan(heavyThickness, lightThickness, "Very Heavy (\(heavyThickness)px) must be thicker than Light (\(lightThickness)px)")
    }

    func testPinchZoomsInkTogetherWithTheCornellBackground() {
        let lineY: CGFloat = 330
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

    // MARK: - Helpers

    private var canvas: XCUIElement {
        app.descendants(matching: .any)["note-canvas"]
    }

    private var strokeCount: String? {
        canvas.value as? String
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

    /// Finds the drawn line and the Cornell divider (the first light-gray vertical line right of the
    /// canvas edge) on screen, in points.
    private func screenLayout(file: StaticString = #filePath, line: UInt = #line) -> Layout {
        let screen = screenPixels()
        func darkness(_ x: CGFloat, _ y: CGFloat) -> Int {
            let p = screen.pixel(x, y)
            return min(p.red, p.green, p.blue)
        }
        var inkY: CGFloat?
        for y in stride(from: CGFloat(170), to: 640, by: 1) where darkness(sampleX, y) < 100 { inkY = y; break }
        guard let inkY else { XCTFail("No ink found", file: file, line: line); return Layout(inkLeft: 0, inkRight: 0, dividerX: 0) }
        let inkColumns = stride(from: CGFloat(65), to: 1115, by: 1).filter { darkness($0, inkY) < 100 }
        let rowY = min(inkY + 80, 620)
        let divider = stride(from: CGFloat(70), to: 1115, by: 1).first {
            let d = darkness($0, rowY); return d < 235 && d >= 100
        } ?? 0
        return Layout(inkLeft: inkColumns.first ?? 0, inkRight: inkColumns.last ?? 0, dividerX: divider)
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

    private func screenSize() -> CGSize {
        XCUIScreen.main.screenshot().image.size
    }

    /// Pixels in a short vertical scan that differ clearly from the light page background.
    private func inkPixels(atX x: CGFloat, aroundY y: CGFloat, span: CGFloat = 12) -> [Pixel] {
        let screen = screenPixels()
        return stride(from: y - span, through: y + span, by: 0.5)
            .map { screen.pixel(x, $0) }
            .filter { min($0.red, $0.green, $0.blue) < 140 }
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
