import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Vision

/// Local adjustments: each Mask is rendered to an opaque grey image (white = fully affected),
/// the mask's own adjustments are applied to a copy of the picture, and the two are blended through the mask.
extension EditSession {
    func applyMasks(_ input: CIImage, _ s: EditSettings, scale: CGFloat) -> CIImage {
        var cur = input
        let ext = input.extent
        for m in s.masks where !m.adjust.isNeutral {
            let mask = maskImage(m, over: cur)
            let local = localAdjust(cur, m.adjust, scale: scale).cropped(to: ext)
            cur = local.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: cur,
                kCIInputMaskImageKey: mask,
            ])
        }
        return cur
    }

    /// Linear in, linear out.
    private func localAdjust(_ img: CIImage, _ a: LocalAdjust, scale: CGFloat) -> CIImage {
        var x = img
        if a.exposure != 0 { x = x.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        x = Self.temperatureTint(x, a.temperature, a.tint)
        x = Self.toGamma(x)
        x = Self.toneAdjust(x, blacks: 0, shadows: a.shadows, highlights: a.highlights, whites: 0)
        x = Self.colorControls(x, saturation: a.saturation, contrast: a.contrast)
        if a.clarity != 0 { x = Self.localContrast(x, radius: max(2, 40 * scale), amount: a.clarity / 100 * 0.8) }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = x
            f.sharpness = Float(a.sharpness / 100 * 1.5)
            f.radius = Float(max(0.6, 1.2 * scale))
            x = f.outputImage ?? x
        }
        return Self.toLinear(x)
    }

    // MARK: Mask images

    func maskImage(_ m: Mask, over base: CIImage) -> CIImage {
        let ext = base.extent
        var mask: CIImage
        switch m.kind {
        case .linear: mask = linearMask(m, ext)
        case .radial: mask = radialMask(m, ext)
        case .brush: mask = brushMask(m, ext)
        case .subject: mask = subjectMask(base, ext) ?? Self.constant(0, ext)
        case .background:
            let subject = subjectMask(base, ext) ?? Self.constant(0, ext)
            mask = subject.applyingFilter("CIColorInvert")
        case .luminance: mask = luminanceMask(m, base)
        case .color: mask = colorMask(m, base)
        }
        if m.invert { mask = mask.applyingFilter("CIColorInvert") }
        if m.amount < 100 {
            let k = m.amount / 100
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            ])
        }
        return mask.cropped(to: ext)
    }

    private static func constant(_ v: CGFloat, _ ext: CGRect) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: ext)
    }

    /// Normalised (top-left origin) point -> Core Image pixel coordinates.
    private static func pixel(_ x: Double, _ y: Double, _ ext: CGRect) -> CGPoint {
        CGPoint(x: ext.minX + CGFloat(x) * ext.width, y: ext.minY + CGFloat(1 - y) * ext.height)
    }

    /// Single-channel images come in as (v,0,0); copy red into all channels and make it opaque.
    private static func expandRed(_ i: CIImage) -> CIImage {
        let v = CIVector(x: 1, y: 0, z: 0, w: 0)
        return i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    private static func fit(_ img: CIImage, to ext: CGRect) -> CIImage {
        let e = img.extent
        return img
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: ext.width / e.width, y: ext.height / e.height))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
    }

    private func linearMask(_ m: Mask, _ ext: CGRect) -> CIImage {
        let p0 = Self.pixel(m.x0, m.y0, ext)
        let p1 = Self.pixel(m.x1, m.y1, ext)
        guard hypot(p1.x - p0.x, p1.y - p0.y) > 1 else { return Self.constant(1, ext) }
        let f = CIFilter.linearGradient()
        f.point0 = p0
        f.point1 = p1
        f.color0 = CIColor(red: 1, green: 1, blue: 1)
        f.color1 = CIColor(red: 0, green: 0, blue: 0)
        return (f.outputImage ?? Self.constant(0, ext)).cropped(to: ext)
    }

    private func radialMask(_ m: Mask, _ ext: CGRect) -> CIImage {
        let unit: CGFloat = 100
        let inner = max(0, 1 - m.feather / 100)
        let f = CIFilter.radialGradient()
        f.center = .zero
        f.radius0 = Float(inner * Double(unit))
        f.radius1 = Float(unit)
        f.color0 = CIColor(red: 1, green: 1, blue: 1)
        f.color1 = CIColor(red: 0, green: 0, blue: 0)
        guard let g = f.outputImage else { return Self.constant(0, ext) }
        let c = Self.pixel(m.x0, m.y0, ext)
        let rx = CGFloat(max(0.01, m.x1)) * ext.width / unit
        let ry = CGFloat(max(0.01, m.y1)) * ext.height / unit
        let t = CGAffineTransform(scaleX: rx, y: ry).concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        return g.transformed(by: t).cropped(to: ext)
    }

    private func brushMask(_ m: Mask, _ ext: CGRect) -> CIImage {
        let longSide = max(ext.width, ext.height)
        let mw = max(1, Int(1024 * ext.width / longSide))
        let mh = max(1, Int(1024 * ext.height / longSide))
        guard let ctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return Self.constant(0, ext) }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let side = CGFloat(max(mw, mh))
        func cg(_ p: Pt) -> CGPoint { CGPoint(x: CGFloat(p.x) * CGFloat(mw), y: CGFloat(1 - p.y) * CGFloat(mh)) }
        for st in m.strokes {
            guard let first = st.points.first else { continue }
            ctx.setStrokeColor(gray: st.erase ? 0 : 1, alpha: 1)
            ctx.setLineWidth(max(1, CGFloat(st.size) * side))
            ctx.beginPath()
            ctx.move(to: cg(first))
            ctx.addLine(to: cg(first))
            for p in st.points.dropFirst() { ctx.addLine(to: cg(p)) }
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return Self.constant(0, ext) }
        var ci = Self.expandRed(CIImage(cgImage: image, options: [.colorSpace: NSNull()]))
        let blurRadius = m.feather / 100 * 0.03 * Double(side)
        if blurRadius > 0.5 {
            let e = ci.extent
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = ci.clampedToExtent()
            blur.radius = Float(blurRadius)
            ci = blur.outputImage?.cropped(to: e) ?? ci
        }
        return Self.fit(ci, to: ext)
    }

    private func subjectMask(_ base: CIImage, _ ext: CGRect) -> CIImage? {
        if subjectCache == nil && !subjectTried {
            subjectTried = true
            subjectCache = computeSubjectMask(base)
        }
        guard let c = subjectCache else { return nil }
        return Self.fit(c, to: ext)
    }

    /// Apple's on-device foreground segmentation (Vision, iOS 17+).
    private func computeSubjectMask(_ base: CIImage) -> CIImage? {
        let e = base.extent
        let k = min(1, 1024 / max(e.width, e.height))
        let small = base.transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = Self.context.createCGImage(small, from: small.extent, format: .RGBA8,
                                                  colorSpace: Self.outputSpace) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first,
              let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        else { return nil }
        let ci = Self.expandRed(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ci.clampedToExtent()
        blur.radius = 1.5
        return blur.outputImage?.cropped(to: ci.extent) ?? ci
    }

    private func luminanceMask(_ m: Mask, _ base: CIImage) -> CIImage {
        let g = Self.toGamma(base)
        let sm = max(0.02, m.smooth)
        func luma(_ k: Double, _ b: Double) -> CIImage {
            let r = CIVector(x: 0.2126 * k, y: 0.7152 * k, z: 0.0722 * k, w: 0)
            return g.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": r, "inputGVector": r, "inputBVector": r,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 1),
            ]).applyingFilter("CIColorClamp")
        }
        let up = luma(1 / sm, -(m.lumLow - sm) / sm)
        let down = luma(-1 / sm, (m.lumHigh + sm) / sm)
        return up.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: down])
    }

    private func colorMask(_ m: Mask, _ base: CIImage) -> CIImage {
        let g = Self.toGamma(base)
        let shifted = g.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: -m.colorR, y: -m.colorG, z: -m.colorB, w: 0),
        ])
        let squared = shifted.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputGreenCoefficients": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputBlueCoefficients": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ])
        let t = max(0.03, m.tolerance)
        let k = -1 / (t * t)
        let v = CIVector(x: k, y: k, z: k, w: 0)
        return squared.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]).applyingFilter("CIColorClamp")
    }
}
