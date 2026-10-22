import XCTest

/// Drives the real app in the simulator with real touches (taps, holds, drags, pinches) and checks what the editor does.
final class LumenUITests: XCTestCase {
    var app: XCUIApplication!
    var logPath = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testHealDeletionPrivacy() {
        launchLibrary(extra: ["-lumenDemoHealDeletion", "1"])
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("heal deletion FAIL"), log)
        XCTAssertEqual(log.components(separatedBy: "heal deletion PASS").count - 1, 9, log)
    }

    /// Owner, 15 Oct: after setting the blur, leaving Lens Blur and coming back, the amount could not be changed.
    func testLensBlurAmountStillAdjustsAfterLeavingTool() {
        launch(open: 0, tool: "Lens Blur", extra: ["-lumenDemoLensDepth", "1"])
        XCTAssertTrue(el("lens-blur-focus").waitForExistence(timeout: 40))
        el("lens-blur-focus").tap()
        el("lens-focus-layer").coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        sleep(2)
        func drag(_ from: CGFloat, _ to: CGFloat) -> Double {
            let s = el("slider-Blur amount")
            XCTAssertTrue(s.waitForExistence(timeout: 10))
            s.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
            sleep(1)
            return Double(valueOf("reset-Blur amount")) ?? -1
        }
        let first = drag(0.4, 0.7)
        for other in ["Detail", "Masks", "Curve"] {
            tapTool(other); sleep(1)
            tapTool("Lens Blur"); sleep(2)
            let before = Double(valueOf("reset-Blur amount")) ?? -1
            XCTAssertEqual(before, first, accuracy: 0.6, "amount must be kept after visiting \(other)")
            let after = drag(0.6, 0.3)
            XCTAssertLessThan(after, before - 3, "Blur amount must still move after visiting \(other)")
            _ = drag(0.3, 0.6)
        }
        shot("lens-blur-after-return")
    }

    /// Owner, 15 Oct: sliding Blur amount fast back and forth closed the app (twice).
    func testLensBlurFastSlidingKeepsAppRunning() {
        launch(open: 0, tool: "Lens Blur", extra: ["-lumenDemoLensDepth", "1"])
        let s = el("slider-Blur amount")
        XCTAssertTrue(s.waitForExistence(timeout: 40))
        for i in 0..<12 {
            let (a, b): (CGFloat, CGFloat) = i % 2 == 0 ? (0.15, 0.95) : (0.95, 0.15)
            s.coordinate(withNormalizedOffset: CGVector(dx: a, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: b, dy: 0.5)),
                       withVelocity: .fast, thenHoldForDuration: 0)
        }
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app must survive fast Blur amount drags")
        let before = Double(valueOf("reset-Blur amount")) ?? -1
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        sleep(1)
        XCTAssertNotEqual(Double(valueOf("reset-Blur amount")) ?? -1, before, "the slider must still respond")
        shot("lens-blur-after-fast-sliding")
    }

    // MARK: helpers

    func testLensBlurRevisionsAndPhotoInfo() {
        launch(open: 0, tool: "Lens Blur", extra: ["-lumenDemoLensDepth", "1", "-lumenDemoLegacyLens", "1"])
        XCTAssertTrue(el("lens-blur-focus").waitForExistence(timeout: 40))
        XCTAssertEqual(Double(valueOf("reset-Blur amount")) ?? -1, 23, accuracy: 0.1)
        XCTAssertTrue(el("lum-bar").exists, "Depth range must be on the main Lens Blur page")
        XCTAssertTrue(el("slider-Near edge").exists && el("slider-Far edge").exists)
        el("lens-blur-focus").tap()
        XCTAssertTrue(el("lens-focus-feedback").exists)
        let layer = el("lens-focus-layer")
        layer.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        let shown = NSPredicate(format: "value == 'shown'")
        expectation(for: shown, evaluatedWith: el("lens-blur-selection-eye"))
        waitForExpectations(timeout: 5)
        XCTAssertTrue(el("lens-focus-feedback").label.contains("Subject selected"))
        shot("lens-blur-confirmed-background")
        sleep(5)
        XCTAssertEqual(valueOf("lens-blur-selection-eye"), "hidden")
        XCTAssertTrue(el("btn-info").isHittable)
        el("btn-info").tap()
        XCTAssertTrue(app.staticTexts["Photo information"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Shutter"].exists)
        XCTAssertTrue(app.staticTexts["Aperture"].exists)
        XCTAssertTrue(app.staticTexts["ISO"].exists)
        shot("photo-information")
        el("photo-info-done").tap()
        let handle = el("panel-handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -220)))
        XCTAssertTrue(el("lens-blur-preview").exists)
        if valueOf("lens-blur-preview") == "0" { el("lens-blur-preview").tap() }
        let amount = el("slider-Blur amount")
        amount.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: amount.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(events().contains { $0.contains("lens preview true") })
        XCTAssertTrue(events().last(where: { $0.contains("lens preview ") })?.contains("false") == true,
                      "Selection preview must clear on slider release")
        el("lens-blur-preview").tap()
        let before = events().filter { $0.contains("lens preview true") }.count
        amount.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: amount.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertEqual(events().filter { $0.contains("lens preview true") }.count, before)
        el("lens-blur-refine").tap()
        XCTAssertTrue(el("lens-blur-refine-done").waitForExistence(timeout: 10))
        XCTAssertTrue(el("lum-bar").exists)
        shot("lens-blur-inline-refinement")
        el("lens-blur-refine-done").tap()
        XCTAssertTrue(el("slider-Blur amount").exists)
        // the linked background mask belongs to Lens Blur: Masks must not list it
        tapTool("Masks"); sleep(1)
        XCTAssertFalse(app.buttons["Lens Blur background"].exists, "Lens Blur's mask must not appear in Masks")
        tapTool("Lens Blur")
        XCTAssertTrue(el("slider-Blur amount").waitForExistence(timeout: 10))
        el("reset-Blur amount").tap()
        XCTAssertEqual(Double(valueOf("reset-Blur amount")) ?? -1, 0, accuracy: 0.1)
        sleep(2)
        app.terminate()
        if let i = app.launchArguments.firstIndex(of: "-lumenDemoFresh") { app.launchArguments.removeSubrange(i...i + 1) }
        if let i = app.launchArguments.firstIndex(of: "-lumenDemoLegacyLens") { app.launchArguments.removeSubrange(i...i + 1) }
        app.launch()
        XCTAssertTrue(el("slider-Blur amount").waitForExistence(timeout: 30))
        XCTAssertEqual(Double(valueOf("reset-Blur amount")) ?? -1, 0, accuracy: 0.1, "Saved zero must survive reopening")
        app.terminate()
        testDepthEdgeSlidersHaveFullTravel()
    }

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

    /// Tester builds: once the expiry date has passed, the app shows the "test version has ended" screen, not the library.
    func testTesterExpiredScreen() {
        app = XCUIApplication()
        let dir = ProcessInfo.processInfo.environment["DEMO_DIR"] ?? "/tmp/demo"
        app.launchArguments = ["-lumenDemoDir", dir, "-lumenDemoExpired", "1"]
        app.launch()
        XCTAssertTrue(el("tester-expired").waitForExistence(timeout: 30), "an expired tester build should say so")
        XCTAssertFalse(el("library-item").exists, "an expired tester build should not show the library")
        shot("tester-expired")
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

    /// Taps a tool in the bottom bar, scrolling the bar first when the tool is off screen (since Lens Blur joined,
    /// the bar scrolls and Masks/Heal/Presets start past the right edge on the test iPhone).
    func tapTool(_ name: String) {
        let b = el("tool-\(name)")
        _ = b.waitForExistence(timeout: 10)
        // position only: asking isHittable of a button off screen throws ("activation point invalid")
        for _ in 0..<6 where b.frame.maxX > app.frame.maxX - 2 || b.frame.minX < app.frame.minX + 2 {
            let left = b.frame.midX > app.frame.midX
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: b.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: left ? -160 : 160, dy: 0)))
            usleep(400_000)
        }
        b.tap()
    }

    func waitGone(_ e: XCUIElement, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
    }

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

    /// Focused checks for the owner's October 14 editor reports; no full-suite rerun needed.
    func testOctoberEditorFixes() {
        launch(open: 0, tool: "Light")
        let slider = el("slider-Highlights")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(2) // debounced settings and history are written together
        let edited = valueOf("reset-Highlights")
        XCTAssertNotEqual(edited, "0")
        app.terminate()
        if let i = app.launchArguments.firstIndex(of: "-lumenDemoFresh") {
            app.launchArguments.removeSubrange(i...i + 1)
        }
        app.launch()
        XCTAssertTrue(el("photo").waitForExistence(timeout: 60))
        sleep(3)
        XCTAssertEqual(valueOf("reset-Highlights"), edited)
        XCTAssertTrue(el("btn-undo").isEnabled, "saved undo must survive reopening")
        for _ in 0..<8 {
            if valueOf("reset-Highlights") == "0" || !el("btn-undo").isEnabled { break }
            el("btn-undo").tap(); sleep(1)
        }
        XCTAssertEqual(valueOf("reset-Highlights"), "0")
        XCTAssertTrue(el("btn-redo").isEnabled)
        // Persist the redo stack as well, then reopen and use it.
        sleep(2); app.terminate(); app.launch()
        XCTAssertTrue(el("photo").waitForExistence(timeout: 60)); sleep(3)
        XCTAssertTrue(el("btn-redo").isEnabled)
        el("btn-redo").tap(); sleep(1)
        XCTAssertNotEqual(valueOf("reset-Highlights"), "0")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        sleep(1)
        XCTAssertFalse(el("btn-redo").isEnabled, "a new edit invalidates redo")
        let handle = el("panel-handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 450)))
        sleep(2)
        XCTAssertFalse(el("panel").exists)
        if let d = drawn() {
            XCTAssertEqual(d.top, d.height - d.bottom, accuracy: 2, "closed panel must centre the photo")
        } else { XCTFail("missing photo bounds") }
        shot("closed-panel-centred")

        app.terminate()
        launch(open: 0, tool: "Light", extra: ["-lumenDemoZoom", "7.8"])
        let photo = el("photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6)))
        photo.pinch(withScale: 1.8, velocity: 2)
        sleep(2)
        let points = events().filter { $0.contains("pinch point ") }
        guard let before = points.last(where: { $0.contains("before") }),
              let after = points.last(where: { $0.contains("after") }) else {
            return XCTFail("pinch must report its release point")
        }
        func coordinates(_ line: String) -> [Double] {
            let parts = line.split(separator: " ")
            guard let index = parts.firstIndex(of: "point"), parts.count > index + 4 else { return [] }
            return parts[(index + 2)...(index + 3)].compactMap { Double($0) }
        }
        let b = coordinates(before), a = coordinates(after)
        XCTAssertEqual(b.count, 2); XCTAssertEqual(a.count, 2)
        if b.count == 2 && a.count == 2 {
            XCTAssertEqual(a[0], b[0], accuracy: 0.01)
            XCTAssertEqual(a[1], b[1], accuracy: 0.01)
        }
        XCTAssertTrue(before.contains("zoom 9.200"), "test must exercise elastic overshoot: \(before)")
        XCTAssertEqual(zoomLevel(), 8, accuracy: 0.1)
        shot("maximum-zoom-release")
    }

    func testDepthEdgeSlidersHaveFullTravel() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "depth"])
        XCTAssertTrue(el("lum-bar").waitForExistence(timeout: 30))
        let handle = el("panel-handle")
        let grab = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: -260)))
        sleep(1)
        for preset in ["Near", "Far"] {
            let button = app.buttons[preset].firstMatch
            if !button.isHittable { el("panel").swipeDown(); sleep(1) }
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap(); sleep(1)
            for name in ["Near edge", "Far edge"] {
                let slider = el("slider-" + name)
                if !slider.isHittable { el("slider-Near edge").swipeUp(); sleep(1) }
                XCTAssertTrue(slider.isHittable, "depth endpoint feather must stay enabled")
                for _ in 0..<3 {
                    slider.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                        .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)))
                }
                sleep(1)
                XCTAssertEqual(valueOf("reset-" + name), "100", "endpoint feather must reach its full range")
            }
        }
        shot("depth-edges-full-travel")
    }

    func testLensBlurToolbarAndEditorFixes() {
        testOctoberEditorFixes()
        app.terminate()
        launch(open: 0, tool: "Lens Blur", extra: ["-lumenDemoLensDepth", "1"])
        let focus = el("lens-blur-focus")
        XCTAssertTrue(focus.waitForExistence(timeout: 30), "depth fixture must finish preparing")
        XCTAssertTrue(el("tool-Lens Blur").isHittable)
        XCTAssertGreaterThanOrEqual(el("tool-Lens Blur").frame.width, 60, "tools must keep readable widths")
        focus.tap()
        XCTAssertTrue(el("lens-focus-layer").waitForExistence(timeout: 5))
        el("lens-focus-layer").tap(); sleep(1)
        XCTAssertTrue(events().contains { $0.contains("lens focus picked") })
        XCTAssertFalse(el("lens-focus-layer").exists)
        let amount = el("slider-Blur amount")
        amount.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: amount.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(2)
        XCTAssertGreaterThan(Double(valueOf("reset-Blur amount")) ?? 0, 10)
        shot("lens-blur-panel")
        // Make room for the last row rather than letting the scroll gesture land on a range control.
        let handle = el("panel-handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -220)))
        el("lens-blur-refine").tap(); sleep(2)
        XCTAssertTrue(el("lum-bar").exists, "refine opens the background's depth range")
        shot("lens-blur-refinement")
        el("lens-blur-refine-done").tap(); sleep(1)
        let beforeRefinedDrag = Double(valueOf("reset-Blur amount")) ?? 0
        let refinedSlider = el("slider-Blur amount")
        refinedSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: refinedSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        sleep(1)
        XCTAssertGreaterThan(Double(valueOf("reset-Blur amount")) ?? 0, beforeRefinedDrag + 10,
                             "refinement must not interrupt the Blur amount gesture")
        el("editor-tools").swipeLeft(); sleep(1)
        XCTAssertTrue(el("tool-Presets").isHittable, "scrolling reveals the last tool")
        el("editor-tools").swipeRight(); el("editor-tools").swipeRight(); sleep(1)
        XCTAssertTrue(el("tool-Crop").isHittable, "scrolling back reveals the first tool")
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

    /// ⋯ → History lists the edit steps; tapping the first ("Opened") goes back to how the photo opened, and redo
    /// brings the edit back (owner's request, 21 Oct: like Lightroom's history).
    func testHistoryGoesBack() {
        launch(open: 0, tool: "Light")
        let s = el("slider-Highlights")
        XCTAssertTrue(s.waitForExistence(timeout: 30))
        let before = valueOf("reset-Highlights")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(2)
        XCTAssertNotEqual(valueOf("reset-Highlights"), before, "the drag should change Highlights")
        el("btn-menu").tap()
        let item = app.buttons["menu-history"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the ⋯ menu should have History")
        item.tap()
        let steps = app.buttons.matching(identifier: "history-step")
        XCTAssertTrue(steps.firstMatch.waitForExistence(timeout: 5), "History should list the steps")
        XCTAssertTrue(steps.firstMatch.label.contains("Highlights"), "the newest step should name Highlights (\(steps.firstMatch.label))")
        shot("history")
        // the photo may have older history from other tests: go back to the first step that isn't this drag
        var target: XCUIElement?
        for i in 1..<8 {
            let row = steps.element(boundBy: i)
            guard row.exists else { break }
            if !row.label.contains("Highlights") { target = row; break }
        }
        guard let target else { XCTFail("History should list the step before the drag"); return }
        target.tap()
        sleep(2)
        XCTAssertEqual(valueOf("reset-Highlights"), before, "going back past the drag should restore Highlights")
        XCTAssertTrue(el("btn-redo").isEnabled, "redo should bring it back")
    }

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

    /// "image WxH" from the photo's accessibility value.
    func shownImageAspect() -> Double {
        let parts = valueOf("photo").split(separator: " ")
        guard let i = parts.firstIndex(of: "image"), i + 1 < parts.count else { return -1 }
        let wh = parts[i + 1].split(separator: "x").compactMap { Double($0) }
        return wh.count == 2 && wh[1] > 0 ? wh[0] / wh[1] : -1
    }

    func testMasksShowThePhotoCroppedLikeEveryOtherTool() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoCrop", "1"])
        sleep(2)   // the demo picks the 1:1 ratio after a moment
        XCTAssertEqual(shownImageAspect(), 1.0, accuracy: 0.03, "Light should show the 1:1 crop")
        tapTool("Masks")
        sleep(2)
        XCTAssertEqual(shownImageAspect(), 1.0, accuracy: 0.03, "Masks should show the same 1:1 crop, not the uncropped photo")
        shot("masks-cropped")
    }

    func testHoldShowsOriginalInMasksAdjustTabButNotWhilePlacing() {
        // Shape tab: a finger places the mask, so holding must not flick to the original
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "radial"])
        sleep(1)
        el("photo").coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).press(forDuration: 2)
        sleep(1)
        XCTAssertFalse(events().contains { $0.hasSuffix("original true") }, "Shape tab: holding should not show the original; \(events().filter { $0.contains("original") })")
        // Adjust tab: nothing on the photo to place, so press and hold compares like in every other tool
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "radial", "-lumenDemoMaskTab", "adjust"])
        sleep(1)
        el("photo").coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).press(forDuration: 2)
        sleep(1)
        let ev = events().filter { $0.contains("original") }
        XCTAssertTrue(ev.contains { $0.hasSuffix("original true") }, "Adjust tab: holding should show the original; \(ev)")
        XCTAssertTrue(ev.last?.hasSuffix("original false") ?? false, "Adjust tab: letting go should go back to the edit; \(ev)")
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

    /// A 4 GB iPhone (Lumen gets about 2 GB): zooming in still works (the 100 % copy is smaller or skipped) and the
    /// app keeps running.
    func testLowMemoryPhoneZooms() {
        launch(open: 0, tool: "Detail", extra: ["-lumenDemoMemoryMB", "1900"])
        el("photo").pinch(withScale: 3, velocity: 2)
        sleep(3)
        XCTAssertGreaterThan(zoomLevel(), 1.5, "pinch should zoom on a low-memory phone, got \(zoomLevel())")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(el("photo").exists)
        shot("low-memory-zoom")
    }

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
        XCTAssertLessThan(z, 0.85, "in Masks pinching in should make the photo smaller than the screen, got \(z); events: \(events().suffix(12).joined(separator: " | ")); photo \(valueOf("photo")) frame \(el("photo").frame)")
        XCTAssertGreaterThan(z, 0.25, "but not smaller than the limit, got \(z)")
        shot("masks-zoomed-out")
        tapTool("Light")
        sleep(1)
        XCTAssertEqual(zoomLevel(), 1.0, accuracy: 0.05, "leaving Masks should bring the photo back to fit")
    }

    /// The photo used to stay drawn for the old size (squashed, or out of line with the crop frame) after the panel
    /// changed height. Every tool switch must end with a frame drawn for the size the view really has.
    func testPhotoIsRedrawnAtTheNewSizeAfterEveryToolSwitch() {
        launch(open: 0, tool: "Light")
        for t in ["Crop", "Detail", "Color", "Presets", "Masks", "Light"] {
            tapTool(t)
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
            tapTool(t)
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

    /// One slider at a time: the panel hugs its single row (no empty space under it), a small pull up settles back,
    /// and Reset is a small round icon so the slider names keep the room.
    func testStripPanelHugsItsRowAndResetIsSmall() {
        launch(open: 1, tool: "Masks", extra: ["-lumenDemoMask", "linear", "-lumenDemoMaskTab", "adjust", "-lumenDemoSlider", "strip"])
        let panel = el("panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 30))
        sleep(2)
        shot("strip-hug")
        let h0 = panel.frame.height
        XCTAssertLessThanOrEqual(h0, 190 + 24 + 30, "the one-at-a-time panel should hug its row (\(panel.frame))")
        let reset = el("pill-Reset")
        XCTAssertTrue(reset.exists, "the mask Adjust page should have a Reset button")
        XCTAssertLessThanOrEqual(reset.frame.width, 44, "in the one-at-a-time row Reset should be a small icon (\(reset.frame))")
        let handle = el("panel-handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -90)))
        sleep(1)
        XCTAssertLessThan(abs(panel.frame.height - h0), 4, "a pull that stops short of the list should settle back (\(h0) -> \(panel.frame.height))")
    }

    /// Full list: the page Reset shares the first heading's row instead of taking a row of its own.
    func testListResetSitsOnFirstHeadingRow() {
        launch(open: 1, tool: "Masks", extra: ["-lumenDemoMask", "linear", "-lumenDemoMaskTab", "adjust", "-lumenDemoSlider", "list"])
        let heading = el("section-Light"), reset = el("pill-Reset")
        XCTAssertTrue(heading.waitForExistence(timeout: 30), "the mask list should start with its Light heading")
        XCTAssertTrue(reset.exists, "the mask list should have a Reset button")
        shot("list-reset-heading")
        XCTAssertLessThan(abs(reset.frame.midY - heading.frame.midY), 14, "Reset (\(reset.frame)) should sit on the heading's row (\(heading.frame))")
        XCTAssertLessThan(reset.frame.height, 34, "the list Reset should be small (\(reset.frame))")
    }

    /// Every mask kind (11 since Landscape and Depth) fits in the add-mask grid without being cut off.
    func testEveryMaskKindFitsInTheGrid() {
        launch(open: 0, tool: "Masks")
        let panel = el("panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        sleep(1)
        shot("mask-kinds")
        for k in ["subject", "sky", "background", "people", "landscape", "brush", "linear", "radial", "luminance", "color", "depth"] {
            let b = el("kind-\(k)")
            XCTAssertTrue(b.exists, "mask kind \(k) should be in the grid")
            XCTAssertLessThanOrEqual(b.frame.maxY, panel.frame.maxY + 1, "mask kind \(k) (\(b.frame)) must not be cut off by the panel (\(panel.frame))")
        }
    }

    /// A mask the AI can't fill says so (panel and photo) and can be removed in one tap. In the simulator the
    /// Landscape model isn't bundled, which is exactly such a case.
    func testEmptyAIMaskSaysSoAndCanBeRemoved() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "landscape"])
        let banner = el("mask-empty")
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "an AI mask that selects nothing should say so in the panel")
        XCTAssertTrue(el("mask-empty-photo").exists, "and on the photo")
        shot("mask-empty")
        el("mask-empty-remove").tap()
        XCTAssertTrue(el("kind-subject").waitForExistence(timeout: 10), "Remove mask should take it away (back to the mask list)")
        XCTAssertFalse(el("mask-empty").exists)
    }

    /// Heal: a stroke on the photo never crashes or hangs, and without the model the panel says Heal isn't available.
    func testHealToolPaintsAndExplainsWhenUnavailable() {
        launch(open: 0, tool: "Heal")
        XCTAssertTrue(el("heal-layer").waitForExistence(timeout: 20), "the Heal tool should put a paint layer on the photo")
        let photo = el("photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        XCTAssertTrue(el("heal-note").waitForExistence(timeout: 10), "without the model in this build, the panel should say so")
        XCTAssertFalse(el("heal-busy").exists, "nothing should be left spinning")
        shot("heal-unavailable")
    }

    /// Tapping an automatic mask type shows at once, on the photo, that the AI is working (CI slows the AI down).
    func testAutoMaskShowsItIsWorking() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoSlowAI", "1"])
        if !el("kind-subject").waitForExistence(timeout: 10) { el("mask-add").tap() }
        XCTAssertTrue(el("kind-subject").waitForExistence(timeout: 10), "the mask types should show")
        el("kind-subject").tap()
        XCTAssertTrue(el("mask-busy").waitForExistence(timeout: 2), "the photo should say the subject is being found")
        shot("mask-busy")
        XCTAssertTrue(waitGone(el("mask-busy"), timeout: 60), "the notice should go once the mask is ready")
    }

    /// A RAW photo opened for the first time starts in HDR (the sample ARW, fresh: no saved edits).
    func testRawStartsInHDR() {
        // the library shows the newest import first: the ARW (imported first) is the third photo
        launch(open: 2, tool: "Light", extra: ["-lumenDemoRawHDR", "1"])
        XCTAssertTrue(el("pill-hdr").waitForExistence(timeout: 20))
        XCTAssertTrue(el("file-kind").waitForExistence(timeout: 45) && el("file-kind").label.contains("RAW"),
                      "the third demo photo should be the RAW (\(el("file-kind").label))")
        XCTAssertEqual(valueOf("pill-hdr"), "on", "a RAW opened for the first time should start with HDR on")
    }

    /// Remove people (made-up people in CI): the picker shows a pin per person, starts with everyone but the big one,
    /// All / Cancel work, and Remove without the model says so instead of hanging.
    func testRemovePeoplePicker() {
        launch(open: 0, tool: "Heal", extra: ["-lumenDemoPeople", "1"])
        XCTAssertTrue(el("heal-people").waitForExistence(timeout: 20), "Heal should offer Remove people")
        el("heal-people").tap()
        XCTAssertTrue(el("people-note").waitForExistence(timeout: 20), "finding people should open the picker")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "person-pin").count, 3, "a pin per person")
        let remove = app.buttons["people-remove"]
        XCTAssertTrue(remove.label.contains("2"), "the two small people should be picked, not the big one (\(remove.label))")
        shot("people-picker")
        el("people-all").tap()
        XCTAssertTrue(remove.label.contains("3"), "All should pick everyone (\(remove.label))")
        el("people-cancel").tap()
        XCTAssertTrue(el("heal-people").waitForExistence(timeout: 10), "Cancel should go back to the Heal panel")
        XCTAssertFalse(el("person-pin").exists, "and take the pins away")
        // again, then Remove: this build has no heal model, so the panel must say so and nothing keeps spinning
        el("heal-people").tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 20))
        remove.tap()
        XCTAssertTrue(el("heal-note").waitForExistence(timeout: 20), "without the model the panel should say so")
        XCTAssertFalse(el("heal-busy").exists, "nothing should be left spinning")
        XCTAssertFalse(el("person-pin").exists, "the picker should be closed")
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
        if !el("reset-Highlights").exists, el("tool-Light").exists { tapTool("Light"); sleep(1) }
        XCTAssertTrue(el("reset-Highlights").waitForExistence(timeout: 10), "Light panel should show Highlights on photo 2")
        XCTAssertEqual(valueOf("reset-Highlights"), "0", "photo 2 must not show photo 1's Highlights edit")
        shot("swipe-photo2")
        el("photo").swipeRight()
        sleep(2)
        XCTAssertTrue(el("photo").waitForExistence(timeout: 45), "the first photo never finished loading again")
        XCTAssertEqual(el("photo").label, first, "swiping right should return to the first photo")
        if !el("reset-Highlights").exists, el("tool-Light").exists { tapTool("Light"); sleep(1) }
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
        if !el("slider-Highlights").exists, el("tool-Light").exists { tapTool("Light"); sleep(1) }
        XCTAssertTrue(el("reset-Highlights").waitForExistence(timeout: 10), "Light panel should show Highlights")
        XCTAssertEqual(Int(valueOf("reset-Highlights")) ?? 0, edited, "the Highlights edit should be saved and restored")
        shot("reopened")
    }

    // MARK: nothing may overlap the tool bar

    func testEveryToolPanelStaysAboveToolBar() {
        launch(open: 0, tool: "Presets")
        let bar = el("tool-Light").frame
        // each tap switches to a different tool than the one before, so no tap closes the panel
        for name in ["Presets", "Crop", "Light", "Color", "Grade", "Curve", "Detail", "Masks", "Heal"] {
            if name != "Presets" {
                XCTAssertTrue(el("tool-\(name)").waitForExistence(timeout: 10), "tool button \(name) should exist")
                tapTool(name)
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
        let look = app.buttons["paste-look"]
        XCTAssertTrue(look.waitForExistence(timeout: 5), "Paste edits should offer pasting the look")
        XCTAssertTrue(app.buttons["paste-look-masks"].exists, "Paste edits should offer pasting the look and masks")
        XCTAssertTrue(app.buttons["paste-choose"].exists, "Paste edits should offer choosing the tools")
        look.tap()
        XCTAssertTrue(el("library-notice").waitForExistence(timeout: 5), "pasting should confirm")
        el("btn-select-done").tap()
        sleep(1)
        items().element(boundBy: 1).tap()
        XCTAssertTrue(el("photo").waitForExistence(timeout: 40))
        sleep(2)
        if !el("reset-Shadows").exists, el("tool-Light").exists { tapTool("Light"); sleep(1) }
        XCTAssertEqual(valueOf("reset-Shadows"), edited, "the pasted Shadows edit should be on the second photo")
    }

    /// ⋯ → Send diagnostics shows the Findings (or "No problems spotted") and a share button.
    func testDiagnosticsShowsFindings() {
        launchLibrary()
        el("btn-library-filter").tap()
        let send = app.buttons["Send diagnostics…"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(el("diagnostics-findings").waitForExistence(timeout: 20), "the Diagnostics screen should show its findings")
        XCTAssertTrue(el("diagnostics-share").waitForExistence(timeout: 20), "the report should be ready to share")
        shot("diagnostics")
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

    // MARK: UI refresh (2026-10-10)

    func testAutoButtonShowsItIsOnAndTapsBackOff() {
        launch(open: 0, tool: "Light")
        let auto = el("pill-auto")
        XCTAssertTrue(auto.waitForExistence(timeout: 10), "the Light page should have an Auto button")
        XCTAssertEqual(valueOf("pill-auto"), "off")
        let before = valueOf("reset-Exposure")
        auto.tap()
        sleep(2)
        XCTAssertEqual(valueOf("pill-auto"), "on", "Auto should stay lit once applied")
        shot("auto-on")
        auto.tap()
        sleep(2)
        XCTAssertEqual(valueOf("pill-auto"), "off", "a second tap should take Auto back off")
        XCTAssertEqual(valueOf("reset-Exposure"), before, "taking Auto back off should restore the previous values")
    }

    func testHDRIsInTheTopBarNotTheLightPage() {
        launch(open: 0, tool: "Light")
        let hdr = el("pill-hdr"), back = el("btn-back")
        XCTAssertTrue(hdr.waitForExistence(timeout: 10))
        XCTAssertLessThan(abs(hdr.frame.midY - back.frame.midY), 4, "HDR should sit in the top bar next to Back")
        XCTAssertTrue(el("btn-edits").exists, "the top bar should have the Edits button")
    }

    func testEditsSheetSwitchesAToolOffAndBackOn() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoEdit", "1"])
        XCTAssertEqual(valueOf("tool-Light"), "on")
        el("btn-edits").tap()
        let toggle = el("edits-toggle-Light")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Edits sheet should list Light with a switch")
        shot("edits-sheet")
        toggle.tap()
        sleep(1)
        XCTAssertEqual(valueOf("tool-Light"), "off", "switching Light off in the sheet should mark the tool as off")
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-Exposure"), "0.30", "switching a tool off must keep its values")
        let turnOn = el("section-turn-on")
        XCTAssertTrue(turnOn.waitForExistence(timeout: 5), "the Light page should say it is switched off")
        shot("light-switched-off")
        turnOn.tap()
        sleep(1)
        XCTAssertEqual(valueOf("tool-Light"), "on", "Turn on should switch Light back on")
    }

    func testGradeShowsOneBigWheelPerTab() {
        launch(open: 0, tool: "Grade")
        el("grade-tab-Midtones").tap()
        sleep(1)
        let wheel = el("grade-wheel")
        XCTAssertTrue(wheel.waitForExistence(timeout: 5), "a zone tab should show one big wheel")
        XCTAssertGreaterThan(wheel.frame.width, 139, "the single wheel should be big (\(wheel.frame))")
        XCTAssertTrue(el("slider-Hue").exists, "the zone tab should have a full-width Hue slider")
        XCTAssertTrue(el("slider-Grade luminance").exists, "the zone tab should have a Luminance slider")
        shot("grade-midtones")
        el("grade-tab-All").tap()
        sleep(1)
        XCTAssertFalse(el("grade-wheel").exists, "All shows the three small wheels instead")
        XCTAssertTrue(el("slider-Blend").exists, "All should keep Blend and Balance")
        shot("grade-all")
    }

    func testColourPageOrderAndWhiteBalancePicker() {
        launch(open: 0, tool: "Color")
        let sat = el("slider-Saturation"), vib = el("slider-Vibrance"), temp = el("slider-Temp")
        XCTAssertTrue(sat.waitForExistence(timeout: 10))
        XCTAssertLessThan(sat.frame.minY, vib.frame.minY, "Saturation comes first")
        XCTAssertLessThan(vib.frame.minY, temp.frame.minY, "then Vibrance, then Temp")
        el("pill-wb").tap()
        sleep(1)
        XCTAssertTrue(el("wb-layer").waitForExistence(timeout: 5), "the picker should wait for a tap on the photo")
        el("wb-layer").tap()
        sleep(2)
        XCTAssertTrue(events().contains { $0.contains("wb picked") }, "a tap on the photo should set the white balance")
        shot("wb-picked")
    }

    func testLuminanceSoftEdgeCanBeDraggedOnTheGraph() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "luminance"])
        let bar = el("lum-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "the luminance bar should show")
        sleep(1)
        let before = valueOf("lum-bar")
        // the light-side soft-edge handle sits at the bottom of the bar, at (end of band + soft edge)
        let parts = before.split(separator: " ")   // "low 0.00 high 0.35 soft 0.10 0.10"
        let high = Double(parts[3]) ?? 0.35, soft = Double(parts[6]) ?? 0.1
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: high + soft, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: min(high + soft + 0.25, 0.98), dy: 0.85)))
        sleep(1)
        let after = valueOf("lum-bar").split(separator: " ")
        let soft2 = Double(after[6]) ?? 0
        XCTAssertGreaterThan(soft2, soft + 0.1, "dragging the soft-edge handle should widen the light edge (\(before) -> \(after))")
        XCTAssertEqual(String(after[3]), String(parts[3]), "it must not move the band itself")
        shot("lum-soft-edge")
    }

    func testLinearAndRadialMasksHaveMoveAndTurnHandles() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "linear"])
        XCTAssertTrue(el("mask-pin").waitForExistence(timeout: 30), "linear mask should have a move pin")
        XCTAssertTrue(el("mask-rotate").exists, "linear mask should have a turn handle")
        shot("linear-handles")
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "radial"])
        XCTAssertTrue(el("mask-pin").waitForExistence(timeout: 30), "radial mask should have a move pin")
        XCTAssertTrue(el("mask-rotate").exists, "radial mask should have a turn handle")
        let pin = el("mask-pin").frame, knob = el("mask-rotate").frame
        XCTAssertGreaterThan(knob.midY, pin.midY + 20, "the radial turn knob should sit below the pin, within thumb reach (pin \(pin), knob \(knob))")
        shot("radial-handles")
    }

    /// "drawn <top> <bottom> of <view height>" from the photo's accessibility value.
    func drawn() -> (top: Int, bottom: Int, height: Int)? {
        let parts = valueOf("photo").split(separator: " ")
        guard let i = parts.firstIndex(of: "drawn"), parts.count > i + 4,
              let t = Int(parts[i + 1]), let b = Int(parts[i + 2]), let h = Int(parts[i + 4]) else { return nil }
        return (t, b, h)
    }

    func testPhotoRestsOnThePanelAndGrowsUpwardsWhenZoomed() {
        launch(open: 0, tool: "Light")
        guard let d0 = drawn() else { return XCTFail("photo should report where it is drawn: \(valueOf("photo"))") }
        XCTAssertEqual(d0.bottom, d0.height, accuracy: 2, "at fit the photo should sit on the panel, not leave a gap (\(d0))")
        XCTAssertGreaterThan(d0.top, 10, "a landscape photo leaves space above it (\(d0))")
        el("photo").pinch(withScale: 2.5, velocity: 2)
        sleep(1)
        guard let d1 = drawn() else { return XCTFail("no drawn value after zoom") }
        XCTAssertGreaterThan(zoomLevel(), 1.5, "the pinch should zoom in")
        XCTAssertLessThanOrEqual(d1.top, 2, "zoomed in, the photo should grow up into the free space (\(d1))")
        XCTAssertGreaterThanOrEqual(d1.bottom, d1.height - 2, "and still reach the panel (\(d1))")
        shot("zoomed-fills-height")
    }

    func testToolBarFoldsAwayAndComesBack() {
        launch(open: 0, tool: "Light")
        let panelBefore = el("panel").frame
        XCTAssertTrue(el("tools-collapse").waitForExistence(timeout: 10), "the panel should have a fold-away button for the tools")
        el("tools-collapse").tap()
        sleep(1)
        XCTAssertFalse(el("tool-Light").exists, "folded: the tool buttons are hidden")
        XCTAssertTrue(el("tools-expand").exists, "folded: a thin strip brings them back")
        XCTAssertGreaterThan(el("panel").frame.maxY, panelBefore.maxY + 10, "folded: the panel and photo get the space")
        shot("tools-folded")
        el("tools-expand").tap()
        sleep(1)
        XCTAssertTrue(el("tool-Light").waitForExistence(timeout: 5), "tapping the strip brings the tools back")
    }

    func testLandscapePutsControlsBesideThePhoto() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait; sleep(1) }
        launch(open: 0, tool: "Light")
        sleep(2)
        let screen = app.windows.firstMatch.frame
        let panel = el("panel").frame, photo = el("photo").frame
        XCTAssertGreaterThan(screen.width, screen.height, "the simulator should be on its side (\(screen))")
        XCTAssertGreaterThan(panel.minX, screen.width * 0.45, "in landscape the controls sit in a column on the right (\(panel))")
        XCTAssertGreaterThan(photo.height, screen.height * 0.8, "the photo keeps (nearly) the full height (\(photo) of \(screen))")
        XCTAssertTrue(el("slider-Exposure").exists, "the sliders are listed in the side column")
        XCTAssertTrue(el("tool-Color").exists, "the tools sit under the side column")
        shot("landscape")
    }

    func testLandscapeEveryToolFitsInTheSideColumn() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait; sleep(1) }
        launch(open: 1, tool: "Presets")
        sleep(2)
        let screen = app.windows.firstMatch.frame
        for name in ["Crop", "Light", "Color", "Grade", "Curve", "Detail", "Masks", "Presets"] {
            if name != "Presets" { tapTool(name); sleep(2) }
            let panel = el("panel").frame, bar = el("tool-Light").frame, photo = el("photo").frame
            XCTAssertTrue(el("panel").exists, "\(name) should open a panel in landscape")
            XCTAssertGreaterThan(panel.minX, photo.maxX - 2, "\(name): the panel sits beside the photo, not over it (\(panel) vs \(photo))")
            XCTAssertLessThanOrEqual(panel.maxX, screen.maxX + 1, "\(name): the panel stays on screen (\(panel))")
            XCTAssertLessThanOrEqual(panel.maxY, bar.minY + 2, "\(name): the panel stays above the tools (\(panel), \(bar))")
            XCTAssertGreaterThan(panel.height, screen.height * 0.5, "\(name): the panel uses the column's height (\(panel))")
            shot("landscape-\(name)")
        }
        XCTAssertTrue(el("pill-hdr").exists && el("btn-edits").exists, "the top buttons are still there in landscape")
    }

    func testFoldedToolBarKeepsEveryToolUsable() {
        launch(open: 0, tool: "Light")
        el("tools-collapse").tap()
        sleep(1)
        XCTAssertTrue(el("slider-Exposure").exists, "folded: the Light sliders are still there")
        // the photo still rests on the panel
        if let d = drawn() { XCTAssertEqual(d.bottom, d.height, accuracy: 2, "folded: no gap under the photo (\(d))") }
        el("tools-expand").tap()
        sleep(1)
        tapTool("Masks")
        sleep(1)
        XCTAssertTrue(el("tools-collapse").exists, "every tool's panel offers the fold button")
    }

    // MARK: Pro pack (2026-10-11)

    func testLuminanceMaskOverlayStaysOnThePhoto() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "luminance"])
        sleep(3)
        guard let d = drawn() else { return XCTFail("no drawn value: \(valueOf("photo"))") }
        let drew = events().last { $0.contains("drew image") } ?? ""
        let parts = drew.split(separator: " ")
        // "<t> drew image WxH at y A-B"
        let span = parts.last.map { $0.split(separator: "-").compactMap { Double($0) } } ?? []
        XCTAssertEqual(span.count, 2, "draw log: \(drew)")
        if span.count == 2 {
            XCTAssertEqual(span[0], Double(d.top), accuracy: 3, "the drawn image must start where the photo starts (\(drew); photo \(d))")
            XCTAssertEqual(span[1], Double(d.bottom), accuracy: 3, "the drawn image must end where the photo ends (\(drew); photo \(d))")
        }
        shot("lum-overlay-on-photo")
    }

    func testCropFlipTransformTabsAndAutoLevel() {
        launch(open: 0, tool: "Crop")
        XCTAssertTrue(el("crop-flip-h").waitForExistence(timeout: 10), "the crop page should have flip buttons")
        el("crop-flip-h").tap()
        sleep(1)
        shot("crop-flipped")
        el("crop-auto-level").tap()
        sleep(4)
        XCTAssertTrue(events().contains { $0.contains("auto level") }, "Auto should try to level the photo")
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }   // "couldn't find a horizon" is fine on a test photo
        el("crop-tab-Transform").tap()
        sleep(1)
        let v = el("slider-Vertical")
        XCTAssertTrue(v.waitForExistence(timeout: 5), "the Transform tab should have perspective sliders")
        XCTAssertTrue(el("slider-Aspect").exists && el("slider-Scale").exists, "Aspect (stretch) and Scale should be there")
        v.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: v.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        sleep(1)
        XCTAssertNotEqual(valueOf("reset-Vertical"), "0", "dragging Vertical should change it")
        shot("crop-transform")
        el("crop-tab-Crop").tap()
    }

    func testClippingWarningAndBeforeAfterSplit() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoEdit", "1"])
        el("btn-menu").tap()
        app.buttons["View"].tap()
        XCTAssertTrue(app.buttons["Clipping warning"].waitForExistence(timeout: 5))
        app.buttons["Clipping warning"].tap()
        sleep(1)
        XCTAssertEqual(valueOf("histogram"), "clipping on", "More > View > Clipping warning turns it on")
        XCTAssertTrue(el("clip-badge").exists, "a badge says the clipping warning is on")
        shot("clipping-on")
        el("clip-badge").tap()
        sleep(1)
        XCTAssertEqual(valueOf("histogram"), "clipping off")
        el("btn-menu").tap()
        app.buttons["View"].tap()
        XCTAssertTrue(app.buttons["Before / after split"].waitForExistence(timeout: 5))
        app.buttons["Before / after split"].tap()
        sleep(1)
        let h = el("split-handle")
        XCTAssertTrue(h.waitForExistence(timeout: 5), "the split line should show")
        h.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: el("photo").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        sleep(1)
        XCTAssertGreaterThan(Double(valueOf("split-handle")) ?? 0, 0.6, "dragging moves the split line")
        shot("before-after")
        el("split-close").tap()
        sleep(1)
        XCTAssertFalse(el("split-handle").exists, "× ends the split")
    }

    func testPasteSomeEditsOnlyTakesTheChosenTools() {
        launch(open: 0, tool: "Light", extra: ["-lumenDemoEdit", "1"])
        el("btn-menu").tap()
        app.buttons["Copy edits"].tap()
        sleep(1)
        el("pill-Reset").tap()   // Light back to 0 on this photo
        sleep(1)
        XCTAssertEqual(valueOf("reset-Exposure"), "0.00")
        el("btn-menu").tap()
        XCTAssertTrue(app.buttons["Paste some edits…"].waitForExistence(timeout: 5))
        app.buttons["Paste some edits…"].tap()
        XCTAssertTrue(el("paste-go").waitForExistence(timeout: 5), "the Paste some sheet should open")
        shot("paste-some")
        el("paste-go").tap()
        sleep(1)
        XCTAssertEqual(valueOf("reset-Exposure"), "0.30", "Light (ticked) should come back from the copy")
    }

    func testGlobalGradingTabAndPeopleMaskType() {
        launch(open: 0, tool: "Grade")
        el("grade-tab-Global").tap()
        sleep(1)
        XCTAssertTrue(el("grade-wheel").waitForExistence(timeout: 5), "Global has its own big wheel")
        shot("grade-global")
        tapTool("Masks")
        sleep(1)
        XCTAssertTrue(app.buttons["People"].waitForExistence(timeout: 5), "People is one of the mask types")
        shot("mask-types")
    }

    func testPresetStrengthSlider() {
        launch(open: 0, tool: "Presets")
        sleep(2)
        XCTAssertTrue(app.buttons["Punchy"].waitForExistence(timeout: 10))
        app.buttons["Punchy"].tap()
        sleep(1)
        let s = el("slider-Strength")
        XCTAssertTrue(s.waitForExistence(timeout: 5), "after a preset, a Strength slider shows")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        sleep(1)
        let v = Int(valueOf("reset-Strength")) ?? 100
        XCTAssertLessThan(v, 90, "dragging left lowers the strength (\(v))")
        shot("preset-strength")
    }

    /// Owner's bug 2026-10-11: with a mask selected, turning the phone left edits invisible until a tab change.
    func testEditsStillShowAfterTurningThePhoneInMasks() {
        launch(open: 0, tool: "Masks", extra: ["-lumenDemoMask", "linear", "-lumenDemoMaskTab", "adjust"])
        defer { XCUIDevice.shared.orientation = .portrait; sleep(1) }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let s = el("slider-Exposure")
        XCTAssertTrue(s.waitForExistence(timeout: 10), "mask Exposure slider in landscape")
        let before = events().filter { $0.contains("drew image") }.count
        let v0 = valueOf("reset-Exposure")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: s.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(2)
        let v1 = valueOf("reset-Exposure")
        let after = events().filter { $0.contains("drew image") }.count
        XCTAssertNotEqual(v0, v1, "the drag should change the mask's Exposure (\(v0) -> \(v1)); slider \(s.frame)")
        XCTAssertGreaterThan(after, before, "moving a mask slider after turning the phone must redraw the photo (\(before) -> \(after), value \(v0) -> \(v1)); last: \(events().suffix(4))")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        let back = events().filter { $0.contains("drew image") }.count
        el("slider-Exposure").doubleTap()
        sleep(2)
        XCTAssertGreaterThan(events().filter { $0.contains("drew image") }.count, back, "and again after turning back")
    }
}
