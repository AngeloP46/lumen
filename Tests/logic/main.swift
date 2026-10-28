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
do {
    for level: Float in [-7, -2, 0, 2, 7] {
        let flat = [Float](repeating: level, count: 96 * 64)
        let band = BilateralClarity.residual(flat, width: 96, height: 64, spatialSigma: 8)
        check(band.count == flat.count && band.allSatisfy { $0.isFinite && abs($0) < 0.0001 },
              "bilateral clarity: a constant field gains contrast at \(level) EV")
    }
    var scene = [Float](repeating: 0, count: 192 * 64)
    for y in 0..<64 { for x in 0..<192 {
        let cell = x % 48
        scene[y * 192 + x] = cell < 4 ? -3 : cell < 8 ? 2 : 0.35 * sin(2 * .pi * Float(x) / 32)
    } }
    let band = BilateralClarity.residual(scene, width: 192, height: 64, spatialSigma: 12)
    let surfaces = (16..<176).filter { (16..<40).contains($0 % 48) }
    let response = surfaces.map { abs(band[32 * 192 + $0]) }.reduce(0, +) / Float(surfaces.count)
    check(response > 0.05, "bilateral clarity: nearby edges suppress the surface detail band")
    check(band.allSatisfy { $0.isFinite }, "bilateral clarity: invalid detail values")
}
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

// Every recipe uses one engine. Migrating metadata must preserve adjustment values, masks and pixel-file references.
do {
    check(EditSettings().processingVersion == EditSettings.currentProcessing, "processing: new recipes use the current engine")
    var old = encoded(rich)
    old["processingVersion"] = nil
    old["formatVersion"] = 1
    let loaded = EditsFile.load(data(old)), migrated = loaded.settings
    check(migrated == rich && loaded.report.engineMigrated, "processing: migrating old edits changes values or misses backup requirement")
    check(migrated.heals == rich.heals && migrated.aiDenoise == rich.aiDenoise && migrated.lensBlur == rich.lensBlur,
          "processing: migration must retain Heal, AI Denoise and Lens Blur references")
    old["vignetteMidpoint"] = nil
    let tolerant = EditsFile.decodeSettings(data(old))
    check(tolerant == rich, "processing: tolerant migration must preserve old adjustments on the current engine")
    check(tolerant.cropVersion == rich.cropVersion, "processing: tolerant migration must retain an explicit crop coordinate version")
    old["cropVersion"] = nil
    check(EditsFile.decodeSettings(data(old)).cropVersion == nil, "processing: a missing old crop version must remain absent")
    check(EditsFile.decodeSettings(data(encoded(migrated))) == rich, "processing: migrated edits fail a save/load round trip")
    for version in [-1, 0, 1, 2, 99] {
        var obj = encoded(rich); obj["processingVersion"] = version
        let decoded = try? JSONDecoder().decode(EditSettings.self, from: data(obj))
        check(decoded?.processingVersion == EditSettings.currentProcessing && decoded?.exposure == rich.exposure,
              "processing: compatibility version \(version) selects another engine or loses values")
    }
    var presetSettings = encoded(rich); presetSettings["processingVersion"] = 1; presetSettings["formatVersion"] = 1
    let presetObject: [String: Any] = ["id": UUID().uuidString, "name": "Older look", "settings": presetSettings]
    let presets = try? JSONDecoder().decode([UserPreset].self, from: data([presetObject]))
    check(presets?.first?.settings == rich, "processing: an old user preset fails to migrate without changing its values")
    var target = EditSettings(); target.exposure = -2; target.grading.highlights.sat = 15
    var selection = CopySelection(); selection.set(.light, true)
    let pasted = Clipboard(settings: migrated, selection: selection, sourceName: "Old edits").pasted(onto: target)
    check(pasted.exposure == rich.exposure && pasted.grading == target.grading && pasted.processingVersion == EditSettings.currentProcessing,
          "processing: partial paste must use the current engine while preserving unselected values")
    check(EditSettings.blend(target, migrated, 0) == target && EditSettings.blend(target, migrated, 1).processingVersion == EditSettings.currentProcessing,
          "processing: preset Strength endpoints must retain their values on one engine")
    check(EditSettings.currentFormat > 2, "processing: earlier two-engine apps need a newer-format rollback warning")
}

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

