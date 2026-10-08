import SwiftUI
import MetalKit
import CoreImage

/// Where the photo sits inside the canvas (points), given pinch-zoom and pan.
struct ViewXform: Equatable {
    var canvas: CGSize
    var image: CGSize
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    var rect: CGRect {
        guard image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let s = min(canvas.width / image.width, canvas.height / image.height) * zoom
        let w = image.width * s, h = image.height * s
        return CGRect(x: canvas.width / 2 + pan.width - w / 2, y: canvas.height / 2 + pan.height - h / 2, width: w, height: h)
    }

    /// Normalised (0...1, top-left origin) -> canvas point.
    func point(_ x: Double, _ y: Double) -> CGPoint {
        let r = rect
        return CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.minY + CGFloat(y) * r.height)
    }

    func normalised(_ p: CGPoint) -> Pt {
        let r = rect
        guard r.width > 0, r.height > 0 else { return Pt(x: 0, y: 0) }
        return Pt(x: Double(min(max((p.x - r.minX) / r.width, 0), 1)), y: Double(min(max((p.y - r.minY) / r.height, 0), 1)))
    }
}

/// Holds the image the Metal view should draw. Updated on the main thread; drawing is cheap because the graph is lazy.
final class CanvasModel {
    var image: CIImage?
    weak var view: MTKView?

    func update(_ img: CIImage?) {
        image = img
        view?.setNeedsDisplay()
    }
}

final class CanvasRenderer: NSObject, MTKViewDelegate {
    let model: CanvasModel
    var xform = ViewXform(canvas: .zero, image: .zero)

    init(model: CanvasModel) { self.model = model }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue = LumenGPU.queue, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        guard size.width > 1, size.height > 1 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        var out = CIImage(color: .black).cropped(to: bounds)
        let r = xform.rect
        if let img = model.image, r.width > 1, r.height > 1 {
            let sf = view.contentScaleFactor
            let ext = img.extent
            let k = r.width * sf / ext.width
            var placed = img.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            if k < 0.7 {
                placed = placed.applyingFilter("CILanczosScaleTransform",
                                               parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
            } else {
                placed = placed.transformed(by: CGAffineTransform(scaleX: k, y: k))
            }
            let h = placed.extent.height
            // Core Image's origin is bottom-left; position by the photo's top-left corner in view space.
            placed = placed.transformed(by: CGAffineTransform(translationX: r.minX * sf, y: size.height - (r.minY * sf + h)))
            out = placed.composited(over: out)
        }
        LumenGPU.context.render(out, to: drawable.texture, commandBuffer: cb, bounds: bounds, colorSpace: LumenGPU.displaySpace)
        cb.present(drawable)
        cb.commit()
    }
}

struct CanvasView: UIViewRepresentable {
    let model: CanvasModel
    let xform: ViewXform

    func makeCoordinator() -> CanvasRenderer { CanvasRenderer(model: model) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: LumenGPU.device)
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.isOpaque = true
        v.backgroundColor = .black
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        (v.layer as? CAMetalLayer)?.colorspace = LumenGPU.displaySpace
        v.delegate = context.coordinator
        model.view = v
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator.xform = xform
        model.view = v
        v.setNeedsDisplay()
    }
}
