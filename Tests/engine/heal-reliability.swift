import Foundation
import CoreImage
import ImageIO

/// Saved Heal assets and people-search outcomes can be checked without running either neural model.
func runHealReliabilityChecks() {
    let oldDirectory = HealStore.directory
    let directory = outDir.appendingPathComponent("heal-reliability-\(UUID().uuidString)")
    HealStore.directory = directory
    defer { HealStore.directory = oldDirectory; try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appendingPathComponent("original.png")
        let frame = CGRect(x: 0, y: 0, width: 96, height: 80)
        let original = CIImage(color: CIColor(red: 0.1, green: 0.25, blue: 0.7)).cropped(to: frame)
        try LumenGPU.context.writePNGRepresentation(of: original, to: photo, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        guard let session = EditSession(url: photo, expandHDR: false) else {
            check(false, "Heal reliability: original fixture cannot be opened"); return
        }
        var edits = EditSettings(); edits.hdr = false
        let spot = HealSpot(strokes: [], x: 0, y: 0, w: 1, h: 1)
        edits.heals = [spot]
        func rejected(_ label: String) {
            check(HealStore.unavailable(edits.effective.heals, owner: photo) == [spot.id],
                  "Heal reliability: \(label) was reported available")
            if case .failed(.healMissing) = session.renderDataOutcome(edits, format: .jpeg, quality: 0.9, includeHDR: false) {
                check(true, "")
            } else { check(false, "Heal reliability: \(label) silently exports without the saved fix") }
        }
        rejected("missing patch and mask")
        func writeAsset(_ url: URL, mask: Bool, width: Int = 32, height: Int = 32) throws {
            let image = CIImage(color: mask ? CIColor.white : CIColor(red: 0.7, green: 0.15, blue: 0.1))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let space = mask ? CGColorSpaceCreateDeviceGray() : LumenGPU.displaySpace
            guard let cg = LumenGPU.context.createCGImage(image, from: image.extent, format: mask ? .L8 : .RGBA8, colorSpace: space),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw NSError(domain: "HealFixture", code: 1)
            }
            CGImageDestinationAddImage(destination, cg, nil)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "HealFixture", code: 2) }
        }
        try writeAsset(HealStore.patchURL(spot.id), mask: false)
        rejected("missing mask")
        try writeAsset(HealStore.maskURL(spot.id), mask: true)
        check(HealStore.unavailable([spot], owner: photo).isEmpty, "Heal reliability: valid legacy patch without owner rejected")
        let patched = session.renderData(edits, format: .jpeg, quality: 0.9, includeHDR: false)
        var off = edits; off.setOn(.heal, false)
        let unpatched = session.renderData(off, format: .jpeg, quality: 0.9, includeHDR: false)
        func average(_ data: Data?) -> [Float]? {
            guard let data, let image = CIImage(data: data) else { return nil }
            let mean = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var values = [Float](repeating: 0, count: 4)
            LumenGPU.context.render(mean, toBitmap: &values, rowBytes: 16,
                                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return values
        }
        if let on = average(patched), let neutral = average(unpatched) {
            check(zip(on.prefix(3), neutral.prefix(3)).map { abs($0 - $1) }.reduce(0, +) > 0.1,
                  "Heal reliability: valid saved patch was not applied to export")
        } else { check(false, "Heal reliability: valid patch/off exports failed") }

        // Check file changes even when the previous valid image was cached in this session.
        let goodPatch = try Data(contentsOf: HealStore.patchURL(spot.id))
        try goodPatch.dropLast(12).write(to: HealStore.patchURL(spot.id), options: .atomic)
        rejected("truncated patch after warm cache")
        try goodPatch.write(to: HealStore.patchURL(spot.id), options: .atomic)
        try Data([0]).write(to: HealStore.maskURL(spot.id), options: .atomic)
        rejected("corrupt mask after warm cache")
        try writeAsset(HealStore.maskURL(spot.id), mask: true, width: 16, height: 16)
        rejected("patch and mask dimensions disagree")
        try writeAsset(HealStore.maskURL(spot.id), mask: true)
        let ownerRecord = directory.appendingPathComponent("\(spot.id.uuidString)-owner.json")
        try JSONEncoder().encode("another-photo.png").write(to: ownerRecord, options: .atomic)
        rejected("patch owned by another photo")
        try JSONEncoder().encode(photo.lastPathComponent).write(to: ownerRecord, options: .atomic)
        check(HealStore.unavailable([spot], owner: photo).isEmpty, "Heal reliability: repaired assets/current owner rejected")
        try FileManager.default.removeItem(at: HealStore.patchURL(spot.id))
        rejected("patch deleted after warm cache")
        if case .data = session.renderDataOutcome(off, format: .jpeg, quality: 0.9, includeHDR: false) {
            check(true, "")
        } else { check(false, "Heal reliability: disabled missing Heal incorrectly blocks export") }

        // Production outcome handling, union and splitter, using deterministic detector answers.
        if case .failed(.detection) = session.findPeople(earlier: [], detect: { _ in .failed }) {
            check(true, "")
        } else { check(false, "People reliability: detector failure becomes successful empty search") }
        if case .found(let people) = session.findPeople(earlier: [], detect: { _ in .found([]) }) {
            check(people.isEmpty, "People reliability: successful empty search invents detections")
        } else { check(false, "People reliability: successful empty search becomes failure") }
        let black = CIImage(color: .black).cropped(to: frame)
        let person = CIImage(color: .white).cropped(to: CGRect(x: 30, y: 10, width: 20, height: 55))
            .composited(over: black).cropped(to: frame)
        if case .found(let people) = session.findPeople(earlier: [], detect: { _ in .found([black, person]) }) {
            check(people.count == 1 && people[0].area > 0.1,
                  "People reliability: a useful fallback detection was lost")
        } else { check(false, "People reliability: useful fallback mask becomes failure") }
        var detectorCalled = false
        if case .failed(.healMissing) = session.findPeople(earlier: [spot], detect: { _ in detectorCalled = true; return .found([]) }) {
            check(!detectorCalled, "People reliability: search ran on silently unhealed input")
        } else { check(false, "People reliability: missing earlier Heal was silently ignored") }
    } catch { check(false, "Heal reliability fixture failed: \(error)") }
}
