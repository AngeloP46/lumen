import Foundation
import ImageIO

/// Read-only information from the imported original, using standard EXIF/TIFF across camera brands.
struct PhotoInformation: Sendable {
    var camera = "Not recorded"
    var lens = "Not recorded"
    var date = "Not recorded"
    var dimensions = "Not recorded"
    var size = "Unknown size"
    var shutter = "—"
    var aperture = "—"
    var iso = "—"

    static func read(_ url: URL) -> PhotoInformation {
        var info = PhotoInformation()
        if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            info.size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return info }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let make = text(tiff[kCGImagePropertyTIFFMake]) ?? ""
        if let model = text(tiff[kCGImagePropertyTIFFModel]) {
            info.camera = model.lowercased().contains(make.lowercased()) ? model : "\(make) \(model)".trimmingCharacters(in: .whitespaces)
        } else if !make.isEmpty { info.camera = make }
        var lensParts: [String] = []
        if let mm = number(exif[kCGImagePropertyExifFocalLength]), mm > 0 {
            lensParts.append(String(format: "%g mm", mm))
        }
        if let model = text(exif[kCGImagePropertyExifLensModel]) { lensParts.append(model) }
        else if let specification = exif[kCGImagePropertyExifLensSpecification] as? [NSNumber], specification.count == 4 {
            let lo = specification[0].doubleValue, hi = specification[1].doubleValue
            if lo > 0 && hi > 0 { lensParts.append(lo == hi ? String(format: "%g mm lens", lo) : String(format: "%g–%g mm lens", lo, hi)) }
        }
        if !lensParts.isEmpty { info.lens = lensParts.joined(separator: " · ") }
        if let date = text(exif[kCGImagePropertyExifDateTimeOriginal]) ?? text(exif[kCGImagePropertyExifDateTimeDigitized]) ?? text(tiff[kCGImagePropertyTIFFDateTime]) {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let captured = parser.date(from: date) {
                let display = DateFormatter(); display.locale = Locale(identifier: "en_GB")
                display.timeZone = parser.timeZone; display.dateFormat = "d MMMM yyyy · HH:mm:ss"
                info.date = display.string(from: captured)
            } else { info.date = date }
        }
        if let w = number(exif[kCGImagePropertyExifPixelXDimension]) ?? number(p[kCGImagePropertyPixelWidth]),
           let h = number(exif[kCGImagePropertyExifPixelYDimension]) ?? number(p[kCGImagePropertyPixelHeight]), w > 0, h > 0 {
            let orientation = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let portrait = (5...8).contains(orientation)
            info.dimensions = String(format: "%.1f MP · %g × %g", w * h / 1_000_000, portrait ? h : w, portrait ? w : h)
        }
        if let seconds = number(exif[kCGImagePropertyExifExposureTime]), seconds.isFinite, seconds > 0 {
            info.shutter = seconds < 1 ? String(format: "1/%.0f sec", 1 / seconds) : String(format: "%g sec", seconds)
        }
        if let f = number(exif[kCGImagePropertyExifFNumber]), f > 0 { info.aperture = String(format: "ƒ/%g", f) }
        if let values = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let value = values.first { info.iso = value.stringValue }
        return info
    }
}

