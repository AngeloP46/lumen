import Foundation

// Fast logic tests (quality checklist, batch 0): the rules that lose work if they break, run on Linux in seconds on
// every push. Built from the app's own Foundation-only files (EditSettings, Curves, EditsFile), so they test the real
// code, not a copy. `check` fails the run; `known` records a bug listed in docs/QUALITY-CHECKLIST.md that is still
// open (it prints KNOWN and passes, and turns into a `check` in the batch that fixes it).

var failures = 0, knowns = 0
func check(_ ok: Bool, _ message: String) {
    if !ok { failures += 1; print("FAIL: \(message)") }
}
func known(_ reproduces: Bool, _ id: String, _ message: String) {
    if reproduces { knowns += 1; print("KNOWN \(id): \(message)") } else { print("NOTE \(id) no longer reproduces: \(message)") }
}
func json(_ s: String) -> Data { Data(s.utf8) }
func encoded(_ s: EditSettings) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s))) as? [String: Any] ?? [:]
}
func data(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }

// ---- Edits files: today's format round-trips exactly
var rich = EditSettings()
rich.exposure = 0.7; rich.contrast = 15; rich.highlights = -40; rich.temperature = 12; rich.aiDenoise = 60; rich.hdr = true
rich.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.3), CurvePoint(x: 1, y: 1)]
rich.hsl.bands[2].hue = 15; rich.grading.shadows = GradeZone(hue: 220, sat: 30, lum: -5)
var mask = Mask.make(.sky)
mask.adjust.exposure = -0.5
var brush = MaskComponent.make(.brush, op: .subtract)
brush.strokes = [BrushStroke(points: [Pt(x: 0.1, y: 0.2), Pt(x: 0.3, y: 0.4)], size: 0.05, erase: false, feather: 30)]
mask.components.append(brush)
var subject = MaskComponent.make(.subject)
subject.subjectPoint = Pt(x: 0.4, y: 0.6)
mask.components.append(subject)
rich.masks = [mask]
rich.heals = [HealSpot(strokes: [], x: 0.1, y: 0.1, w: 0.2, h: 0.2, scale: 1.2)]
rich.lensBlur.amount = 40; rich.lensBlur.maskID = mask.id; rich.lensBlur.activated = true
for (name, s) in [("default", EditSettings()), ("rich", rich)] {
    let back = EditsFile.decodeSettings((try? JSONEncoder().encode(s)) ?? Data())
    check(back == s, "edits file: \(name) settings changed after save and load")
}

// ---- Older edits files: missing keys take today's defaults, saved values are kept
do {
    var old = encoded(rich)
    for k in ["aiDenoise", "flipH", "tFill", "heals", "disabled", "vignetteMidpoint"] { old[k] = nil }
    old["someRemovedSlider"] = 7
    let s = EditsFile.decodeSettings(data(old))
    check(s.exposure == 0.7 && s.highlights == -40 && s.masks.count == 1, "edits file: an older file lost saved values")
    check(s.aiDenoise == 0 && s.flipH == false && s.tFill == true && s.heals.isEmpty, "edits file: missing keys didn't take defaults")
    check(s.vignetteMidpoint == 50, "edits file: a missing plain key didn't take its default (\(s.vignetteMidpoint))")
}
// a mask part written before a key existed (part opacity, tapped subject)
do {
    var old = encoded(rich)
    var masks = old["masks"] as? [[String: Any]] ?? []
    var comps = masks.first?["components"] as? [[String: Any]] ?? []
    for i in comps.indices { comps[i]["amount"] = nil; comps[i]["scene"] = nil }
    masks[0]["components"] = comps
    old["masks"] = masks
    let s = EditsFile.decodeSettings(data(old))
    check(s.masks.count == 1 && s.masks[0].components.count == 3, "edits file: masks from before part opacity were dropped")
    check(s.masks.first?.components.allSatisfy { $0.amount == 100 } == true, "edits file: missing part opacity didn't default to 100")
    check(s.masks.first?.components.last?.subjectPoint == Pt(x: 0.4, y: 0.6), "edits file: a tapped subject point was lost in migration")
}
// Lens Blur saved on the old, stronger amount scale (before 15 Oct): old 35 = new 100
do {
    var old = encoded(EditSettings())
    old["lensBlur"] = ["amount": 14.0, "focusDistance": 0.4, "focusWidth": 0.1]
    let s = EditsFile.decodeSettings(data(old))
    check(abs(s.lensBlur.amount - 40) < 0.001, "edits file: old Lens Blur amount 14 should read as 40, got \(s.lensBlur.amount)")
    check(s.lensBlur.activated, "edits file: an old saved Lens Blur should count as a user choice")
}
check(EditsFile.decodeSettings(json("not json")) == EditSettings(), "edits file: garbage should give defaults, not crash")