// An interrupted thumbnail upgrade keeps each completed photo, preserves old display JPEGs, and only resumes
// unfinished work. No whole-library completion flag is required.
do {
    let directory = tmp.appendingPathComponent("thumbnail-resume")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ids = [UUID(), UUID(), UUID()]
    for id in ids { try? Data([1]).write(to: ThumbnailFiles.legacy(in: directory, id: id)) }
    for id in ids.prefix(2) { try? Data([2]).write(to: ThumbnailFiles.current(in: directory, id: id), options: .atomic) }
    let afterRestart = ids.filter { ThumbnailFiles.needsRefresh(in: directory, id: $0) }
    check(afterRestart == [ids[2]], "thumbnails: restart discards completed migration progress")
    check(ids.allSatisfy { FileManager.default.fileExists(atPath: ThumbnailFiles.legacy(in: directory, id: $0).path) },
          "thumbnails: migration removes old display images before successful replacements")
    check(ThumbnailFiles.current(in: directory, id: ids[0]) != ThumbnailFiles.legacy(in: directory, id: ids[0]),
          "thumbnails: old and new engine cache files collide")
    check(HeavyWork.needMB(.thumbnail, megapixels: 48) > HeavyWork.needMB(.thumbnail, megapixels: 24),
          "thumbnails: RAW decode memory estimate ignores source size")
}

// Before the first overwrite, retain the exact old bytes once. A blocked backup must also block that write.
do {
    var old = encoded(rich); old["processingVersion"] = 1; old["formatVersion"] = 2
    let oldHistory: [String: Any] = ["current": old, "undo": [old], "redo": [old]]
    let oldPresets: [[String: Any]] = [["id": UUID().uuidString, "name": "Saved", "settings": old]]
    for (name, original) in [("old.json", data(old)), ("old.history.json", data(oldHistory)), ("presets.json", data(oldPresets))] {
        let url = tmp.appendingPathComponent(name), backup = EditsFile.engineBackupURL(for: tmp.appendingPathComponent(name))
        do {
            try original.write(to: url)
            try EditsFile.preserveBeforeEngineMigration(file: url)
            check((try? Data(contentsOf: backup)) == original, "migration backup: \(name) lost the original bytes")
            // A later old-format save must not replace the first recovery copy.
            let different = data(["exposure": 2, "formatVersion": 1])
            try different.write(to: url)
            try EditsFile.preserveBeforeEngineMigration(file: url)
            check((try? Data(contentsOf: backup)) == original, "migration backup: \(name) overwrote its first copy")
        } catch { check(false, "migration backup: \(name) failed (\(error))") }
    }
    let url = tmp.appendingPathComponent("blocked.json"), original = data(old)
    try? original.write(to: url)
    try? FileManager.default.createDirectory(at: EditsFile.engineBackupURL(for: url), withIntermediateDirectories: true)
    var refused = false
    do {
        try EditsFile.preserveBeforeEngineMigration(file: url)
        try data(encoded(rich)).write(to: url, options: .atomic)
    } catch { refused = true }
    check(refused && (try? Data(contentsOf: url)) == original, "migration backup: failure must leave the source recipe untouched")
    let history = EditsFile.history(data(oldHistory))
    check(history?.current == rich && history?.undo == [rich] && history?.redo == [rich],
          "processing: history migration must preserve all undo/redo values and normalize metadata")
    check(!EditsFile.needsEngineMigration(data(encoded(rich))), "migration backup: current recipes should not need another backup")
}
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
    final class Probe {}
    weak var observed: Probe?
    let model = LoadedModel<Probe> { let value = Probe(); observed = value; return value }
    for _ in 0..<32 {
        do {
            let active = model.model
            model.release()
            check(observed != nil, "model release: an active caller lost its model")
            withExtendedLifetime(active) {}
        }
        check(observed == nil, "model release: last-load hand-off retains a released model after callers finish")
    }
}
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

