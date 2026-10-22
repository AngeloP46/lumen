import SwiftUI
import MetalKit
import CoreImage

/// Where the photo sits inside the canvas (points), given pinch-zoom and pan.
struct ViewXform: Equatable {
    var canvas: CGSize
    var image: CGSize
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// The photo sits on the bottom edge (on top of the panel) while it is shorter than the view, and grows upwards into
    /// the free space as it is zoomed; once it is taller than the view it is centred as usual (owner's request 2026-10-10).
    var bottomAlign = false

    var rect: CGRect {
        guard image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let s = min(canvas.width / image.width, canvas.height / image.height) * zoom
        let w = image.width * s, h = image.height * s
        let drop = bottomAlign ? max((canvas.height - h) / 2, 0) : 0
        return CGRect(x: canvas.width / 2 + pan.width - w / 2, y: canvas.height / 2 + pan.height - h / 2 + drop,
                      width: w, height: h)
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

    /// Like `normalised` but not stopped at the photo's edges (mask handles may sit outside the picture), within `limit`.
    func unclamped(_ p: CGPoint, limit: ClosedRange<Double> = -1.5...2.5) -> Pt {
        let r = rect
        guard r.width > 0, r.height > 0 else { return Pt(x: 0, y: 0) }
        let x = Double((p.x - r.minX) / r.width), y = Double((p.y - r.minY) / r.height)
        return Pt(x: min(max(x, limit.lowerBound), limit.upperBound), y: min(max(y, limit.lowerBound), limit.upperBound))
    }
}

/// Holds the image the Metal view should draw. Updated on the main thread; drawing is cheap because the graph is lazy.
final class CanvasModel {
    var image: CIImage?
    /// Every Metal view showing this photo. Turning the phone rebuilds the layout and can leave more than one view
    /// (and not always the one on screen) attached; keeping just the last one meant edits were rendered but never
    /// drawn after a rotation (owner's bug 2026-10-11). Now every view that is on screen redraws.
    private let views = NSHashTable<MTKView>.weakObjects()
    var view: MTKView? {
        get { views.allObjects.last { $0.window != nil } ?? views.allObjects.last }
        set { if let v = newValue { views.add(v) } }
    }
    /// Called on the main thread with the screen's (current, potential) EDR headroom when either changes by more than
    /// 5% (HDR mode only).
    var onHeadroom: ((CGFloat, CGFloat) -> Void)?
    /// Called once, after the next frame has been drawn (diagnostics: open → first frame).
    var onFirstFrame: (() -> Void)?

    /// How long each frame took from asking the GPU to drawn (milliseconds), for diagnostics (checklist F).
    private var frameTimes: [Double] = []
    func recordFrame(_ ms: Double) {
        if frameTimes.count < 5000 { frameTimes.append(ms) }
        if let f = onFirstFrame { onFirstFrame = nil; f() }
    }
    func frameStats() -> (count: Int, median: Double, p95: Double, max: Double) {
        let s = frameTimes.sorted()
        guard !s.isEmpty else { return (0, 0, 0, 0) }
        return (s.count, s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)], s.last ?? 0)
    }

    func update(_ img: CIImage?) {
        image = img
        for v in views.allObjects where v.window != nil { v.setNeedsDisplay() }
    }
}

final class CanvasRenderer: NSObject, MTKViewDelegate {
    let model: CanvasModel
    var xform = ViewXform(canvas: .zero, image: .zero)
    /// Colour space the drawable is rendered in; switched together with the view's pixel format for HDR.
    var colorSpace: CGColorSpace = LumenGPU.displaySpace
    var hdrOn = false
    private var headroomTimer: Timer?
    private var lastHeadroom: (current: CGFloat, potential: CGFloat) = (1, 1)