// A1 (open): a mask kind this version doesn't know (a file from a newer version, read after a rollback)
do {
    var old = encoded(rich)
    var masks = old["masks"] as? [[String: Any]] ?? []
    var comps = masks[0]["components"] as? [[String: Any]] ?? []
    comps[0]["kind"] = "futureKind"
    masks[0]["components"] = comps
    old["masks"] = masks
    let (s, report) = EditsFile.load(data(old))
    // fixed in batch 1: only the part that can't be read goes; the rest of the mask and every other mask stay
    check(s.masks.count == 1 && s.masks[0].components.count == 2, "A1: an unknown mask part must drop only itself (masks \(s.masks.count), parts \(s.masks.first?.components.count ?? 0))")
    check(report.droppedMasks == 1 && report.lostSomething && report.message != nil, "A1: the loss must be reported (\(report))")
    check(s.exposure == 0.7, "edits file: an unknown mask kind must not lose the global edits")
}

// ---- Undo history files
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-logic-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
do {
    var a = EditSettings(); a.exposure = 1
    let h = EditsFile.History(current: a, undo: [EditSettings()], redo: [])
    let url = tmp.appendingPathComponent("h.history.json")
    try? JSONEncoder().encode(h).write(to: url)
    let back = EditsFile.readHistory(file: url, legacy: nil)
    check(back?.current == a && back?.undo == [EditSettings()], "history: today's file didn't read back")
    // 0.1.197–0.1.210 kept history inside the edits file
    var side = encoded(a)
    side["_undoHistory"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(h))) ?? [:]
    let legacy = EditsFile.readHistory(file: tmp.appendingPathComponent("missing.json"), legacy: data(side))
    check(legacy?.undo.count == 1, "history: history kept inside an older edits file wasn't read")
    // A1 (open): a history step from before a key existed
    var obj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(EditsFile.History(current: rich, undo: [rich], redo: [])))) as? [String: Any] ?? [:]
    var undo = obj["undo"] as? [[String: Any]] ?? []
    undo[0]["aiDenoise"] = nil
    var masks = undo[0]["masks"] as? [[String: Any]] ?? []
    var comps = masks[0]["components"] as? [[String: Any]] ?? []
    comps[0]["amount"] = nil
    masks[0]["components"] = comps
    undo[0]["masks"] = masks
    obj["undo"] = undo
    let oldURL = tmp.appendingPathComponent("old.history.json")
    try? data(obj).write(to: oldURL)
    let read = EditsFile.readHistory(file: oldURL, legacy: nil)
    check(read?.undo.count == 1 && read?.undo.first?.aiDenoise == 0 && read?.undo.first?.masks.first?.components.first?.amount == 100,
          "A1: a history step from before a key existed must still load (got \(read?.undo.count ?? -1) steps)")
}

// ---- What loading reports (A1): nothing lost / older file / newer version / damaged
do {
    let today = EditsFile.load((try? JSONEncoder().encode(rich)) ?? Data())
    check(!today.report.lostSomething && today.report.message == nil, "load report: today's file must report nothing lost")
    var older = encoded(rich); older["aiDenoise"] = nil; older["formatVersion"] = nil
    let o = EditsFile.load(data(older))
    check(!o.report.lostSomething, "load report: an older file with fewer keys loses nothing (\(o.report))")
    var newer = encoded(rich); newer["formatVersion"] = EditSettings.currentFormat + 1; newer["someFutureSetting"] = 3
    let n = EditsFile.load(data(newer))
    check(n.report.newerVersion && n.report.lostSomething && n.settings.exposure == 0.7, "load report: a newer file must be flagged and still read (\(n.report))")
    check(n.settings.formatVersion == EditSettings.currentFormat, "load report: edits read from a newer file are saved back in this version's format (\(n.settings.formatVersion))")
    let again = EditsFile.load((try? JSONEncoder().encode(n.settings)) ?? Data())
    check(!again.report.newerVersion && !again.report.lostSomething, "load report: a file this version saved must not read as newer again (\(again.report))")
    let bad = EditsFile.load(json("{ not json"))
    check(bad.report.unreadable && bad.report.message != nil, "load report: a damaged file must be flagged")
    var wrongType = encoded(rich); wrongType["exposure"] = "bright"
    let w = EditsFile.load(data(wrongType))
    check(w.report.droppedSettings == ["exposure"] && w.settings.highlights == -40 && w.settings.masks.count == 1,
          "load report: one unreadable setting must drop only itself (\(w.report))")
    check(EditSettings().formatVersion == EditSettings.currentFormat, "edits file: new edits are written in today's format")
}

