import Foundation

/// A completed thumbnail carries its renderer revision in its filename. Progress survives an interrupted batch;
/// old JPEGs remain available for display until their replacements have been written atomically.
enum ThumbnailFiles {
    static func current(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-engine-\(EditSettings.currentFormat).jpg")
    }
    static func legacy(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
    static func needsRefresh(in directory: URL, id: UUID) -> Bool {
        !FileManager.default.fileExists(atPath: current(in: directory, id: id).path)
    }
}