// ---- A23 (23 Oct): one decode at a time, only the newest settings; the Heal model's load waits for room
do {
    var f = SingleFlight()
    check(f.request(), "single flight: the first request starts at once")
    check(!f.request() && !f.request() && !f.request(), "single flight: requests during a run do not start more runs")
    check(f.finish() && f.running, "single flight: after the run, one more for all the requests that came in")
    check(!f.finish() && !f.running, "single flight: and then it is idle")
    check(f.request(), "single flight: the next request starts at once again")
    check(!f.finish() && !f.running, "single flight: nothing came in, nothing more to run")

    HeavyWork.availableMB = { 0 }
    var decoded = false
    check(HeavyWork.shared.run(.preview, megapixels: 24) { () -> Int in decoded = true; return 1 } == 1 && decoded,
          "coordinator: with no memory report (the simulator) a preview decode runs at once")
    HeavyWork.availableMB = { 1000 }
    var thumbRendered = false
    check(HeavyWork.shared.run(.thumbnail, megapixels: 24, optional: true) { thumbRendered = true; return 1 } == nil && !thumbRendered,
          "thumbnails: a RAW rebuild starts without its memory reserve")
    HeavyWork.availableMB = { 2400 }
    check(HeavyWork.shared.run(.thumbnail, megapixels: 24, optional: true) { thumbRendered = true; return 1 } == 1 && thumbRendered,
          "thumbnails: a rebuild with room and a reserve is refused")
    HeavyWork.availableMB = { 1000 }
    var loaded = false
    check(HeavyWork.shared.run(.healModel, megapixels: 0, optional: true) { () -> Int in loaded = true; return 1 } == nil && !loaded,
          "coordinator: the Heal model is not loaded with 1000 MB free")
    HeavyWork.availableMB = { 2764 }
    check(HeavyWork.shared.run(.healModel, megapixels: 0, optional: true) { () -> Int in loaded = true; return 1 } == 1 && loaded,
          "coordinator: the Heal model loads with 2764 MB free (0.1.608 refused three heals there)")
    HeavyWork.availableMB = { 10000 }
    check(HeavyWork.shared.run(.preview, megapixels: 24, optional: true) {
        HeavyWork.shared.run(.thumbnail, megapixels: 24, optional: true) { 1 } == nil
    } == true, "thumbnails: rebuild overlaps an active editor decode before its allocations are visible")
    check(HeavyWork.shared.run(.thumbnail, megapixels: 24, optional: true) {
        HeavyWork.shared.run(.preview, megapixels: 24, optional: true) { 1 } == nil
    } == true, "thumbnails: editor decode overlaps a RAW thumbnail before its allocations are visible")
}