// ---- History names and pasting masks
do {
    var a = EditSettings(), b = EditSettings()
    b.highlights = 34
    check(b.historyLabel(from: a) == "Highlights +34", "history label: one slider should read \"Highlights +34\", got \"\(b.historyLabel(from: a))\"")
    a.masks = []; b = a; b.masks = [Mask.make(.sky)]
    check(b.historyLabel(from: a) == "Mask added", "history label: adding a mask should read \"Mask added\"")
    check(EditSettings().historyLabel(from: EditSettings()) == "No change", "history label: nothing changed")
    let moved = rich.masks.forAnotherPhoto
    check(moved[0].components.allSatisfy { $0.kind != .subject || $0.subjectPoint == nil },
          "paste masks: a tapped subject point must not go to another photo")
    check(moved[0].components.first { $0.kind == .brush }?.strokes == brush.strokes, "paste masks: brush strokes must stay as painted")
}

// ---- Copy and paste (Lightroom-style: chosen when copying, applied exactly by Paste; checklist A12)
do {
    // the photo copied from: Light + Colour + Crop edited, HDR on, a Sky mask, a tapped Subject mask, its own Lens Blur
    var src = EditSettings()
    src.exposure = 0.5; src.vibrance = 20; src.cropL = 0.1; src.hdr = true; src.aiDenoise = 80
    var sky = Mask.make(.sky); sky.name = "Sky"; sky.adjust.exposure = -0.4
    var subj = Mask.make(.subject); subj.name = "Subject"; subj.components[0].subjectPoint = Pt(x: 0.3, y: 0.3)
    var focus = Mask.make(.depth); focus.name = "Lens Blur background"
    src.masks = [sky, subj, focus]
    src.lensBlur.amount = 50; src.lensBlur.maskID = focus.id; src.lensBlur.activated = true
    src.heals = [HealSpot(strokes: [], x: 0, y: 0, w: 0.1, h: 0.1)]

    // the photo pasted onto: its own Lens Blur, heal, AI Denoise, mask, crop
    var own = EditSettings()
    own.contrast = 30; own.cropR = 0.8; own.aiDenoise = 10
    var ownMask = Mask.make(.brush); ownMask.name = "Brush"
    var ownFocus = Mask.make(.depth); ownFocus.name = "Lens Blur background"
    own.masks = [ownMask, ownFocus]
    own.lensBlur.amount = 30; own.lensBlur.maskID = ownFocus.id; own.lensBlur.activated = true
    own.heals = [HealSpot(strokes: [], x: 0.5, y: 0.5, w: 0.1, h: 0.1)]

    let modified = CopySelection.modified(src)
    check(modified.has(.light) && modified.has(.color), "copy: Modified should tick the edited tools")
    check(!modified.has(.crop), "copy: Modified must leave Crop unticked")
    check(!modified.has(.grade) && !modified.has(.curve), "copy: Modified must leave unedited tools unticked")
    check(!modified.has(.detail), "copy: AI Denoise alone (its own tick) must not make Modified tick Detail")
    check(modified.masks.isEmpty && !modified.aiDenoise, "copy: Modified leaves masks and AI Denoise for you to pick")
    check(src.copyableMasks.map(\.name) == ["Sky", "Subject"], "copy: Lens Blur's own mask must not be offered")

    var sel = modified
    sel.masks = [sky.id, subj.id]
    let clip = Clipboard(settings: src, selection: sel, sourceName: "A")
    let out = clip.pasted(onto: own)
    check(out.exposure == 0.5 && out.vibrance == 20, "paste: ticked tools should come across")
    check(out.contrast == 0, "paste: a ticked tool comes across whole (Light's contrast takes the copy's 0)")
    check(out.cropR == 0.8 && out.cropL == 0, "paste: Crop (not ticked) must stay the photo's own")
    check(out.heals == own.heals, "paste: heals always stay the photo's own")
    check(out.lensBlur == own.lensBlur, "paste: Lens Blur always stays the photo's own")
    check(out.masks.contains { $0.id == ownFocus.id }, "paste: the photo's own Lens Blur mask must stay")
    check(out.masks.contains { $0.id == ownMask.id }, "paste: the photo's own masks stay (pasted masks are added)")
    check(!out.masks.contains { $0.id == focus.id }, "paste: the other photo's Lens Blur mask must not come across")
    check(out.masks.first { $0.id == subj.id }?.components[0].subjectPoint == nil, "paste: a tapped subject becomes this photo's subject")
    check(out.aiDenoise == 10, "paste: AI Denoise stays the photo's own until it is cleaned")
    check(out.hdr == true, "paste: HDR ticked (Modified, source on) comes across")
    let twice = clip.pasted(onto: out)
    check(twice.masks.count == out.masks.count, "paste: pasting the same masks again must not add copies")

    var noHDR = sel; noHDR.hdr = false
    check(Clipboard(settings: src, selection: noHDR, sourceName: "A").pasted(onto: own).hdr == false, "paste: HDR not ticked stays the photo's own")
    var withCrop = sel; withCrop.set(.crop, true)
    check(Clipboard(settings: src, selection: withCrop, sourceName: "A").pasted(onto: own).cropL == 0.1, "paste: Crop ticked comes across")

    check(clip.summary == "Light, Colour, HDR, 2 masks", "copy: summary should read \"Light, Colour, HDR, 2 masks\", got \"\(clip.summary)\"")
    var withDenoise = sel; withDenoise.aiDenoise = true
    let dclip = Clipboard(settings: src, selection: withDenoise, sourceName: "A")
    check(dclip.bringsDenoise && dclip.summary.hasSuffix("AI Denoise"), "copy: AI Denoise ticked shows in the summary")
    check(Clipboard(settings: src, selection: CopySelection(), sourceName: "A").isEmpty, "copy: nothing ticked is empty")
    // pasting back onto the photo it came from leaves its masks as they are (no re-adapting, no reorder)
    let source = UUID()
    var back = sel; back.set(.light, true)
    let selfClip = Clipboard(settings: src, selection: back, sourceName: "A", sourceID: source)
    let ownedBySource = selfClip.pasted(onto: src, samePhoto: true)
    check(ownedBySource.masks == src.masks, "paste: onto the photo it was copied from, its masks must not change")
    check(selfClip.pasted(onto: src, samePhoto: false).masks != src.masks, "paste: onto another photo the masks are adapted (the contrast to the rule above)")
    var oneMask = CopySelection(); oneMask.masks = [sky.id]
    check(Clipboard(settings: src, selection: oneMask, sourceName: "A").summary == "Sky mask", "copy: one mask reads by name")
}

