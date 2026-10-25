import Foundation

/// Reading a photo's edits file (sidecar) and its undo history, including files written by older versions.
/// Foundation only, so the logic tests (Tests/logic) run it on Linux in seconds. Moved out of LibraryStore on
/// 22 Oct 2026 without changing behaviour (quality checklist, batch 0); the fixes for checklist A1 come in batch 1.
enum EditsFile {
    /// Undo / redo for one photo (`<id>.history.json`).
    struct History: Codable {
        var current: EditSettings
        var undo: [EditSettings]
        var redo: [EditSettings]
    }

    /// What reading an edits file found, so the editor can say so and the original can be kept (checklist A1).
    struct LoadReport: Equatable {
        /// Written by an older Lumen and laid over today's defaults (normal: nothing lost).
        var migrated = false
        /// Masks, or parts of masks, this version can't read (from a newer Lumen, or damaged).
        var droppedMasks = 0
        /// Settings this version can't read.
        var droppedSettings: [String] = []
        /// Written by a newer Lumen.
        var newerVersion = false
        /// Not an edits file at all (damaged): read as no edits.
        var unreadable = false

        /// Something couldn't be read: the file is copied before anything is saved over it.
        var lostSomething: Bool { droppedMasks > 0 || !droppedSettings.isEmpty || newerVersion || unreadable }

        /// What to tell the user, or nil when nothing was lost.
        var message: String? {
            if unreadable { return "This photo's edits file was damaged, so it opened without edits. A copy of the file was kept." }
            var parts: [String] = []
            if droppedMasks > 0 { parts.append("\(droppedMasks) mask\(droppedMasks == 1 ? "" : "s") or mask part\(droppedMasks == 1 ? "" : "s")") }
            if !droppedSettings.isEmpty { parts.append("\(droppedSettings.count) setting\(droppedSettings.count == 1 ? "" : "s")") }
            if newerVersion {
                return "These edits were made with a newer version of Lumen" + (parts.isEmpty ? "" : "; \(parts.joined(separator: " and ")) couldn't be read")
                    + ". A copy of the original edits was kept."
            }
            guard !parts.isEmpty else { return nil }
            return "Some edits on this photo couldn't be read (\(parts.joined(separator: " and "))). A copy of the original edits was kept."
        }
    }

    static func decodeSettings(_ data: Data) -> EditSettings { load(data).settings }