// ---- B4 / B2 (23 Oct): long brush strokes keep their shape with far fewer points; heavy work waits for the screen
do {
    // a straight stroke of 400 points is two; a curve keeps the points that bend it
    let line = BrushStroke(points: (0..<400).map { Pt(x: Double($0) / 400, y: 0.5) }, size: 0.05, erase: false, feather: 30)
    let simple = line.simplified()
    check(simple.points.count == 2, "stroke: a straight line needs only its two ends (\(simple.points.count))")
    check(simple.size == 0.05 && simple.erase == false && simple.feather == 30, "stroke: size, erase and feather are kept")
    let arc = BrushStroke(points: (0..<500).map { i in let t = Double(i) / 499 * Double.pi; return Pt(x: 0.5 - 0.4 * cos(t), y: 0.5 - 0.4 * sin(t)) },
                          size: 0.03, erase: true, feather: nil)
    let reduced = arc.simplified()
    check(reduced.points.count < 120 && reduced.points.count > 10, "stroke: an arc of 500 points keeps its shape in far fewer (\(reduced.points.count))")
    check(reduced.points.first == arc.points.first && reduced.points.last == arc.points.last, "stroke: both ends stay")
    // no point of the original is farther from the reduced stroke than epsilon
    func distance(_ p: Pt, _ a: Pt, _ b: Pt) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
    var worst = 0.0
    for p in arc.points {
        var best = Double.infinity
        for i in 0..<(reduced.points.count - 1) { best = min(best, distance(p, reduced.points[i], reduced.points[i + 1])) }
        worst = max(worst, best)
    }
    check(worst <= 0.0006 + 1e-9, "stroke: the shape stays within epsilon of the original (\(worst))")
    let noisy = BrushStroke(points: (0..<2000).map { i in Pt(x: Double(i % 50) / 50, y: Double((i * 7) % 50) / 50) }, size: 0.03, erase: false, feather: nil)
    check(noisy.simplified(limit: 300).points.count <= 300, "stroke: never more than the limit")
    let few = BrushStroke(points: [Pt(x: 0.1, y: 0.1), Pt(x: 0.2, y: 0.3)], size: 0.03, erase: false, feather: nil)
    check(few.simplified() == few, "stroke: two points stay as they are")

    // heavy work waits while Lumen is in the background
    HeavyWork.availableMB = { 3300 }
    HeavyWork.isForeground = false
    let started = Date()
    var startedAt: Date?
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = HeavyWork.shared.run(.export, megapixels: 12) { () -> Int in startedAt = Date(); return 1 }
        finished.signal()
    }
    usleep(700_000)
    check(startedAt == nil, "background: an export does not start while Lumen is in the background")
    HeavyWork.isForeground = true
    check(finished.wait(timeout: .now() + 3) == .success, "background: and starts when Lumen is back on screen")
    check((startedAt?.timeIntervalSince(started) ?? 0) >= 0.6, "background: it waited for the screen")
}

// ---- careful mode (23 Oct): two memory closures within a day
do {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let h = 3600.0
    check(!CarefulMode.active(closures: [], now: now), "careful: not without closures")
    check(!CarefulMode.active(closures: [now.addingTimeInterval(-h)], now: now), "careful: one closure is not enough")
    check(CarefulMode.active(closures: [now.addingTimeInterval(-h), now.addingTimeInterval(-2 * h)], now: now), "careful: two within a day")
    check(!CarefulMode.active(closures: [now.addingTimeInterval(-h), now.addingTimeInterval(-25 * h)], now: now), "careful: a closure older than a day does not count")
    check(!CarefulMode.active(closures: [now.addingTimeInterval(-23 * h), now.addingTimeInterval(-25 * h)], now: now), "careful: back to normal once the older one is a day old")
    check(CarefulMode.pruned([now.addingTimeInterval(-30 * h), now.addingTimeInterval(-h)], now: now).count == 1, "careful: old closures are forgotten")
    check(CarefulMode.pruned((0..<50).map { now.addingTimeInterval(-Double($0)) }, now: now).count == 20, "careful: the list never grows past 20")
}

// ---- Brightness (owner, 25 Oct): older edits and masks read 0 straight away, and it belongs to Light everywhere
do {
    var old = encoded(EditSettings()); old["brightness"] = nil
    let o = EditsFile.load(data(old))
    check(o.settings.brightness == 0 && !o.report.migrated, "brightness: an older file reads 0, without the slow path (migrated \(o.report.migrated))")
    var b = EditSettings(); b.brightness = 30
    var c = EditSettings(); c.take(.light, from: b)
    check(c.brightness == 30, "brightness: copying Light takes it")
    check(c.hasEdits(.light), "brightness: counts as a Light edit (tool bar dot, Edits sheet)")
    c.reset(.light)
    check(c.brightness == 0, "brightness: Light's Reset clears it")
    check(b.historyLabel(from: EditSettings()) == "Brightness +30", "brightness: History names it (\(b.historyLabel(from: EditSettings())))")
    var off = b; off.setOn(.light, false)
    check(off.effective.brightness == 0 && off.brightness == 30, "brightness: switching Light off keeps it but stops it applying")
    check(EditSettings.blend(EditSettings(), b, 0.5).brightness == 15, "brightness: preset Strength mixes it")
    var la = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalAdjust()))) as? [String: Any] ?? [:]
    la["brightness"] = nil
    let back = try? JSONDecoder().decode(LocalAdjust.self, from: data(la))
    check(back?.brightness == 0 && back?.isNeutral == true, "brightness: an older mask's adjustments read 0")
}

