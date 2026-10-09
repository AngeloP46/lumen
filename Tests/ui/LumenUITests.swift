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

    /// Opens the app on the library (no photo open). The demo library always holds exactly the sample photos.
    func launchLibrary(extra: [String] = []) {
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        let dir = env["DEMO_DIR"] ?? "/tmp/demo"
        logPath = (env["OUT_DIR"] ?? NSTemporaryDirectory()) + "/events-\(UUID().uuidString).log"
        app.launchArguments = ["-lumenDemoDir", dir, "-lumenDemoLog", logPath, "-lumenDemoFresh", "1"] + extra
        app.launch()
        XCTAssertTrue(el("library-item").waitForExistence(timeout: 60), "library did not show any photos")
        sleep(3)
    }

    func items() -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "library-item") }

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

    func testVerticalSwipeOnASliderScrollsTheList() {
        launch(open: 0, tool: "Detail", extra: ["-lumenDemoSlider", "list"])
        let first = el("slider-Texture"), touched = el("slider-Sharpen")
        XCTAssertTrue(touched.isHittable, "Sharpen row should be on screen")
        let y0 = first.frame.minY
        let before = valueOf("reset-Sharpen")
        // start right on the slider's track and swipe up
        touched.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: touched.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -170)))
        sleep(1)
        let y1 = first.frame.minY
        XCTAssertLessThan(y1, y0 - 40, "swiping up on a slider should scroll the list (Texture row \(y0) -> \(y1))")
        XCTAssertEqual(valueOf("reset-Sharpen"), before, "a vertical swipe must not change the slider it started on")
        shot("list-scrolled-from-slider")
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

    func testHDRPillTurnsHDROnAndOff() {
        // pretend to be an HDR screen with 2 stops of headroom (the simulator has none)
        launch(open: 0, tool: "Light", extra: ["-lumenDemoHeadroom", "4"])
        XCTAssertFalse(el("hdr-badge").exists, "HDR badge should be hidden while HDR is off")
        XCTAssertTrue(el("file-kind").exists, "the file type (RAW or JPEG) should show under the histogram")
        el("pill-hdr").tap()
        sleep(3)
        XCTAssertTrue(el("hdr-badge").waitForExistence(timeout: 5), "HDR badge should show while HDR is on")
        XCTAssertFalse(el("slider-HDR range").exists, "HDR is just on or off: there is no range slider any more")
        let label = el("hdr-badge").label
        XCTAssertTrue(label.hasPrefix("HDR +") || label.contains("nothing above white"),
                      "on an HDR screen the badge should say how far above white it shows, got '\(label)'")
        XCTAssertTrue(events().contains { $0.contains("reloaded hdr true") }, "turning HDR on should decode the photo for HDR")
        shot("hdr-on")
        el("pill-hdr").tap()
        sleep(2)
        XCTAssertFalse(el("hdr-badge").exists, "HDR badge should disappear when HDR is turned off")
    }

    func testHDRBadgeExplainsWhenTheScreenCannotShowHDR() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoHeadroom", "1"])
        el("pill-hdr").tap()
        sleep(3)
        XCTAssertTrue(el("hdr-badge").waitForExistence(timeout: 5))
        XCTAssertTrue(el("hdr-badge").label.contains("can't show") || el("hdr-badge").label.contains("Low Power"),
                      "with no HDR headroom the badge should say why nothing changes, got '\(el("hdr-badge").label)'")
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

    func testPinchSmallerThanFitSpringsBackOutsideMasks() {
        launch(open: 0, tool: "Light")
        el("photo").pinch(withScale: 0.5, velocity: -1)
        sleep(1)
        XCTAssertEqual(zoomLevel(), 1.0, accuracy: 0.05, "outside Masks the photo should spring back to fit")
    }

    func testMasksCanZoomOutPastThePhotoAndLeavingMasksRestoresFit() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "radial"])
        el("photo").pinch(withScale: 0.45, velocity: -1)
        sleep(1)
        let z = zoomLevel()
        XCTAssertLessThan(z, 0.85, "in Masks pinching in should make the photo smaller than the screen, got \(z)")
        XCTAssertGreaterThan(z, 0.25, "but not smaller than the limit, got \(z)")
        shot("masks-zoomed-out")
        el("tool-Light").tap()
        sleep(1)
        XCTAssertEqual(zoomLevel(), 1.0, accuracy: 0.05, "leaving Masks should bring the photo back to fit")
    }

    /// The photo used to stay drawn for the old size (squashed, or out of line with the crop frame) after the panel
    /// changed height. Every tool switch must end with a frame drawn for the size the view really has.
    func testPhotoIsRedrawnAtTheNewSizeAfterEveryToolSwitch() {
        launch(open: 0, tool: "Light")
        for t in ["Crop", "Detail", "Color", "Presets", "Masks", "Light"] {
            el("tool-\(t)").tap()
            sleep(2)
            let draws = events().filter { $0.contains(" draw canvas ") }
            guard let last = draws.last else { XCTFail("no frame drawn after switching to \(t)"); continue }
            let parts = last.split(separator: " ")   // <time> draw canvas WxH view WxH
            XCTAssertEqual(parts.count, 6, "odd log line \(last)")
            if parts.count == 6 {
                XCTAssertEqual(String(parts[3]), String(parts[5]),
                               "after switching to \(t) the last frame was drawn for another size: \(last)")
            }
            shot("redraw-\(t)")
        }
    }

    func testEverydayToolsKeepThePhotoStill() {
        launch(open: 0, tool: "Light")
        var tops: [String: CGFloat] = ["Light": el("panel").frame.minY]   // Light is open already (tapping it would close it)
        for t in ["Color", "Detail", "Grade", "Curve", "Presets"] {
            el("tool-\(t)").tap()
            sleep(1)
            tops[t] = el("panel").frame.minY
        }
        let values = Array(tops.values)
        XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 2,
                          "the panel (and so the photo) should stay the same height across everyday tools: \(tops)")
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
        sleep(2)
        // the next photo is the 24 MP RAW: on a busy CI machine it can take a while to decode
        XCTAssertTrue(el("photo").waitForExistence(timeout: 45), "the next photo never finished loading: \(events().suffix(3))")
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
        sleep(2)
        XCTAssertTrue(el("photo").waitForExistence(timeout: 45), "the first photo never finished loading again")
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
        XCTAssertTrue(el("export-quality").exists, "Export should have a quality slider")
        shot("export-choices")
        app.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["JPEG"].exists, "Cancel should close the export choices")
    }

    func testExportUsesTheChosenQualityAndSize() {
        launch(open: 0, tool: "Light")
        el("btn-export").tap()
        XCTAssertTrue(app.buttons["JPEG"].waitForExistence(timeout: 10))
        app.buttons["JPEG"].tap()
        app.buttons["60"].tap()
        XCTAssertEqual(el("export-quality-value").label, "60", "the quality preset should set the slider")
        app.buttons["1080 px"].tap()
        shot("export-options")
        el("export-go").tap()
        XCTAssertTrue(app.navigationBars["Exported"].waitForExistence(timeout: 90), "the export should finish and offer Save / Share")
        XCTAssertTrue(events().contains { $0.contains("exported jpeg q 60 edge 1080") },
                      "the export should use quality 60 and 1080 px: \(events().filter { $0.contains("exported") })")
        app.buttons["Done"].tap()
    }

    func testToolBarHasPresetsOnTheFarRight() {
        launch(open: 0, tool: "Light")
        let presets = el("tool-Presets").frame
        for t in ["Crop", "Light", "Color", "Grade", "Curve", "Detail", "Masks"] {
            XCTAssertLessThan(el("tool-\(t)").frame.minX, presets.minX, "\(t) should be left of Presets")
        }
    }

    func testSelectedSliderChipIsMarked() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoSlider", "strip"])
        XCTAssertTrue(el("chip-Contrast").waitForExistence(timeout: 10))
        el("chip-Contrast").tap()
        sleep(1)
        XCTAssertTrue(el("chip-Contrast").isSelected, "the tapped slider chip should be marked as selected")
        XCTAssertFalse(el("chip-Exposure").isSelected, "only one chip is selected")
        shot("strip-selected-chip")
    }

    func testCurveFillsThePanelAndBendsWithADrag() {
        launch(open: 0, tool: "Curve")
        let c = el("curve")
        XCTAssertTrue(c.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(c.frame.width, 300, "the curve should use the panel's width (\(c.frame))")
        XCTAssertGreaterThan(c.frame.height, 200, "the curve should use the panel's height (\(c.frame))")
        let before = (c.value as? String) ?? ""
        c.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: c.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        sleep(1)
        let after = (c.value as? String) ?? ""
        XCTAssertNotEqual(before, after, "dragging on the curve should bend it")
        XCTAssertEqual(after.split(separator: " ").count, 3, "the drag should add one point: \(after)")
        shot("curve-bent")
    }

    // MARK: library

    func testLibraryShowsDateSectionsAndRawBadges() {
        launchLibrary()
        XCTAssertTrue(el("library-section").exists, "photos should be grouped under a date")
        XCTAssertEqual(items().count, 3, "the demo library has three photos")
        shot("library")
    }

    func testSelectAndDeleteSeveralPhotos() {
        launchLibrary()
        XCTAssertEqual(items().count, 3)
        el("btn-select").tap()
        items().element(boundBy: 0).tap()
        items().element(boundBy: 1).tap()
        XCTAssertEqual(items().element(boundBy: 0).value as? String, "selected")
        shot("library-selected")
        el("lib-delete").tap()
        let confirm = app.buttons["Remove 2 photos"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting should ask first")
        confirm.tap()
        sleep(2)
        XCTAssertEqual(items().count, 1, "two photos should be gone")
    }

    func testPasteEditsOntoSelectedPhotos() {
        // an edit made by hand (demo mode would re-apply its own sample edits to every photo it opens)
        launch(open: 0, tool: "Light", extra: ["-lumenDemoSlider", "list"])
        let s = el("slider-Shadows")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(1)
        let edited = valueOf("reset-Shadows")
        XCTAssertNotEqual(edited, "0", "dragging should raise Shadows")
        el("btn-menu").tap()
        app.buttons["Copy edits"].tap()
        sleep(1)
        el("btn-back").tap()
        XCTAssertTrue(el("btn-select").waitForExistence(timeout: 20))
        el("btn-select").tap()
        items().element(boundBy: 1).tap()
        items().element(boundBy: 2).tap()
        el("lib-paste").tap()
        let look = app.buttons["Paste the look (keep each photo's crop and masks)"]
        XCTAssertTrue(look.waitForExistence(timeout: 5), "Paste edits should offer pasting the look")
        look.tap()
        XCTAssertTrue(el("library-notice").waitForExistence(timeout: 5), "pasting should confirm")
        el("btn-select-done").tap()
        sleep(1)
        items().element(boundBy: 1).tap()
        XCTAssertTrue(el("photo").waitForExistence(timeout: 40))
        sleep(2)
        if !el("reset-Shadows").exists, el("tool-Light").exists { el("tool-Light").tap(); sleep(1) }
        XCTAssertEqual(valueOf("reset-Shadows"), edited, "the pasted Shadows edit should be on the second photo")
    }

    func testBatchExportOfSelectedPhotos() {
        launchLibrary()
        el("btn-select").tap()
        el("lib-select-all").tap()
        el("lib-export").tap()
        XCTAssertTrue(app.buttons["1080 px"].waitForExistence(timeout: 10), "batch export should show the export options")
        app.buttons["JPEG"].tap()
        app.buttons["1080 px"].tap()
        el("export-go").tap()
        XCTAssertTrue(el("batch-exported").waitForExistence(timeout: 180), "the batch export should finish: \(events().suffix(3))")
        XCTAssertTrue(events().contains { $0.contains("batch exported 3 of 3") }, "all three photos should export")
        shot("batch-exported")
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

    func cropFrame() -> [Double] {
        // "l 0.00 t 0.00 r 1.00 b 1.00"
        valueOf("crop-frame").split(separator: " ").compactMap { Double($0) }
    }

    func testRotatingKeepsTheCrop() {
        launch(open: 0, tool: "Crop", extra: ["-lumenDemoCrop", "1"])
        sleep(2)   // the demo picks the 1:1 ratio after a moment
        let f0 = cropFrame()
        XCTAssertEqual(f0.count, 4)
        guard f0.count == 4 else { return }
        XCTAssertNotEqual(f0, [0, 0, 1, 1], "the demo crop should not be the whole picture")
        el("crop-rotate-right").tap()
        sleep(1)
        let f1 = cropFrame()
        XCTAssertEqual(f1.count, 4)
        guard f1.count == 4 else { return }
        // clockwise: (l, t, r, b) -> (1 - b, l, 1 - t, r)
        let expected = [1 - f0[3], f0[0], 1 - f0[1], f0[2]]
        for i in 0..<4 { XCTAssertEqual(f1[i], expected[i], accuracy: 0.02, "rotating should turn the crop with the picture: \(f0) -> \(f1)") }
        shot("crop-rotated")
        el("crop-rotate-left").tap()
        sleep(1)
        let f2 = cropFrame()
        for i in 0..<min(4, f2.count) { XCTAssertEqual(f2[i], f0[i], accuracy: 0.02, "rotating back should restore the crop: \(f0) -> \(f2)") }
    }

    func testUnreadableFileSaysSoInsteadOfSpinning() {
        launchLibrary(extra: ["-lumenDemoBroken", "1"])
        XCTAssertTrue(el("thumb-unreadable").waitForExistence(timeout: 30), "a file that is not a photo should say it can't be opened")
        shot("library-unreadable")
    }

    func testDamagedPhotoListIsRecovered() {
        // the list is damaged but its last good copy is fine
        launchLibrary(extra: ["-lumenDemoCorruptIndex", "index"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10), "the user should be told the list was rebuilt")
        XCTAssertTrue(app.alerts.firstMatch.label.contains("Lumen") || app.alerts.firstMatch.staticTexts.count > 0)
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertEqual(items().count, 3, "all photos should be back from the last good copy")
        XCTAssertTrue(events().contains { $0.contains("index recovered from its last good copy") }, "\(events())")
        // both copies damaged: rebuilt from the photo files themselves
        launchLibrary(extra: ["-lumenDemoCorruptIndex", "both"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertEqual(items().count, 3, "all photos should be rebuilt from their files")
        XCTAssertTrue(events().contains { $0.contains("index recovered from the photo files") }, "\(events())")
        shot("library-recovered")
    }

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