// A9: a model load can take seconds. Releasing from the UI must not wait for it or cache its late result.
do {
    let entered = DispatchSemaphore(value: 0), finishLoad = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let model = LoadedModel<Int> {
        entered.signal()
        _ = finishLoad.wait(timeout: .now() + 3)
        return 42
    }
    DispatchQueue.global().async { _ = model.model; done.signal() }
    check(entered.wait(timeout: .now() + 2) == .success, "model load started")
    // The old lock-around-load implementation blocks release until this watchdog unblocks the loader.
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finishLoad.signal() }
    let start = Date()
    model.release()
    check(Date().timeIntervalSince(start) < 0.25, "release must not wait for an in-flight model load")
    finishLoad.signal()
    check(done.wait(timeout: .now() + 2) == .success, "active model request completes after release")
    finishLoad.signal()
    _ = model.model
    check(entered.wait(timeout: .now() + 0.2) == .success, "model released while loading must not be cached afterwards")
}
do {
    var loads = 0
    let model = LoadedModel<Int> { loads += 1; return loads == 1 ? nil : 7 }
    check(model.model == nil, "failed model load returns nil")
    check(model.model == 7, "a later model request retries a transient load failure")
    check(model.model == 7 && loads == 2, "successful model load is cached")
    model.release()
    check(model.model == 7 && loads == 3, "released model loads again on demand")
}

for brokenMasks in [["unexpected": "object"], "invalid", NSNull()] as [Any] {
    var damaged = encoded(rich)
    damaged["masks"] = brokenMasks
    let loaded = EditsFile.load(data(damaged))
    check(loaded.report.lostSomething && loaded.report.droppedMasks > 0, "malformed mask container must request backup and notice")
    check(loaded.settings.exposure == rich.exposure, "malformed masks must not discard readable exposure")
}