// ---- the slider's neutral detent (owner, 25 Oct: "the smallest value I can select is 3, any less and it reverts to 0")
do {
    // from 0 the very next values can be chosen (before: anything within 2.4 of 0 snapped back to it)
    var a = DetentDrag(value: 0, neutral: 0, range: -100...100)
    a.move(points: 1, perPoint: 0.6)
    check(abs(a.value - 0.6) < 1e-9, "detent: leaving 0 moves at once, so 1 can be chosen (\(a.value))")
    var e = DetentDrag(value: 0, neutral: 0, range: -5...5)
    e.move(points: 2, perPoint: 0.03)
    check(abs(e.value - 0.06) < 1e-9, "detent: Exposure can be nudged by hundredths (before: nothing within 0.12 EV) (\(e.value))")
    // coming back through 0 rests there for a stretch of finger travel, then carries on
    var b = DetentDrag(value: 5, neutral: 0, range: -100...100)
    b.move(points: -10, perPoint: 0.6)
    check(b.value == 0, "detent: passing through 0 rests there (\(b.value))")
    b.move(points: -8, perPoint: 0.6)
    check(b.value == 0, "detent: still resting within the hold (\(b.value))")
    b.move(points: -6, perPoint: 0.6)
    check(abs(b.value + 1.2) < 1e-9, "detent: then carries on past 0 (\(b.value))")
    // the ends: pushed past, then back, it moves at once
    var c = DetentDrag(value: 95, neutral: 0, range: -100...100)
    c.move(points: 50, perPoint: 0.6)
    check(c.value == 100, "detent: stops at the end (\(c.value))")
    c.move(points: -5, perPoint: 0.6)
    check(abs(c.value - 97) < 1e-9, "detent: back from the end at once (\(c.value))")
    // neutral at the low end (Grain): resting at 0, pushing on stays at 0, back up moves at once
    var g = DetentDrag(value: 10, neutral: 0, range: 0...100)
    g.move(points: -30, perPoint: 0.6)
    g.move(points: -40, perPoint: 0.6)
    check(g.value == 0, "detent: an end at neutral holds (\(g.value))")
    g.move(points: 5, perPoint: 0.6)
    check(abs(g.value - 3) < 1e-9, "detent: and moves again at once (\(g.value))")
}

// ---- end stops (owner, 25 Oct: past a limit and back, the control seemed to forget where 0 was)
do {
    var base = 140.0
    let range = 50.0...150.0
    let atEnd = EndStop.value(base: &base, delta: 40, in: range)          // pushed 30 past the end
    check(atEnd == 150, "end stop: a drag past the end stops at it (\(atEnd))")
    let back = EndStop.value(base: &base, delta: 35, in: range)           // the finger comes back 5
    check(abs(back - 145) < 1e-9, "end stop: coming back responds at once, not after undoing the overshoot (\(back))")
    var b2 = 0.0
    let free = EndStop.value(base: &b2, delta: 12, in: -45...45)
    check(free == 12 && b2 == 0, "end stop: inside the range the drag is unchanged")
}