    /// While HDR is on, checks the screen's EDR headroom about once a second (it follows brightness and ambient light).
    /// iPhones report a current headroom of 1 until something brighter than white is on screen, so the potential
    /// headroom is reported as well. `-lumenDemoHeadroom <x>` pretends to be an HDR screen (CI simulator).
    func trackHeadroom(_ on: Bool, view: MTKView) {
        headroomTimer?.invalidate()
        headroomTimer = nil
        guard on else {
            if lastHeadroom.current != 1 || lastHeadroom.potential != 1 {
                lastHeadroom = (1, 1)
                model.onHeadroom?(1, 1)
            }
            return
        }
        let forced = DemoMode.value("-lumenDemoHeadroom").flatMap(Double.init).map { CGFloat($0) }
        let check: (MTKView?) -> Void = { [weak self] v in
            guard let self else { return }
            let screen = v?.window?.windowScene?.screen ?? UIScreen.main
            let c = forced ?? max(screen.currentEDRHeadroom, 1)
            let p = forced ?? max(screen.potentialEDRHeadroom, 1)
            let moved = abs(c - self.lastHeadroom.current) / self.lastHeadroom.current > 0.05
                || abs(p - self.lastHeadroom.potential) / self.lastHeadroom.potential > 0.05
            if moved {
                self.lastHeadroom = (c, p)
                self.model.onHeadroom?(c, p)
            }
        }
        check(view)
        headroomTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak view] _ in check(view) }
    }

    deinit { headroomTimer?.invalidate() }

    init(model: CanvasModel) { self.model = model }

    /// The view changed size (a different tool's panel, the panel dragged, chrome hidden): draw again at the new
    /// size. Without this the last frame, drawn for the old size, stayed on screen stretched and out of place.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    /// Frames the GPU has not finished yet. A fast slider drag asks for a new frame on every finger movement; with
    /// heavy edits (Lens Blur) the GPU fell further and further behind until iOS closed the app (owner, 15 Oct).
    /// Now at most two frames are queued; a request that arrives meanwhile is drawn when one finishes, always with
    /// the newest edit, so nothing is lost and memory stays flat.
    private var inFlight = 0
    private var redrawWaiting = false

    func draw(in view: MTKView) {
        guard inFlight < 2 else { redrawWaiting = true; return }
        guard let queue = LumenGPU.queue, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        guard size.width > 1, size.height > 1 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        var out = CIImage(color: .black).cropped(to: bounds)
        // Place the photo for the size the view really has right now, so the frame is never distorted even if
        // SwiftUI's layout and the drawable are briefly out of step.
        var xf = xform
        if view.bounds.width > 1, view.bounds.height > 1 { xf.canvas = view.bounds.size }
        let r = xf.rect
        if DemoMode.isOn {
            DemoMode.log(String(format: "draw canvas %.0fx%.0f view %.0fx%.0f", xform.canvas.width, xform.canvas.height,
                                view.bounds.width, view.bounds.height))
        }
        if let img = model.image, r.width > 1, r.height > 1, !img.extent.isEmpty, !img.extent.isInfinite {
            let sf = size.width / max(view.bounds.width, 1)
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
            if DemoMode.isOn {
                DemoMode.log(String(format: "drew image %.0fx%.0f at y %.0f-%.0f", ext.width, ext.height,
                                    r.minY, r.minY + h / max(sf, 0.001)))
            }
            out = placed.composited(over: out)
        }
        let started = CACurrentMediaTime()
        LumenGPU.context.render(out, to: drawable.texture, commandBuffer: cb, bounds: bounds, colorSpace: colorSpace)
        cb.present(drawable)
        inFlight += 1
        let photoShown = model.image != nil
        cb.addCompletedHandler { [weak self, weak view] _ in
            let ms = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                if photoShown { self.model.recordFrame(ms) }
                self.inFlight -= 1
                if self.redrawWaiting { self.redrawWaiting = false; view?.setNeedsDisplay() }
            }
        }
        cb.commit()
    }
}

struct CanvasView: UIViewRepresentable {
    let model: CanvasModel
    let xform: ViewXform
    /// true = extended-range (EDR) drawable so highlights can go above paper white.
    var hdr: Bool = false

    /// Switches the view between today's 8-bit Display P3 drawable and a half-float extended-linear EDR one.
    static func configure(_ v: MTKView, renderer: CanvasRenderer, hdr: Bool) {
        let layer = v.layer as? CAMetalLayer
        if hdr {
            let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? LumenGPU.displaySpace
            v.colorPixelFormat = .rgba16Float
            layer?.wantsExtendedDynamicRangeContent = true
            layer?.colorspace = space
            renderer.colorSpace = space
        } else {
            v.colorPixelFormat = .bgra8Unorm
            layer?.wantsExtendedDynamicRangeContent = false
            layer?.colorspace = LumenGPU.displaySpace
            renderer.colorSpace = LumenGPU.displaySpace
        }
    }

    static func dismantleUIView(_ v: MTKView, coordinator: CanvasRenderer) {
        coordinator.trackHeadroom(false, view: v)
    }

    func makeCoordinator() -> CanvasRenderer { CanvasRenderer(model: model) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: LumenGPU.device)
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.isOpaque = true
        v.backgroundColor = .black
        // while the view is being resized keep the last frame unscaled and centred (it is redrawn straight after)
        v.contentMode = .center
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        CanvasView.configure(v, renderer: context.coordinator, hdr: hdr)
        context.coordinator.hdrOn = hdr
        context.coordinator.trackHeadroom(hdr, view: v)
        v.delegate = context.coordinator
        model.view = v
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        // The model must always point at the view on screen. Turning the phone rebuilds the layout: a view made and
        // thrown away along the way could leave the model with no view (it is weak), so edits rendered into nothing
        // until something else redrew the screen (owner's bug report 2026-10-11).
        model.view = v
        context.coordinator.xform = xform
        if context.coordinator.hdrOn != hdr {
            context.coordinator.hdrOn = hdr
            CanvasView.configure(v, renderer: context.coordinator, hdr: hdr)
            context.coordinator.trackHeadroom(hdr, view: v)
        }
        model.view = v
        v.setNeedsDisplay()
    }
}
