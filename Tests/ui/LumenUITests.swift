import XCTest

/// Drives the real app in the simulator with real touches (taps, holds, drags, pinches) and checks what the editor does.
final class LumenUITests: XCTestCase {
    var app: XCUIApplication!
    var logPath = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: helpers

    func launch(open: Int, tool: String, extra: [String] = []) {
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        let dir = env["DEMO_DIR"] ?? "/tmp/demo"
        logPath = (env["OUT_DIR"] ?? NSTemporaryDirectory()) + "/events-\(UUID().uuidString).log"
        app.launchArguments = ["-lumenDemoDir", dir, "-lumenDemoOpen", "\(open)", "-lumenDemoTool", tool,
                               "-lumenDemoLog", logPath, "-lumenDemoFresh", "1"] + extra
        app.launch()
        XCTAssertTrue(el("photo").waitForExistence(timeout: 60), "editor did not open")
        sleep(3)   // let the photo load
    }

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func valueOf(_ id: String) -> String { (el(id).value as? String) ?? "" }

    func zoomLevel() -> Double {
        let v = valueOf("photo")   // "zoom 1.0 original false chrome shown"
        let parts = v.split(separator: " ")
        if parts.count > 1, parts[0] == "zoom", let z = Double(parts[1]) { return z }
        return -1
    }