// ---- crop frame moves (pinch and drag of the photo under the frame), 25 Oct
do {
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    let full = CropRect.full
    // back to 1x: the biggest frame of the same shape, centred
    let f1 = CropMath.fullShape(CropRect(l: 0.6, t: 0.1, r: 0.8, b: 0.2))      // 2:1 in fractions
    check(near(f1.w, 1) && near(f1.h, 0.5) && near(f1.t, 0.25) && near(f1.l, 0), "crop 1x: a wide frame fills the width, centred \(f1)")
    let f2 = CropMath.fullShape(CropRect(l: 0.2, t: 0.2, r: 0.3, b: 0.6))      // tall
    check(near(f2.h, 1) && near(f2.w, 0.25) && near(f2.l, 0.375), "crop 1x: a tall frame fills the height, centred \(f2)")
    // dragging the photo moves the frame the other way and keeps its size; it stops at the picture's edge
    let half = CropRect(l: 0.25, t: 0.25, r: 0.75, b: 0.75)
    let p1 = CropMath.panned(half, dx: 0.1, dy: -0.05)
    check(near(p1.l, 0.35) && near(p1.r, 0.85) && near(p1.t, 0.2) && near(p1.b, 0.7), "crop pan: moved by the drag \(p1)")
    let p2 = CropMath.panned(half, dx: 0.9, dy: 0.9)
    check(near(p2.r, 1) && near(p2.b, 1) && near(p2.w, 0.5) && near(p2.h, 0.5), "crop pan: stops at the edge and keeps its size \(p2)")
    // zooming in 2x about the middle halves the frame, centred
    let z1 = CropMath.zoomed(full, factor: 2, anchor: (0.5, 0.5), rel: (0.5, 0.5))
    check(near(z1.l, 0.25) && near(z1.r, 0.75) && near(z1.t, 0.25) && near(z1.b, 0.75), "crop zoom: 2x about the middle \(z1)")
    // the point under the fingers stays at the same place in the frame
    let z2 = CropMath.zoomed(full, factor: 4, anchor: (0.8, 0.3), rel: (0.8, 0.3))
    check(near(z2.l + 0.8 * z2.w, 0.8) && near(z2.t + 0.3 * z2.h, 0.3) && near(z2.w, 0.25), "crop zoom: the held point stays put \(z2)")
    // zooming out cannot go past the whole picture, and keeps the shape of a 3:2 frame
    let wide = CropRect(l: 0, t: 0.1667, r: 1, b: 0.8333)
    let z3 = CropMath.zoomed(wide, factor: 0.5, anchor: (0.5, 0.5), rel: (0.5, 0.5))
    check(near(z3.w, 1) && near(z3.h / z3.w, wide.h / wide.w) && z3.l >= 0 && z3.r <= 1 && z3.t >= 0 && z3.b <= 1, "crop zoom: out stops at the picture, same shape \(z3)")
    // zooming in cannot go below the smallest frame
    let z4 = CropMath.zoomed(half, factor: 100, anchor: (0.5, 0.5), rel: (0.5, 0.5))
    check(z4.w >= CropMath.minSide - 1e-9 && z4.h >= CropMath.minSide - 1e-9, "crop zoom: stops at the smallest frame \(z4)")
    // moving the fingers moves the photo with them: the held point ends up further along in the frame
    let z5 = CropMath.zoomed(half, factor: 1, anchor: (0.5, 0.5), rel: (0.6, 0.5))
    check(z5.l < half.l && near(z5.w, half.w), "crop zoom: dragging the held point right moves the frame left \(z5)")
}

