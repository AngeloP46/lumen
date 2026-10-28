import Foundation

func runThumbnailWorkChecks() {
    var queue = ThumbnailWorkQueue()
    let a = UUID(), b = UUID(), c = UUID()
    queue.enqueue(a); queue.enqueue(b); queue.enqueue(c); queue.enqueue(b, priority: true)
    check(queue.pendingCount == 3 && queue.next() == b, "thumbnail queue: visible priority or dedup failed")
    check(queue.next() == nil, "thumbnail queue: more than one render admitted")
    queue.enqueue(b)
    check(queue.pendingCount == 2, "thumbnail queue: active photo duplicated without replacement")
    queue.enqueue(b, replaceActive: true); queue.enqueue(b, replaceActive: true)
    check(queue.pendingCount == 3, "thumbnail queue: active replacement is not deduplicated")
    check(queue.finish(b) == 0 && queue.next() == a, "thumbnail queue: finish changes pending order")
    _ = queue.finish(a); check(queue.next() == c, "thumbnail queue: background ID lost")
    _ = queue.finish(c); check(queue.next() == b, "thumbnail queue: active replacement lost")
    check(queue.finish(b) == 0.15, "thumbnail queue: fourth completed photo does not yield")
    queue.enqueue(a); _ = queue.next()
    check(queue.finish(a, pressure: true) == 2, "thumbnail queue: memory pressure retries in a tight loop")
    queue.enqueue(a); queue.remove(a)
    check(queue.pendingCount == 0 && queue.next() == nil, "thumbnail queue: removed photo stays queued")
    var freshIDs = ThumbnailWorkQueue()
    for id in [a, b, c] { freshIDs.enqueue(id) }
    check(freshIDs.next() == a && freshIDs.pendingCount == 2,
          "thumbnail queue: launch cannot queue IDs before reading per-photo freshness")
    freshIDs.enqueue(c, priority: true); _ = freshIDs.finish(a)
    check(freshIDs.next() == c, "thumbnail queue: visible photo cannot overtake unscanned launch IDs")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-quality-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), other = UUID(), gate = ThumbnailGenerationGate()
        check(!gate.canRender, "thumbnail scheduler: work starts before library is visible")
        gate.setEnabled(true); check(gate.canRender, "thumbnail scheduler: library cannot resume")
        let old = ThumbnailFiles.previousCurrent(in: directory, id: id)
        try Data([1]).write(to: old)
        check(ThumbnailFiles.display(in: directory, id: id) == old
              && ThumbnailFiles.needsRefresh(in: directory, id: id),
              "thumbnail quality: prior renderer is not a visible, stale fallback")
        let pendingBasic = gate.token(id)
        check(try gate.install(Data([2]), in: directory, id: id, token: pendingBasic, quality: .basic),
              "thumbnail quality: basic checkpoint cannot be installed")
        check(!ThumbnailFiles.needsRefresh(in: directory, id: id) && ThumbnailFiles.needsRefinement(in: directory, id: id),
              "thumbnail quality: basic completion confused with refinement")
        // Simulated interruption: completed basic remains valid at restart, another unfinished photo does not.
        check(ThumbnailFiles.needsRefresh(in: directory, id: other), "thumbnail quality: unfinished photo marked complete")
        let editor = gate.advance(id)
        check(try gate.install(Data([3]), in: directory, id: id, token: editor, quality: .refined),
              "thumbnail quality: editor refinement cannot be installed")
        check(!(try gate.install(Data([9]), in: directory, id: id, token: pendingBasic, quality: .basic)),
              "thumbnail quality: older basic render overwrites editor refinement")
        let persisted = try Data(contentsOf: ThumbnailFiles.display(in: directory, id: id))
        check(!ThumbnailFiles.needsRefinement(in: directory, id: id) && persisted == Data([3]),
              "thumbnail quality: durable refined result lost after stale install")
        gate.setEnabled(false); check(!gate.canRender, "thumbnail scheduler: editor/background cannot pause starts")
        gate.remove(id)
        check(!(try gate.install(Data([9]), in: directory, id: id, token: editor, quality: .refined)),
              "thumbnail quality: deletion permits a late thumbnail to recreate files")

        // Simulate a kill between JPEG installation and cleanup: newest complete quality must win by itself.
        let basic = ThumbnailFiles.current(in: directory, id: other, quality: .basic)
        let refined = ThumbnailFiles.current(in: directory, id: other)
        let recipe = directory.appendingPathComponent("recipe.json")
        try Data([4]).write(to: refined); try Data([5]).write(to: basic); try Data([6]).write(to: recipe)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20)], ofItemAtPath: refined.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: basic.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-15)], ofItemAtPath: recipe.path)
        check(ThumbnailFiles.display(in: directory, id: other) == basic
              && !ThumbnailFiles.needsRefresh(in: directory, id: other, recipe: recipe)
              && ThumbnailFiles.needsRefinement(in: directory, id: other, recipe: recipe),
              "thumbnail quality: interrupted cleanup promotes old refined pixels over newer basic")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: recipe.path)
        check(ThumbnailFiles.needsRefresh(in: directory, id: other, recipe: recipe),
              "thumbnail quality: new saved edits do not invalidate older renditions")

        var edits = EditSettings(); edits.lensBlur.amount = 20
        var automatic = Mask.make(.subject); automatic.adjust.exposure = 1; automatic.invert = true
        var manual = Mask.make(.brush); manual.adjust.exposure = 0.5
        edits.masks = [automatic, manual]
        let quick = ThumbnailFiles.basicRecipe(edits)
        check(ThumbnailFiles.requiresRefinement(edits) && quick.lensBlur.amount == 0 && quick.masks == [manual],
              "thumbnail quality: basic rendition runs AI or inverts an unprepared automatic mask")
        check(!ThumbnailFiles.requiresRefinement(quick), "thumbnail quality: manual/global edits incorrectly need AI refinement")
        let blockedID = UUID(), fallback = ThumbnailFiles.legacy(in: directory, id: blockedID)
        try Data([8]).write(to: fallback)
        try FileManager.default.createDirectory(at: ThumbnailFiles.current(in: directory, id: blockedID), withIntermediateDirectories: true)
        var refused = false
        do { try ThumbnailFiles.install(Data([9]), in: directory, id: blockedID, quality: .refined) }
        catch { refused = true }
        let oldBytes = try Data(contentsOf: fallback)
        check(refused && oldBytes == Data([8]), "thumbnail quality: failed atomic install removes the old display JPEG")
    } catch { check(false, "thumbnail scheduler fixtures failed: \(error)") }
}
