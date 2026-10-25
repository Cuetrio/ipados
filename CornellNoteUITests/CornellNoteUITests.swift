import XCTest

/// Exercises the Editor drawing tools through the real UI on a simulator.
/// Apple Pencil feel and pressure still require on-device acceptance.
final class CornellNoteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        app.buttons["新規ノート"].tap()
        let note = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '無題のノート'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        XCTAssertTrue(app.buttons["取り消す"].waitForExistence(timeout: 10))
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
        let lineY: CGFloat = 450
        draw(fromX: 300, toX: 650, y: lineY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: 475, aroundY: lineY).isEmpty }, "The stroke must be drawn")
        XCTAssertTrue(app.buttons["取り消す"].isEnabled)

        app.buttons["取り消す"].tap()
        XCTAssertTrue(waitUntil { self.inkPixels(atX: 475, aroundY: lineY).isEmpty }, "Undo must remove the stroke")
        XCTAssertTrue(app.buttons["やり直す"].isEnabled)

        app.buttons["やり直す"].tap()
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: 475, aroundY: lineY).isEmpty }, "Redo must restore the stroke")
        XCTAssertFalse(app.buttons["やり直す"].isEnabled)
    }

    func testEraserRemovesStrokeAndUndoRestoresIt() {
        let lineY: CGFloat = 500
        draw(fromX: 300, toX: 650, y: lineY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: 475, aroundY: lineY).isEmpty })

        app.otherElements["Drawing-Palette"].buttons["Eraser"].tap()
        drawVertical(x: 475, fromY: lineY - 30, toY: lineY + 30)
        XCTAssertTrue(waitUntil { self.inkPixels(atX: 475, aroundY: lineY).isEmpty }, "The eraser must remove the stroke")

        app.buttons["取り消す"].tap()
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: 475, aroundY: lineY).isEmpty }, "Undo must restore the erased stroke")
    }

    func testSelectedColorAppliesToTheNextStroke() {
        let palette = app.otherElements["Drawing-Palette"]
        palette.buttons["Red"].tap()
        XCTAssertTrue(palette.buttons["Red"].isSelected)
        let lineY: CGFloat = 550
        draw(fromX: 300, toX: 650, y: lineY)

        XCTAssertTrue(waitUntil { !self.inkPixels(atX: 475, aroundY: lineY).isEmpty }, "The red stroke must be drawn")
        let pixels = inkPixels(atX: 475, aroundY: lineY)
        let reddest = pixels.max { $0.red - $0.green < $1.red - $1.green }!
        XCTAssertGreaterThan(reddest.red, 150)
        XCTAssertLessThan(reddest.green, 110)
        XCTAssertLessThan(reddest.blue, 110)
    }

    func testDrawingIsSavedAndTitleTypingKeepsFocus() {
        draw(fromX: 300, toX: 650, y: 600)
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.staticTexts["Saved"].exists && !self.app.buttons["保存"].isEnabled },
                      "The stroke must be autosaved")

        let title = app.textFields["ノートのタイトル"]
        title.tap()
        title.typeText("Tools")
        XCTAssertEqual(title.value as? String, "Tools", "The canvas must not take focus from the title field")
    }

    func testSelectedWeightAppliesToTheNextStroke() {
        let lightY: CGFloat = 400
        draw(fromX: 300, toX: 650, y: lightY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: 475, aroundY: lightY).isEmpty })
        let lightThickness = inkPixels(atX: 475, aroundY: lightY, span: 30).count

        let palette = app.otherElements["Drawing-Palette"]
        palette.buttons["Pen"].tap()
        let heaviest = app.buttons.matching(NSPredicate(format: "label == 'Weight' AND value == 'Very Heavy'")).firstMatch
        XCTAssertTrue(heaviest.waitForExistence(timeout: 5), "Tapping the selected pen must show weight choices")
        heaviest.tap()
        XCTAssertTrue(heaviest.isSelected)
        app.otherElements["PopoverDismissRegion"].tap()

        let heavyY: CGFloat = 650
        draw(fromX: 300, toX: 650, y: heavyY)
        XCTAssertTrue(waitUntil { !self.inkPixels(atX: 475, aroundY: heavyY).isEmpty })
        let heavyThickness = inkPixels(atX: 475, aroundY: heavyY, span: 30).count
        // The pen narrows with fast finger strokes, so compare thickness rather than a fixed ratio.
        XCTAssertGreaterThan(heavyThickness, lightThickness, "Very Heavy (\(heavyThickness)px) must be thicker than Light (\(lightThickness)px)")
    }

    // MARK: - Helpers

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func draw(fromX startX: CGFloat, toX endX: CGFloat, y: CGFloat) {
        point(startX, y).press(forDuration: 0.1, thenDragTo: point(endX, y))
    }

    private func drawVertical(x: CGFloat, fromY startY: CGFloat, toY endY: CGFloat) {
        point(x, startY).press(forDuration: 0.1, thenDragTo: point(x, endY))
    }

    private struct Pixel { let red: Int; let green: Int; let blue: Int }

    /// Pixels in a short vertical scan that differ clearly from the light page background.
    private func inkPixels(atX x: CGFloat, aroundY y: CGFloat, span: CGFloat = 12) -> [Pixel] {
        let image = XCUIScreen.main.screenshot().image
        guard let cgImage = image.cgImage else { return [] }
        // Screen points map to pixels by the screenshot scale; app.frame may not match the screen.
        let scale = image.scale
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let column = Int(x * scale)
        var result: [Pixel] = []
        for row in Int((y - span) * scale)...Int((y + span) * scale) {
            let offset = (row * width + column) * 4
            let pixel = Pixel(red: Int(bytes[offset]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset + 2]))
            if min(pixel.red, pixel.green, pixel.blue) < 140 { result.append(pixel) }
        }
        return result
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
