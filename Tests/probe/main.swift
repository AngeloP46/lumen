import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers
import Foundation

let dev = MTLCreateSystemDefaultDevice()
print("Metal device:", dev?.name ?? "NONE")
let args = CommandLine.arguments
let libURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let data = try! Data(contentsOf: libURL)
let kernel = try CIColorKernel(functionName: "probeKernel", fromMetalLibraryData: data)
// gradient test image
let g = CIFilter(name: "CILinearGradient", parameters: [
    "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 512, y: 0),
    "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 0.5, blue: 0.2)])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 512, height: 256))
let out = kernel.apply(extent: g.extent, arguments: [g, CIVector(x: 0.5, y: 1, z: 1, w: 1)])!
for (name, ctx) in [("gpu", CIContext()), ("cpu", CIContext(options: [.useSoftwareRenderer: true]))] {
    if let cg = ctx.createCGImage(out, from: out.extent) {
        let url = outDir.appendingPathComponent("probe-\(name).png")
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
        print(name, "ok")
    } else { print(name, "FAILED") }
}
