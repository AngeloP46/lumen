// Headless RAW format matrix: `raw-matrix <metallib> <inputDir> <outDir>`
//
// One sample per camera RAW format (Canon CR3, Nikon NEF, Fuji RAF, Sony ARW, Adobe DNG).
// For each: the engine must open it, decode it, and export it to JPEG. This is the Gate 2
// "every camera" proof — the engine's decode path is exactly what the app uses (CIRAWFilter
// on the GPU), so a pass here means the app opens and edits that format.
//
// DRAFT — sandbox only. Not part of the SideStore build.
import CoreImage
import CoreText
import Foundation
import ImageIO
import Metal

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
LumenGPU.libraryURL = URL(fileURLWithPath: args[1])
let inDir = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
print("Metal:", LumenGPU.device?.name ?? "none", "kernels:", LumenKernels.shared != nil)
guard LumenKernels.shared != nil else { print("KERNELS FAILED TO LOAD"); exit(1) }

let files = ((try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? [])
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let wanted = ["cr3", "nef", "raf", "arw", "dng"]
print("samples:", files.map { $0.lastPathComponent }.joined(separator: " | "))

var failures: [String] = []
func check(_ ok: Bool, _ message: String) {
    if !ok { failures.append(message); print("FAIL:", message, "\n::error::" + message.replacingOccurrences(of: "\n", with: " ").prefix(900)) }
}

func avgBrightness(_ cg: CGImage?) -> Float {
    guard let cg else { return -1 }
    let w = 128, h = 128
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum: Float = 0
    for i in 0..<(w * h) { sum += Float(0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2])) / 255 }
    return sum / Float(w * h)
}

var passCount = 0
for f in files {
    let ext = f.pathExtension.lowercased()
    guard wanted.contains(ext) else { continue }
    let name = f.deletingPathExtension().lastPathComponent
    print("== \(name) (\(ext.uppercased())) ==")

    // 1. open — the app's own entry point
    guard let session = EditSession(url: f) else { check(false, "\(name): EditSession could not open the file"); continue }

    // 2. decode — a preview-size render proves the RAW was actually decoded, not just sniffed
    guard let cg = session.renderCGImage(EditSettings(), maxEdge: 600) else {
        check(false, "\(name): decode failed (renderCGImage nil)")
        continue
    }
    let avg = avgBrightness(cg)
    check(avg > 0.03 && avg < 0.97, "\(name): decoded image looks blank or full-white (avg brightness \(String(format: "%.3f", avg)))")

    // 3. export at full resolution — JPEG, HEIC and 16-bit TIFF, the app's three export formats
    for (fmt, minKB) in [(ExportFormat.jpeg, 20), (ExportFormat.heic, 20), (ExportFormat.tiff, 500)] {
        guard let data = session.renderData(EditSettings(), format: fmt, quality: 0.9) else {
            check(false, "\(name): \(fmt.rawValue) export returned nil")
            continue
        }
        check(data.count > minKB * 1024, "\(name): \(fmt.rawValue) export is suspiciously small (\(data.count / 1024) KB)")
        print("   \(fmt.rawValue) full-size export: \(data.count / 1024) KB")
    }
    passCount += 1
}

let found = files.map { $0.pathExtension.lowercased() }.filter { wanted.contains($0) }
check(found.count == wanted.count, "expected one sample per format (\(wanted.count)), found \(found.count): \(found.sorted())")
let summary = failures.isEmpty
    ? "PASS: \(passCount)/\(passCount) RAW formats decoded and exported"
    : "FAILED: \(failures.count) problems\n" + failures.map { "  - " + $0 }.joined(separator: "\n")
print("==== RAW MATRIX SUMMARY ====")
print(summary)
try? (summary + "\n").write(to: outDir.appendingPathComponent("RESULT.txt"), atomically: true, encoding: .utf8)
exit(failures.isEmpty ? 0 : 1)