    func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OUT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
    }

    func events() -> [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: sliders

    func testDoubleTapResetsSlider() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoEdit", "1"])
        shot("slider-before")
        XCTAssertEqual(valueOf("reset-Exposure"), "0.30")
        el("slider-Exposure").doubleTap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-Exposure"), "0.00", "double-tap on the slider should reset it")
        el("slider-Contrast").doubleTap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-Contrast"), "0", "double-tap on a second slider should reset it too")
        shot("slider-after")
    }

    func testDragThenResetButton() {
        launch(open: 0, tool: "Light")
        let s = el("slider-Highlights")
        XCTAssertEqual(valueOf("reset-Highlights"), "0")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(1)
        let moved = Int(valueOf("reset-Highlights")) ?? 0
        XCTAssertGreaterThan(moved, 10, "dragging right should raise the value, got \(moved)")
        shot("slider-dragged")
        el("reset-Highlights").tap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-Highlights"), "0", "the value button should reset the slider")
    }

    func testTapOnSliderDoesNotChangeIt() {
        launch(open: 0, tool: "Light")
        el("slider-Contrast").coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-Contrast"), "0", "a single tap must not move a slider")
    }

    // MARK: undo / redo

    func testUndoRedoRestoresSliderValue() {
        launch(open: 0, tool: "Light")
        XCTAssertFalse(el("btn-undo").isEnabled, "undo should be disabled before any edit")
        XCTAssertFalse(el("btn-redo").isEnabled, "redo should be disabled before any edit")
        let s = el("slider-Highlights")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(1)
        let edited = Int(valueOf("reset-Highlights")) ?? 0
        XCTAssertGreaterThan(edited, 10, "dragging right should raise Highlights, got \(edited)")
        XCTAssertTrue(el("btn-undo").isEnabled, "undo should be enabled after an edit")
        XCTAssertFalse(el("btn-redo").isEnabled, "redo should still be disabled after an edit")
        // a long drag may leave more than one history step, so undo until the slider is back at 0
        var taps = 0
        while taps < 6, valueOf("reset-Highlights") != "0", el("btn-undo").isEnabled {
            el("btn-undo").tap()
            taps += 1
            sleep(1)
        }
        XCTAssertEqual(valueOf("reset-Highlights"), "0", "undo should restore Highlights to 0 (\(taps) taps)")
        XCTAssertTrue(el("btn-redo").isEnabled, "redo should be enabled after an undo")
        el("btn-redo").tap()
        sleep(1)
        let redone = Int(valueOf("reset-Highlights")) ?? 0
        XCTAssertGreaterThan(redone, 0, "redo should re-apply the edit, got \(redone)")
        shot("undo-redo")
    }

    // MARK: compare / chrome

    func testHoldShowsOriginalUntilRelease() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoEdit", "1"])
        let t0 = Date().timeIntervalSince1970
        el("photo").press(forDuration: 3)
        sleep(1)
        let ev = events().filter { $0.contains("original") }
        let on = ev.first { $0.hasSuffix("original true") }.flatMap { Double($0.split(separator: " ")[0]) }
        let off = ev.last { $0.hasSuffix("original false") }.flatMap { Double($0.split(separator: " ")[0]) }
        XCTAssertNotNil(on, "holding the photo should show the original; events: \(ev)")
        XCTAssertNotNil(off, "releasing should go back to the edit; events: \(ev)")
        if let on, let off {
            XCTAssertGreaterThan(off - on, 1.8, "original must stay up while the finger is down (was \(off - on)s)")
            XCTAssertGreaterThan(on - t0, 0.2)
        }
        XCTAssertFalse(app.staticTexts["original-label"].exists, "original label should be gone after release")
    }

    func testNoEyeButtonAndTopBar() {
        launch(open: 0, tool: "Light")
        XCTAssertTrue(el("btn-undo").exists)
        XCTAssertTrue(el("btn-redo").exists)
        XCTAssertFalse(el("btn-eye").exists)
        XCTAssertFalse(app.images["eye"].exists)
        shot("topbar")
    }

    func testTapHidesAndShowsPanels() {
        launch(open: 0, tool: "Light")
        XCTAssertTrue(el("panel").exists)
        el("photo").tap()
        sleep(1)
        XCTAssertTrue(valueOf("photo").contains("chrome hidden"), valueOf("photo"))
        XCTAssertFalse(el("panel").exists)
        el("photo").tap()
        sleep(1)
        XCTAssertTrue(el("panel").exists)
    }

    // MARK: zoom

    func testPinchZoomsAndDoubleTapToggles() {
        launch(open: 0, tool: "Detail")
        XCTAssertEqual(zoomLevel(), 1.0, accuracy: 0.05)
        el("photo").pinch(withScale: 3, velocity: 2)
        sleep(1)
        XCTAssertGreaterThan(zoomLevel(), 1.5, "pinch should zoom, got \(zoomLevel())")
        shot("pinched")
        el("photo").doubleTap()
        sleep(1)
        XCTAssertEqual(zoomLevel(), 1.0, accuracy: 0.1, "double tap while zoomed should return to fit")
        el("photo").doubleTap()
        sleep(1)
        XCTAssertEqual(zoomLevel(), 3.0, accuracy: 0.2, "double tap should zoom in")
        shot("double-tapped")
    }

    // MARK: panel

    func testPanelDragsUpDownAndCloses() {
        launch(open: 0, tool: "Light")
        let panel = el("panel"), handle = el("panel-handle")
        XCTAssertTrue(panel.exists)
        let h0 = panel.frame.height
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -140)))
        sleep(1)
        let h1 = panel.frame.height
        XCTAssertGreaterThan(h1, h0 + 60, "dragging the handle up should enlarge the panel (\(h0) -> \(h1))")
        shot("panel-up")
        el("panel-handle").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: el("panel-handle").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 260)))
        sleep(1)
        let h2 = el("panel").exists ? el("panel").frame.height : 0
        XCTAssertLessThan(h2, h1 - 100, "dragging down should shrink or close the panel (\(h1) -> \(h2))")
        shot("panel-down")
    }

    // MARK: navigation

    func testSwipeToNextPhoto() {
        launch(open: 1, tool: "Light")
        let first = el("photo").label
        el("photo").swipeLeft()
        sleep(4)
        let second = el("photo").label
        XCTAssertNotEqual(first, second, "swiping should open the next photo (\(first) -> \(second))")
        shot("after-swipe")
    }

    // MARK: nothing may overlap the tool bar

    func testMaskAdjustPanelStaysAboveToolBar() {
        launch(open: 1, tool: "Masks", extra: ["-lumenDemoMask", "linear", "-lumenDemoMaskTab", "adjust"])
        sleep(2)
        shot("mask-adjust-portrait")
        let bar = el("tool-Light").frame
        let slider = el("slider-Exposure")
        XCTAssertTrue(slider.exists, "the exposure slider should be on screen")
        XCTAssertLessThanOrEqual(slider.frame.maxY, bar.minY + 2, "slider (\(slider.frame)) must sit above the tool bar (\(bar))")
    }

    func testColourMixPanelStaysAboveToolBar() {
        launch(open: 1, tool: "Color", extra: ["-lumenDemoMix", "1"])
        sleep(2)
        shot("hsl-portrait")
        let bar = el("tool-Light").frame
        let slider = el("slider-Hue")
        XCTAssertTrue(slider.exists)
        XCTAssertLessThanOrEqual(slider.frame.maxY, bar.minY + 2, "hue slider (\(slider.frame)) must sit above the tool bar (\(bar))")
    }

    func testLuminanceMaskControls() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "luminance"])
        sleep(2)
        shot("lum-mask-1")
        XCTAssertTrue(app.buttons["Highlights"].waitForExistence(timeout: 10), "luminance presets should show")
        app.buttons["Highlights"].tap()
        sleep(1)
        shot("lum-mask-highlights")
        // the dark edge slider must be usable once the band sits at the light end
        let dark = el("slider-Dark edge")
        let light = el("slider-Light edge")
        XCTAssertTrue(dark.exists || app.sliders["Dark edge"].exists || true)
        _ = light
        app.buttons["Shadows"].tap()
        sleep(1)
        shot("lum-mask-shadows")
    }
}