// ---- The 100 % view's copy (checklist A21, 23 Oct): never started without room beside the safety margin, never retried in a loop
do {
    let margin = HeavyWork.marginMB
    // the owner's phone: 24 MP, 2477 MB free, a 4096 px copy started and added ~2150 MB; iOS closed Lumen
    check(DetailCopy.edge(freeMB: 2477, megapixels: 24, native: 6000, highTier: false, marginMB: margin) == 0,
          "100 % copy: 2477 MB free is not enough for a 24 MP photo (needs ~\(DetailCopy.needMB(megapixels: 24)) + \(margin))")
    check(DetailCopy.edge(freeMB: 3100, megapixels: 24, native: 6000, highTier: false, marginMB: margin) == 4096,
          "100 % copy: with room it is 4096 px on a standard phone")
    check(DetailCopy.edge(freeMB: 3100, megapixels: 24, native: 3000, highTier: false, marginMB: margin) == 3000,
          "100 % copy: never bigger than the photo")
    check(DetailCopy.edge(freeMB: 4500, megapixels: 24, native: 6000, highTier: true, marginMB: margin) == 6000,
          "100 % copy: the increased memory limit gets the full-size photo")
    check(DetailCopy.needMB(megapixels: 48) >= 2640 && DetailCopy.needMB(megapixels: 24) >= 2150,
          "100 % copy: the estimate is not below what the phone measured (2150 MB at 24 MP, 2640 MB at 48 MP)")
    check(DetailCopy.edge(freeMB: 3200, megapixels: 48, native: 8064, highTier: false, marginMB: margin) == 0,
          "100 % copy: a 48 MP photo needs more room than 3200 MB free")

    var gate = RetryGate()
    let t0 = Date(timeIntervalSince1970: 1_000)
    check(gate.allows(t0), "retry gate: open to begin with")
    gate.hold(for: 12, from: t0)
    check(!gate.allows(t0.addingTimeInterval(5)) && !gate.allows(t0.addingTimeInterval(11.9)), "retry gate: closed while held")
    check(gate.allows(t0.addingTimeInterval(12.1)), "retry gate: open again after the hold")
    gate.hold(for: 30, from: t0.addingTimeInterval(1))
    gate.hold(for: 2, from: t0.addingTimeInterval(2))
    check(!gate.allows(t0.addingTimeInterval(20)), "retry gate: a short hold never shortens a long one")

    // the job coordinator: an optional job needs its room AND the margin, even when nothing else is running
    HeavyWork.availableMB = { 2477 }
    var ran = false
    let mp24 = 24.0
    check(HeavyWork.shared.run(.fullSizeCopy, megapixels: mp24, optional: true) { () -> Int in ran = true; return 1 } == nil && !ran,
          "coordinator: an optional 100 % copy is skipped with 2477 MB free on a 24 MP photo")
    HeavyWork.availableMB = { 3300 }
    check(HeavyWork.shared.run(.fullSizeCopy, megapixels: mp24, optional: true) { () -> Int in ran = true; return 1 } == 1 && ran,
          "coordinator: an optional 100 % copy runs with room and margin")
}

// ---- A9, the last edge (23 Oct): callers already waiting for a load that a release overtakes share its result
do {
    let entered = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var loads = 0
    var got: [Int?] = []
    let model = LoadedModel<Int> {
        lock.lock(); loads += 1; lock.unlock()
        entered.signal()
        _ = go.wait(timeout: .now() + 3)
        return 5
    }
    let both = DispatchGroup()
    for i in 0..<2 {
        both.enter()
        DispatchQueue.global().async {
            let r = model.model
            lock.lock(); got.append(r); lock.unlock()
            both.leave()
        }
        if i == 0 { _ = entered.wait(timeout: .now() + 2) }   // the first call is the one loading
    }
    usleep(300_000)           // the second call is waiting for it
    model.release()           // memory warning in the middle of the load
    go.signal()
    check(both.wait(timeout: .now() + 3) == .success, "both callers finish")
    check(loads == 1, "a waiter must not start a second load after a release (\(loads) loads)")
    check(got.count == 2 && got.allSatisfy { $0 == 5 }, "both callers get the model (\(got))")
}

print("logic tests: \(failures == 0 ? "PASS" : "FAIL"), \(failures) failure(s), \(knowns) known open bug(s) reproduced")
exit(failures == 0 ? 0 : 1)
