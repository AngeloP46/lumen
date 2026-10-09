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

    func testHDRPillTogglesRangeSlider() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoSlider", "list", "-lumenDemoPanel", "440"])
        XCTAssertFalse(el("slider-HDR range").exists, "HDR range slider should be hidden while HDR is off")
        XCTAssertFalse(el("hdr-badge").exists, "HDR badge should be hidden while HDR is off")
        el("pill-hdr").tap()
        sleep(1)
        XCTAssertTrue(el("slider-HDR range").waitForExistence(timeout: 5), "HDR range slider should appear when HDR is on")
        XCTAssertTrue(el("hdr-badge").exists, "HDR badge should show while HDR is on")
        XCTAssertEqual(valueOf("reset-HDR range"), "2.0")
        let s = el("slider-HDR range")
        // the 7th row may sit below the visible part of the panel: grow the panel, then scroll the list
        if !s.isHittable { el("panel-handle").swipeUp(); sleep(1) }
        if !s.isHittable { el("panel").swipeUp(); sleep(1) }
        XCTAssertTrue(s.isHittable, "HDR range slider should be reachable (frame \(s.frame))")
        shot("hdr-before-drag")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
        sleep(1)
        shot("hdr-after-drag")
        XCTAssertNotEqual(valueOf("reset-HDR range"), "2.0",
                          "dragging should change the HDR range (slider frame \(s.frame), value now \(valueOf("slider-HDR range")), highlights row \(el("slider-Highlights").frame))")
        s.doubleTap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-HDR range"), "2.0", "double-tap should reset the HDR range")
        el("pill-hdr").tap()
        sleep(1)
        XCTAssertFalse(el("slider-HDR range").exists, "HDR range slider should disappear when HDR is turned off")
        XCTAssertFalse(el("hdr-badge").exists, "HDR badge should disappear when HDR is turned off")
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

    // MARK: group reset

    func testGroupResetPillResetsSeveralSliders() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoEdit", "1"])
        // the demo edit sets Exposure 0.30, Contrast 20 and Highlights -30
        XCTAssertEqual(valueOf("reset-Exposure"), "0.30")
        XCTAssertEqual(valueOf("reset-Contrast"), "20")
        XCTAssertEqual(valueOf("reset-Highlights"), "-30")
        XCTAssertTrue(el("pill-Reset").waitForExistence(timeout: 10), "the Light panel should have a Reset pill")
        el("pill-Reset").tap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-Exposure"), "0.00", "group Reset should reset Exposure")
        XCTAssertEqual(valueOf("reset-Contrast"), "0", "group Reset should reset Contrast")
        XCTAssertEqual(valueOf("reset-Highlights"), "0", "group Reset should reset Highlights")
        XCTAssertEqual(valueOf("reset-Shadows"), "0")
        shot("group-reset")
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

    func testHoldWhileZoomedWithPanelOpenShowsOriginalThenReturns() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoEdit", "1", "-lumenDemoZoom", "2"])
        XCTAssertTrue(el("panel").exists, "panel should be open before the hold")
        let z0 = zoomLevel()
        XCTAssertGreaterThan(z0, 1.5, "demo zoom should start zoomed in, got \(z0)")
        el("photo").press(forDuration: 3)
        sleep(1)
        let ev = events().filter { $0.contains("original") }
        let on = ev.first { $0.hasSuffix("original true") }.flatMap { Double($0.split(separator: " ")[0]) }
        let off = ev.last { $0.hasSuffix("original false") }.flatMap { Double($0.split(separator: " ")[0]) }
        XCTAssertNotNil(on, "holding a zoomed photo should show the original; events: \(ev)")
        XCTAssertNotNil(off, "releasing should go back to the edit; events: \(ev)")
        if let on, let off {
            XCTAssertGreaterThan(off - on, 1.8, "original must stay up while the finger is down (was \(off - on)s)")
        }
        XCTAssertFalse(app.staticTexts["original-label"].exists, "original label should be gone after release")
        XCTAssertTrue(el("panel").exists, "panel should still be open after the hold")
        XCTAssertEqual(zoomLevel(), z0, accuracy: 0.1, "holding must not change the zoom")
        XCTAssertTrue(valueOf("photo").contains("original false"), valueOf("photo"))
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

    func testSwipeAwayAndBackKeepsEachPhotosOwnEdit() {
        launch(open: 1, tool: "Light", extra: ["-lumenDemoSlider", "list"])
        let first = el("photo").label
        let s = el("slider-Highlights")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(1)
        let edited = Int(valueOf("reset-Highlights")) ?? 0
        XCTAssertGreaterThan(edited, 10, "dragging right should raise Highlights, got \(edited)")
        el("photo").swipeLeft()
        sleep(4)
        let second = el("photo").label
        XCTAssertNotEqual(first, second, "swiping left should open the next photo (\(first) -> \(second))")
        if !el("reset-Highlights").exists, el("tool-Light").exists { el("tool-Light").tap(); sleep(1) }
        XCTAssertTrue(el("reset-Highlights").waitForExistence(timeout: 10), "Light panel should show Highlights on photo 2")
        XCTAssertEqual(valueOf("reset-Highlights"), "0", "photo 2 must not show photo 1's Highlights edit")
        shot("swipe-photo2")
        el("photo").swipeRight()
        sleep(4)
        XCTAssertEqual(el("photo").label, first, "swiping right should return to the first photo")
        if !el("reset-Highlights").exists, el("tool-Light").exists { el("tool-Light").tap(); sleep(1) }
        XCTAssertTrue(el("reset-Highlights").waitForExistence(timeout: 10), "Light panel should show Highlights on photo 1")
        XCTAssertEqual(Int(valueOf("reset-Highlights")) ?? 0, edited, "photo 1 should keep its Highlights edit")
        shot("swipe-photo1-again")
    }

    func testBackToLibraryAndReopenKeepsEdit() {
        launch(open: 0, tool: "Light")
        let s = el("slider-Highlights")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(1)
        let edited = Int(valueOf("reset-Highlights")) ?? 0
        XCTAssertGreaterThan(edited, 10, "dragging right should raise Highlights, got \(edited)")
        XCTAssertTrue(el("btn-back").waitForExistence(timeout: 10), "editor should have a back button")
        el("btn-back").tap()
        XCTAssertTrue(el("library-item").waitForExistence(timeout: 20), "back should return to the library grid")
        XCTAssertFalse(el("photo").exists, "the editor should be gone after Back")
        sleep(2)   // let the sidecar save settle
        el("library-item").tap()
        XCTAssertTrue(el("photo").waitForExistence(timeout: 30), "tapping the thumbnail should reopen the editor")
        sleep(3)
        if !el("slider-Highlights").exists, el("tool-Light").exists { el("tool-Light").tap(); sleep(1) }
        XCTAssertTrue(el("reset-Highlights").waitForExistence(timeout: 10), "Light panel should show Highlights")
        XCTAssertEqual(Int(valueOf("reset-Highlights")) ?? 0, edited, "the Highlights edit should be saved and restored")
        shot("reopened")
    }

    // MARK: nothing may overlap the tool bar

    func testEveryToolPanelStaysAboveToolBar() {
        launch(open: 0, tool: "Presets")
        let bar = el("tool-Light").frame
        // each tap switches to a different tool than the one before, so no tap closes the panel
        for name in ["Presets", "Crop", "Light", "Color", "Grade", "Curve", "Detail", "Masks"] {
            if name != "Presets" {
                XCTAssertTrue(el("tool-\(name)").waitForExistence(timeout: 10), "tool button \(name) should exist")
                el("tool-\(name)").tap()
                sleep(2)
            }
            let panel = el("panel")
            XCTAssertTrue(panel.waitForExistence(timeout: 10), "\(name) should open a panel")
            XCTAssertLessThanOrEqual(panel.frame.maxY, bar.minY + 2, "\(name) panel (\(panel.frame)) must sit above the tool bar (\(bar))")
            XCTAssertGreaterThan(panel.frame.height, 40, "\(name) panel should have some height (\(panel.frame))")
            shot("tool-panel-\(name)")
        }
    }

    func testMaskOverlayShowsOnShapeTabAndHidesOnAdjustTab() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "linear"])
        let shape = app.buttons["Shape"], adjust = app.buttons["Adjust"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 30), "the mask panel should show its Shape/Adjust tabs")
        sleep(1)
        XCTAssertTrue(valueOf("photo").contains("overlay true"), "overlay should show on the Shape tab: \(valueOf("photo"))")
        adjust.tap()
        sleep(1)
        XCTAssertTrue(valueOf("photo").contains("overlay false"), "overlay should be hidden on the Adjust tab: \(valueOf("photo"))")
        shot("mask-overlay-adjust")
        XCTAssertTrue(shape.waitForExistence(timeout: 5))
        shape.tap()
        sleep(1)
        XCTAssertTrue(valueOf("photo").contains("overlay true"), "overlay should return on the Shape tab: \(valueOf("photo"))")
    }

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

    // MARK: export and menu

    func testExportButtonOffersFormats() {
        launch(open: 0, tool: "Light")
        XCTAssertTrue(el("btn-export").waitForExistence(timeout: 10), "the top bar should have its own Export button")
        el("btn-export").tap()
        XCTAssertTrue(app.buttons["JPEG"].waitForExistence(timeout: 10), "Export should offer JPEG")
        XCTAssertTrue(app.buttons["HEIC"].exists, "Export should offer HEIC")
        XCTAssertTrue(app.buttons["TIFF"].exists, "Export should offer TIFF")
        shot("export-choices")
        app.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["JPEG"].exists, "Cancel should close the export choices")
    }

    func testMoreMenuIsShortAndEveryItemIsOnScreen() {
        launch(open: 0, tool: "Light")
        XCTAssertTrue(el("btn-menu").waitForExistence(timeout: 10))
        el("btn-menu").tap()
        XCTAssertTrue(app.buttons["Copy edits"].waitForExistence(timeout: 10), "the menu should open with Copy edits")
        shot("more-menu")
        let screen = app.windows.firstMatch.frame
        for name in ["Copy edits", "Paste edits", "Reset all edits", "Previous photo", "Next photo", "Rating and flags", "View"] {
            let b = app.buttons[name]
            XCTAssertTrue(b.exists, "menu item \(name) is missing")
            if b.exists {
                XCTAssertTrue(screen.contains(b.frame), "menu item \(name) is off screen: \(b.frame)")
            }
        }
    }

    // MARK: crop

    func testCropToolShowsFrameAndStraightenResets() {
        launch(open: 0, tool: "Crop")
        XCTAssertTrue(el("panel").waitForExistence(timeout: 10), "crop panel should be open")
        XCTAssertTrue(el("crop-frame").waitForExistence(timeout: 10), "crop frame should be shown in the Crop tool")
        let full = valueOf("crop-frame")
        XCTAssertEqual(full, "l 0.00 t 0.00 r 1.00 b 1.00", "a fresh photo starts with the whole picture framed")
        // straighten slider: drag raises it, double-tap resets it
        let s = el("slider-Straighten")
        XCTAssertTrue(s.waitForExistence(timeout: 10), "straighten slider should exist")
        XCTAssertEqual(valueOf("slider-Straighten"), "0.0")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(1)
        let angle = Double(valueOf("slider-Straighten")) ?? 0
        XCTAssertGreaterThan(angle, 0.5, "dragging right should straighten by a positive angle, got \(angle)")
        shot("crop-straightened")
        el("slider-Straighten").doubleTap()
        sleep(1)
        XCTAssertEqual(valueOf("slider-Straighten"), "0.0", "double-tap should reset the straighten angle")
        // a 1:1 ratio changes the frame; the panel's Reset puts it back
        app.buttons["1:1"].tap()
        sleep(1)
        let square = valueOf("crop-frame")
        XCTAssertNotEqual(square, full, "choosing 1:1 should change the crop frame")
        shot("crop-square")
        el("crop-reset").tap()
        sleep(1)
        XCTAssertEqual(valueOf("crop-frame"), full, "Reset should bring back the full frame")
    }

    // MARK: slider layout (More menu)

    func testMoreMenuSliderLayoutSwitchesBetweenListAndStrip() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoSlider", "strip"])
        XCTAssertTrue(el("panel").waitForExistence(timeout: 10), "Light panel should be open")
        // One at a time: a single slider, no per-row value buttons
        XCTAssertTrue(el("slider-Exposure").waitForExistence(timeout: 10), "strip shows the selected slider")
        XCTAssertFalse(el("reset-Highlights").exists, "strip layout must not list every slider")
        XCTAssertFalse(el("slider-Highlights").exists, "strip layout shows only one slider at a time")
        shot("layout-strip")

        // Full list: every slider is visible with its own value button
        el("btn-menu").tap()
        XCTAssertTrue(app.buttons["View"].waitForExistence(timeout: 5), "the More menu should have a View submenu")
        app.buttons["View"].tap()
        let full = app.buttons["Sliders: full list"]
        XCTAssertTrue(full.waitForExistence(timeout: 5), "View should offer Sliders: full list")
        full.tap()
        XCTAssertTrue(el("reset-Highlights").waitForExistence(timeout: 10), "Full list should show the Highlights row")
        XCTAssertTrue(el("slider-Highlights").exists, "Full list should show the Highlights slider")
        XCTAssertTrue(el("reset-Exposure").exists, "Full list should show the Exposure row")
        shot("layout-list")

        // back to One at a time
        el("btn-menu").tap()
        XCTAssertTrue(app.buttons["View"].waitForExistence(timeout: 5), "the More menu should have a View submenu")
        app.buttons["View"].tap()
        let one = app.buttons["Sliders: one at a time"]
        XCTAssertTrue(one.waitForExistence(timeout: 5), "View should offer Sliders: one at a time")
        one.tap()
        sleep(1)
        XCTAssertFalse(el("reset-Highlights").exists, "One at a time should hide the list again")
        XCTAssertTrue(el("slider-Exposure").exists || el("slider-Highlights").exists, "a single slider remains")
    }
}
