import Foundation

/// Copy and paste of edits, like Lightroom's Copy Settings / Paste Settings (Angelo, 22 Oct): what goes is chosen when
/// copying (tools, and each mask by name); Paste then applies exactly that, to one photo or many, from the library or
/// the editor. One rule for every place (quality checklist A12: paste used to behave differently in four places).
/// Foundation only, so Tests/logic checks the rules on Linux.

/// What to copy. Remembered between copies (masks are chosen per photo, so only "all masks or none" is remembered).
struct CopySelection: Codable, Equatable {
    /// Light, Color, Grade, Curve, Detail, Crop (and Masks as a whole when `allMasks`).
    var sections: Set<String> = []
    /// HDR mode (photo-wide, part of Light in Lightroom).
    var hdr = false
    /// AI Denoise: each photo needs its own clean (about a minute), so pasting it asks first.
    var aiDenoise = false
    /// Masks picked by id on the photo being copied.
    var masks: Set<UUID> = []

    func has(_ s: EditSection) -> Bool { sections.contains(s.rawValue) }
    mutating func set(_ s: EditSection, _ on: Bool) { if on { sections.insert(s.rawValue) } else { sections.remove(s.rawValue) } }

    /// The tools Copy offers, in order. Heal (fixes made for one photo's pixels) and Lens Blur (focus is this photo's)
    /// always stay with each photo; Masks are offered one by one.
    static let tools: [EditSection] = [.light, .color, .grade, .curve, .detail, .crop]

    /// Lightroom's "Modified": every tool this photo has edits in, except Crop; masks are left for you to pick.
    static func modified(_ s: EditSettings) -> CopySelection {
        var c = CopySelection()
        for t in tools where t != .crop && s.hasCopyableEdits(t) { c.set(t, true) }
        c.hdr = s.hdr
        return c
    }
    static func all(_ s: EditSettings) -> CopySelection {
        var c = CopySelection()
        for t in tools { c.set(t, true) }
        c.hdr = true
        c.aiDenoise = s.aiDenoise > 0
        c.masks = Set(s.copyableMasks.map(\.id))
        return c
    }
}

/// The copied edits and what was chosen from them.
struct Clipboard: Equatable {
    var settings: EditSettings
    var selection: CopySelection
    /// The photo they came from (for the "Pasted … from …" message).
    var sourceName: String
    /// Its id: pasting back onto it must not re-adapt its own masks (checklist review, 23 Oct).
    var sourceID: UUID? = nil

    /// Pasting brings AI Denoise (the photo may need a clean first).
    var bringsDenoise: Bool { selection.aiDenoise && settings.aiDenoise > 0 }

    /// What Paste will apply, in a few words: "Light, Colour, Sky mask" (menus and the confirmation).
    var summary: String {
        var parts: [String] = []
        for t in CopySelection.tools where selection.has(t) { parts.append(t.copyTitle) }
        if selection.hdr { parts.append("HDR") }
        let masks = settings.copyableMasks.filter { selection.masks.contains($0.id) }
        if masks.count == 1 { parts.append("\(masks[0].name) mask") } else if masks.count > 1 { parts.append("\(masks.count) masks") }
        if bringsDenoise { parts.append("AI Denoise") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
    var isEmpty: Bool { summary == "nothing" }

    /// `own` with the copied edits pasted on. Everything not chosen stays the photo's own; heals, Lens Blur (and its
    /// focus mask) and AI Denoise's strength always do (the caller pastes AI Denoise once the photo is cleaned).
    /// `samePhoto`: it is being pasted back onto the photo it was copied from; the masks it picked are already there as
    /// they are (re-adapting them would drop a tapped subject, reorder them and add an undo step for nothing).
    func pasted(onto own: EditSettings, samePhoto: Bool = false) -> EditSettings {
        var s = own
        // A whole look carries its engine. A partial paste keeps an already edited destination's engine, so
        // tools that were not selected do not change. An untouched destination can adopt the copied recipe.
        let look: [EditSection] = [.light, .color, .grade, .curve, .detail]
        if look.allSatisfy({ selection.has($0) }) || !look.contains(where: { own.hasEdits($0) }) && own.masks.isEmpty {
            if look.contains(where: { selection.has($0) }) || !selection.masks.isEmpty {
                s.processingVersion = settings.processingVersion
            }
        }
        for t in CopySelection.tools where selection.has(t) {
            s.take(t, from: settings)
            s.setOn(t, settings.isOn(t))
        }
        s.aiDenoise = own.aiDenoise               // Detail's take() copies it; a clean of this photo decides
        if selection.hdr { s.hdr = settings.hdr; s.hdrStops = settings.hdrStops }
        let chosen = settings.copyableMasks.filter { selection.masks.contains($0.id) }
        if !chosen.isEmpty, !samePhoto {
            // pasting the same mask again replaces it instead of adding a second copy
            let ids = Set(chosen.map(\.id))
            s.masks.removeAll { ids.contains($0.id) && $0.id != own.lensBlur.maskID }
            s.masks += chosen.forAnotherPhoto
            s.setOn(.masks, settings.isOn(.masks))
        }
        return s
    }
}

extension EditSettings {
    /// Whether Copy has anything to take from this tool. AI Denoise has its own tick (each photo needs its own
    /// clean), so it doesn't make Detail count as edited.
    func hasCopyableEdits(_ t: EditSection) -> Bool {
        guard t == .detail else { return hasEdits(t) }
        var c = self
        c.aiDenoise = 0
        return c.hasEdits(.detail)
    }

    /// The masks Copy lists: the photo's own masks, not Lens Blur's linked focus mask (it belongs to Lens Blur).
    var copyableMasks: [Mask] { masks.filter { $0.id != lensBlur.maskID } }
}

extension EditSection {
    /// Names in the Copy list and the paste summary.
    var copyTitle: String {
        switch self {
        case .light: "Light"
        case .color: "Colour"
        case .grade: "Colour grading"
        case .curve: "Curve"
        case .detail: "Detail"
        case .crop: "Crop and transform"
        case .masks: "Masks"
        case .heal: "Heal"
        case .lensBlur: "Lens Blur"
        }
    }
}