    /// Reads a photo's edits, from today's, older or newer versions of Lumen. Nothing readable is lost: settings and
    /// masks are read one by one, so one unknown mask (say, a kind added by a newer version) drops only that mask.
    /// Before 22 Oct a single unreadable mask dropped every mask, and any unreadable key all the edits (checklist A1).
    static func load(_ data: Data) -> (settings: EditSettings, report: LoadReport) {
        var report = LoadReport()
        let decoder = JSONDecoder()
        if var s = try? decoder.decode(EditSettings.self, from: data) {
            report.newerVersion = s.formatVersion > EditSettings.currentFormat
            // what this version holds is in this version's format: saved back, the file must not claim to be the newer
            // one it came from (it no longer holds that version's extras), or a later newer Lumen would trust it
            s.formatVersion = EditSettings.currentFormat
            return (s, report)
        }
        guard let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            report.unreadable = true
            return (EditSettings(), report)
        }
        report.migrated = true
        if let v = old["formatVersion"] as? Int, v > EditSettings.currentFormat { report.newerVersion = true }
        // today's defaults, as JSON; the mask template gives masks, parts and their adjustments today's defaults too
        var template = EditSettings()
        template.masks = [Mask.make(.brush)]
        guard var defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(template))) as? [String: Any],
              let maskTemplate = (defaults["masks"] as? [Any])?.first else { return (EditSettings(), report) }
        defaults["masks"] = [Any]()
        // Lens Blur reads the absence of these to recognise an old save (old amount scale; a saved choice): the
        // template must not fill them in
        defaults["cropVersion"] = nil   // absent = an older crop; the template must not make it a new one
        if var lens = defaults["lensBlur"] as? [String: Any] {
            lens["scaleVersion"] = nil; lens["activated"] = nil
            defaults["lensBlur"] = lens
        }
        func decodes(_ obj: [String: Any]) -> EditSettings? {
            guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            return try? decoder.decode(EditSettings.self, from: d)
        }
        // every setting this version knows, laid over the default; one that doesn't read is left at its default
        var merged = defaults
        for (k, v) in old where k != "masks" && defaults[k] != nil {
            var trial = merged
            trial[k] = Self.overlay(v, on: defaults[k] ?? v)
            if decodes(trial) != nil { merged = trial } else { report.droppedSettings.append(k) }
        }
        guard var s = decodes(merged) else { return (EditSettings(), report) }
        s.formatVersion = EditSettings.currentFormat   // see above
        // A malformed container is not an empty mask list. Preserve the original and tell the caller.
        if let masks = old["masks"], !(masks is [Any]) { report.droppedMasks += 1 }
        // masks one by one, and inside a mask its parts one by one
        for raw in (old["masks"] as? [Any]) ?? [] {
            guard var m = raw as? [String: Any] else { report.droppedMasks += 1; continue }
            if let comps = m["components"] as? [Any] {
                let partTemplate = ((maskTemplate as? [String: Any])?["components"] as? [Any])?.first ?? [:]
                var kept: [Any] = []
                for c in comps {
                    let laid = Self.overlay(c, on: partTemplate)
                    if let d = try? JSONSerialization.data(withJSONObject: laid), (try? decoder.decode(MaskComponent.self, from: d)) != nil {
                        kept.append(laid)
                    } else {
                        report.droppedMasks += 1
                    }
                }
                guard !kept.isEmpty else { continue }
                m["components"] = kept
            }
            var laidMask = Self.overlay(m, on: maskTemplate) as? [String: Any] ?? m
            if let comps = m["components"] { laidMask["components"] = comps }
            if let d = try? JSONSerialization.data(withJSONObject: laidMask), let mask = try? decoder.decode(Mask.self, from: d) {
                s.masks.append(mask)
            } else {
                report.droppedMasks += 1
            }
        }
        return (s, report)
    }

    /// Lays old JSON values over a template: objects are merged key by key (keys the template lacks are dropped),
    /// array elements are each merged over the template's first element.
    static func overlay(_ value: Any, on template: Any) -> Any {
        if let v = value as? [String: Any], let t = template as? [String: Any] {
            var out = t
            // keys the template lacks are kept: they are the optional ones (left out of the template because they are
            // nil there), e.g. Lens Blur's linked mask and focus point, which migration used to drop (code review, 19 Oct)
            for (k, x) in v { out[k] = t[k].map { overlay(x, on: $0) } ?? x }
            return out
        }
        if let v = value as? [Any], let t = (template as? [Any])?.first, t is [String: Any] {
            return v.map { overlay($0, on: t) }
        }
        return value
    }

    /// The undo history: today's file, or one kept inside an older edits file (0.1.197–0.1.210). Each step is read
    /// like an edits file, so a step from before (or after) a format change no longer throws the whole history away;
    /// a step that can't be read at all is left out (checklist A1).
    static func readHistory(file: URL, legacy: Data?) -> History? {
        if let data = try? Data(contentsOf: file), let h = history(data) { return h }
        guard let data = legacy,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = json["_undoHistory"],
              let encoded = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return history(encoded)
    }

    static func history(_ data: Data) -> History? {
        if let h = try? JSONDecoder().decode(History.self, from: data) { return h }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let current = obj["current"],
              let currentData = try? JSONSerialization.data(withJSONObject: current) else { return nil }
        let (now, report) = load(currentData)
        guard !report.unreadable else { return nil }
        func steps(_ key: String) -> [EditSettings] {
            ((obj[key] as? [Any]) ?? []).compactMap { step in
                guard let d = try? JSONSerialization.data(withJSONObject: step) else { return nil }
                let (s, r) = load(d)
                return r.unreadable ? nil : s
            }
        }
        return History(current: now, undo: steps("undo"), redo: steps("redo"))
    }
}
