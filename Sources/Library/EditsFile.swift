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

    static func decodeSettings(_ data: Data) -> EditSettings {
        let decoder = JSONDecoder()
        if let s = try? decoder.decode(EditSettings.self, from: data) { return s }
        // Older sidecar: lay its values over today's defaults, dropping anything that no longer fits.
        // The template has one mask so masks, components and their adjustments get today's defaults too.
        var template = EditSettings()
        template.masks = [Mask.make(.brush)]
        guard var old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(template))) as? [String: Any]
        else { return EditSettings() }
        old = old.filter { defaults[$0.key] != nil }
        // Lens Blur reads the absence of these to recognise an old save (old amount scale; a saved choice): the
        // template must not fill them in
        if var lens = defaults["lensBlur"] as? [String: Any] {
            lens["scaleVersion"] = nil; lens["activated"] = nil
            defaults["lensBlur"] = lens
        }
        let maskTemplate = defaults["masks"] ?? [Any]()
        defaults["masks"] = [Any]()
        for dropping in [[], ["masks"]] as [[String]] {
            var merged = defaults
            for (k, v) in old where !dropping.contains(k) {
                merged[k] = Self.overlay(v, on: k == "masks" ? maskTemplate : defaults[k] ?? v)
            }
            if let d = try? JSONSerialization.data(withJSONObject: merged),
               let s = try? decoder.decode(EditSettings.self, from: d) { return s }
        }
        return EditSettings()
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

    static func readHistory(file: URL, legacy: Data?) -> History? {
        if let data = try? Data(contentsOf: file), let h = try? JSONDecoder().decode(History.self, from: data) { return h }
        guard let data = legacy,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = json["_undoHistory"],
              let encoded = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(History.self, from: encoded)
    }

}