// ---- the crop kept on real photo (crop rework part 2), 25 Oct
do {
    func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) < e }
    // no straighten, no transform: the whole frame is photo
    let plain = CropFit.region(source: (3, 2), turns: 0, flipH: false, flipV: false, straighten: 0, warp: nil)
    check(CropFit.contains(plain, .full), "crop fit: an untouched photo is all photo")
    check(CropFit.fit(.full, in: plain) == .full, "crop fit: nothing to fit without straighten or perspective")
    // straighten 5 degrees on 3:2: the whole frame is the largest same-shaped centred rectangle (the old kfit)
    let tilted = CropFit.region(source: (3, 2), turns: 0, flipH: false, flipV: false, straighten: 5, warp: nil)
    let th = 5 * Double.pi / 180, kfit = 1 / (cos(th) + sin(th) * 1.5)
    let f = CropFit.fit(.full, in: tilted)
    check(near(f.w, kfit, 1e-5) && near(f.h, kfit, 1e-5) && near((f.l + f.r) / 2, 0.5, 1e-5) && near((f.t + f.b) / 2, 0.5, 1e-5),
          "crop fit: straighten keeps the same shape, centred, as big as fits (\(f), kfit \(kfit))")
    check(CropFit.contains(tilted, f, tolerance: 1e-6), "crop fit: the fitted frame is all photo")
    // a wide free crop can reach further than the centred same-shaped rectangle (the photo's corners are still photo)
    let wide = CropRect(l: 0, t: 0.35, r: 1, b: 0.65)
    let fw = CropFit.fit(wide, in: tilted)
    check(fw.w > kfit + 0.02 && CropFit.contains(tilted, fw, tolerance: 1e-6), "crop fit: a wide crop keeps more width (\(fw.w) vs \(kfit))")
    // a crop off to one side slides back onto the photo before it shrinks
    let side = CropRect(l: 0.6, t: 0.3, r: 1.0, b: 0.7)
    let fs = CropFit.fit(side, in: tilted)
    check(near(fs.w, side.w, 1e-6) && fs.r < 1 && CropFit.contains(tilted, fs, tolerance: 1e-6), "crop fit: slides before shrinking (\(fs))")
    // a lopsided perspective: the frame moves off-centre to keep more photo than zooming about the middle would
    let quad: [CropFit.P] = [(0.1, 0), (1, 0), (1, 1), (0.1, 1)]
    let shifted = CropFit.region(source: (3, 2), turns: 0, flipH: false, flipV: false, straighten: 0, warp: quad)
    let fq = CropFit.fit(.full, in: shifted)
    check(near(fq.w, 0.9, 1e-4) || fq.w > 0.89, "crop fit: a frame cut on one side keeps 90 % of the width (\(fq))")
    // a drag stops at the photo's edge, on the way to where the finger went
    let start = CropFit.fit(.full, in: tilted)
    let stop = CropFit.limit(from: start, to: CropRect(l: start.l - 0.3, t: start.t, r: start.r, b: start.b), in: tilted)
    check(CropFit.contains(tilted, stop, tolerance: 1e-6) && stop.l <= start.l && stop.l > start.l - 0.3, "crop fit: a handle stops at the edge (\(stop))")
    // turns: a quarter turn swaps the frame; flips mirror the region
    let turned = CropFit.region(source: (3, 2), turns: 1, flipH: false, flipV: false, straighten: 4, warp: nil)
    check(CropFit.contains(turned, CropFit.fit(.full, in: turned), tolerance: 1e-6), "crop fit: works on a turned photo")
    // older edits: converted so the same part stays framed
    let old = CropRect(l: 0.1, t: 0.2, r: 0.9, b: 0.8)
    let up = CropFit.upgraded(old, frame: (3, 2), straighten: 5, fillZoom: 1)
    check(near(up.w, 0.8 * kfit) && near((up.l + up.r) / 2, 0.5) && CropFit.contains(tilted, up, tolerance: 1e-6),
          "crop fit: an older straightened crop maps inside the photo, same place (\(up))")
    check(CropFit.upgraded(old, frame: (3, 2), straighten: 0, fillZoom: 1) == old, "crop fit: nothing changes for an older crop without straighten")
}

runThumbnailWorkChecks()
print("logic tests: \(failures == 0 ? "PASS" : "FAIL"), \(failures) failure(s), \(knowns) known open bug(s) reproduced")
exit(failures == 0 ? 0 : 1)
