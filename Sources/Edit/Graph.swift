import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Builds the lazy Core Image graph for a set of edits. Nothing is rendered here, so this is cheap to call per slider tick.
extension EditSession {
    /// How Lens Blur is drawn: `.full` (export, thumbnails, the settled preview), `.preview` (half resolution while a
    /// Lens Blur slider is moving, so fast drags can't pile up heavy GPU work) or `.off` (the histogram: blur barely
    /// changes the tones, and skipping it removes most of the work while sliding).
    enum LensQuality { case full, preview, off }

    func develop(_ edits: EditSettings, source: ImageSource, geometry: Bool, applyCrop: Bool = true, hdrWeight: Double = 0,
                 lens: LensQuality = .full) -> CIImage {
        // sections switched off in the Edits sheet render as if untouched
        let s = edits.effective
        guard let k = LumenKernels.shared else { return source.base }
        let ext = source.extent
        let E = source.longEdge

        func v(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> CIVector { CIVector(x: x, y: y, z: z, w: w) }
        let g0 = v(s.exposure, s.contrast / 100, s.highlights / 100, s.shadows / 100)
        let g1 = v(s.whites / 100, s.blacks / 100, s.temperature / 100, s.tint / 100)
        let g2 = v(s.blackAndWhite ? 0 : s.vibrance / 100, s.blackAndWhite ? 0 : s.saturation / 100,
                   s.texture / 100, s.clarity / 100)
        let g3 = v(s.dehaze / 100, s.sharpness / 100 * 0.9, s.sharpenMasking / 100, s.noiseReduction / 100)
        let g4 = v(s.colorNoise / 100, s.brightness / 100, 0, 0)
        let g6 = v(Double(source.air.x), Double(source.air.y), Double(source.air.z), Double(source.darkNorm))

        var args: [Any] = [source.base, source.l1, source.l2, source.chroma]
        var kernel = k.main
        if let planes = localPlanes(s, source: source) {
            args += planes
            kernel = k.mainLocal
        }
        args += [g0, g1, g2, g3, g4, g6]
        var img = kernel.apply(extent: ext, arguments: args) ?? source.base

        // HDR: the same develop maths, but only the highlight gain (>= 1) is kept; applied again after the look LUT.
        var gainImg: CIImage?
        if s.hdr, hdrWeight > 0, let gk = (kernel === k.mainLocal ? k.gainLocal : k.gain), k.applyGain != nil {
            let gh = v(exp2(s.hdrStops), 0, 0, 0)
            gainImg = gk.apply(extent: ext, arguments: args + [gh])
        }
        // A missing HDR blur kernel shows an SDR preview; it must not reuse an unblurred or independently
        // blurred gain field. Export reports the unavailable HDR path explicitly below.
        if lens != .off, s.lensBlur.amount > 0, k.hdrBlurGain == nil || k.applyRGBGain == nil { gainImg = nil }

        var channelGain = false
        if lens != .off {
            let scale = lens == .preview ? 0.5 : 1
            let unblurred = img
            img = applyLensBlur(img, settings: s, source: source, scale: scale)
            if s.lensBlur.amount > 0, let gi = gainImg, let apply = k.applyGain,
               let ratio = k.hdrBlurGain, k.applyRGBGain != nil,
               let radiance = apply.apply(extent: ext, arguments: [unblurred, gi, v(1, 0, 0, 0)]) {
                // Average the light, not its correlated SDR and gain fields separately. RGB ratios retain
                // differently coloured point lights. The existing output look is still applied to SDR first.
                let blurredHDR = applyLensBlur(radiance, settings: s, source: source, scale: scale)
                gainImg = ratio.apply(extent: ext, arguments: [blurredHDR, img, v(exp2(s.hdrStops), s.blackAndWhite ? 1 : 0, 0, 0)])
                channelGain = gainImg != nil
            }
        }

        if geometry {
            img = self.geometry(img, s, applyCrop: applyCrop)
            if let gi = gainImg { gainImg = self.geometry(gi, s, applyCrop: applyCrop) }
        }

        // Vignette, grain and the output curve.
        let fe = img.extent
        let lookNeutral = s.curves.isNeutral && s.hsl.isNeutral && s.grading.isNeutral && !s.blackAndWhite
        let cell = (0.5 + s.grainSize / 100 * 2.5) * E / 2000
        let f0 = v(s.vignette / 100, s.vignetteMidpoint / 100, s.vignetteFeather / 100, s.vignetteRoundness / 100)
        let f1 = v(Double(fe.width), Double(fe.height), s.grain / 100, cell)
        let f2 = v(s.grainRoughness / 100, lookNeutral ? 0 : 1, 7, 0)
        img = k.finish.apply(extent: fe, arguments: [img, f0, f1, f2]) ?? img

        if !lookNeutral, let data = lookCube(s) {
            let f = CIFilter(name: "CIColorCube")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(ColorCube.dim, forKey: "inputCubeDimension")
            f.setValue(data, forKey: "inputCubeData")
            if let out = f.outputImage {
                img = k.toLinear.apply(extent: fe, arguments: [out]) ?? out
            }
        }
        if let gi = gainImg, let ag = channelGain ? k.applyRGBGain : k.applyGain {
            img = ag.apply(extent: img.extent, arguments: [img, gi, v(min(max(hdrWeight, 0), 1), 0, 0, 0)]) ?? img
        }
        return img
    }

    // MARK: Lens Blur

    /// With no segmented subject the sampled focus plane itself must stay sharp. A detected object instead
    /// supplies its own exact silhouette; retain the existing gradual depth ramp around that object.
    func lensFocusEdge(_ blur: LensBlurSettings, source: ImageSource) -> Double {
        source.cachedMask(Self.subjectKey(blur.subjectPoint)) == nil
            ? max(blur.rampStart, min(max(blur.focusDistance, 0), 1)) : blur.rampStart
    }

    /// One initializer shared by the editor and rendering tests. This is a selection, not a second blur ramp.
    /// The linked renderer maps its unchanged selection back to the exact automatic radius before painting.
    func initialLensRefinement(_ blur: LensBlurSettings, source: ImageSource) -> Mask {
        var mask = Mask.make(.depth)
        mask.name = "Lens Blur background"
        mask.components[0].lumLow = blur.fullFrom
        mask.components[0].lumHigh = 1
        mask.components[0].lumLowFeather = max(blur.fullFrom - lensFocusEdge(blur, source: source), 0)
        mask.components[0].lumHighFeather = 0
        if lensFocusEdge(blur, source: source) >= 0.999 { mask.components[0].amount = 0 }
        var subject = MaskComponent.make(.subject, op: .subtract)
        subject.subjectPoint = blur.subjectPoint
        mask.components.append(subject)
        return mask
    }

    /// Uses only cached analysis; prepareAutoMasks performs the model work off the UI thread.
    func lensBlurMask(_ settings: EditSettings, source: ImageSource) -> CIImage? {
        let s = settings.effective
        let blur = s.lensBlur
        guard blur.amount > 0 else { return nil }
        if let id = blur.maskID, let mask = s.masks.first(where: { $0.id == id }) {
            if mask.amount <= 0 { return Self.constant(0, source.extent) }
            if mask.components.contains(where: { $0.kind == .depth && $0.amount > 0 }),
               source.cachedMask(Self.aiDepth) == nil { return nil }
            guard let selection = maskImage(mask, source: source, gain: exp2(s.exposure)) else { return nil }
            if mask.components.contains(where: { $0.kind == .depth && $0.amount > 0 }),
               let depth = source.cachedMask(Self.aiDepth), let kernel = LumenKernels.shared?.lensRefinedRamp {
                let baselineComponent = initialLensRefinement(blur, source: source).components[0]
                let baseline = componentImage(baselineComponent, source: source, gain: exp2(s.exposure))
                return kernel.apply(extent: source.extent,
                                    arguments: [depth, selection, baseline,
                                                CIVector(x: lensFocusEdge(blur, source: source), y: 0, z: 0, w: 0)])
            }
            return selection
        }
        guard let depth = source.cachedMask(Self.aiDepth), let kernel = LumenKernels.shared?.lensRamp else { return nil }
        let subject = source.cachedMask(Self.subjectKey(blur.subjectPoint)) ?? Self.constant(0, source.extent)
        return kernel.apply(extent: source.extent,
                            arguments: [depth, subject, CIVector(x: lensFocusEdge(blur, source: source), y: 0, z: 0, w: 0)])
    }

    func applyLensBlur(_ input: CIImage, settings: EditSettings, source: ImageSource, scale: Double = 1) -> CIImage {
        let s = settings.effective
        guard s.lensBlur.amount > 0 else { return input }
        if let id = s.lensBlur.maskID, let editable = s.masks.first(where: { $0.id == id }) {
            guard editable.amount > 0 else { return input }
        } else {
            guard lensFocusEdge(s.lensBlur, source: source) < 0.999 else { return input }
        }
        // A no-op must bypass Core Image's colour conversions, not just blend with a black mask.
        guard let mask = lensBlurMask(s, source: source) else { return input }
        let radius = min(max(settings.effective.lensBlur.amount, 0), 100) / 100 * Double(source.longEdge) * LensBlurSettings.radiusScale
        guard radius > 0 else { return input }
        return Self.maskedLensBlur(input, mask: mask, radius: radius, scale: scale)
    }

    /// Radius scales with source pixels, so preview, detail and export show the same apparent blur.
    /// Lens-like: round (disc) blur, so bright points become soft circles as with a real lens, and only the
    /// background feeds it, so the subject's colour does not glow into the blurred area around its edges.
    /// Three blur layers are mixed by the blur map, which keeps the blur growing with distance.
    /// `scale` < 1 blurs a smaller copy and scales the blurred layers back up (live preview while sliding); the sharp
    /// photo and the blur map stay full size, so the subject never goes soft.
    static func maskedLensBlur(_ input: CIImage, mask: CIImage, radius: Double, scale: Double = 1) -> CIImage {
        let extent = input.extent
        if let k = LumenKernels.shared, let weigh = k.lensWeigh, let compose = k.lensCompose,
           CIFilter(name: "CIBokehBlur") != nil {
            let m = mask.cropped(to: extent)
            guard var weighted = weigh.apply(extent: extent, arguments: [input.clampedToExtent(), m.clampedToExtent()])
            else { return smoothLensBlur(input, mask: mask, radius: radius) }
            let sc = min(max(scale, 0.25), 1)
            let down = CGAffineTransform(translationX: -extent.minX, y: -extent.minY).scaledBy(x: sc, y: sc)
            if sc < 1 { weighted = weighted.cropped(to: extent).transformed(by: down) }
            let small = sc < 1 ? weighted.extent : extent
            // a disc looks about as strong as a smooth blur of ~0.6x its radius: keep the familiar strength
            // (capped: a huge disc on a big photo only costs memory, it doesn't look any different)
            let disc = min(radius * 1.6 * sc, 200)
            let layers = [disc / 3, disc * 2 / 3, disc].map { r -> CIImage in
                var layer = weighted.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [
                    kCIInputRadiusKey: max(r, 0.5), "inputRingAmount": 0, "inputRingSize": 0.1, "inputSoftness": 1.0
                ]).cropped(to: small)
                if sc < 1 { layer = layer.clampedToExtent().transformed(by: down.inverted()).cropped(to: extent) }
                return layer
            }
            if let out = compose.apply(extent: extent, arguments: [input, m] + layers) { return out.cropped(to: extent) }
        }
        return smoothLensBlur(input, mask: mask, radius: radius)
    }

    /// The first Lens Blur (smooth, Gaussian-like): the fallback when the lens-like kernels are unavailable.
    static func smoothLensBlur(_ input: CIImage, mask: CIImage, radius: Double) -> CIImage {
        let extent = input.extent
        let filter = CIFilter(name: "CIMaskedVariableBlur")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(mask.cropped(to: extent).clampedToExtent(), forKey: "inputMask")
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = filter?.outputImage?.cropped(to: extent) else { return input }
        return blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input, "inputMaskImage": mask.cropped(to: extent)
        ]).cropped(to: extent)
    }

    // MARK: Geometry

    /// 90° turns, straighten, then crop to the frame (fractions of the largest rectangle that fits inside the rotated picture).
    /// `applyCrop: false` keeps the whole straightened picture, which is what the crop editor shows.
    func geometry(_ input: CIImage, _ s: EditSettings, applyCrop: Bool = true) -> CIImage {
        var img = input
        // Transform (perspective, aspect, scale, offset): the photo's corners move, the frame stays the same size
        if let q = Homography.corners(s) {
            let e = img.extent
            func pt(_ p: Pt) -> CIVector { CIVector(x: e.minX + CGFloat(p.x) * e.width, y: e.minY + CGFloat(1 - p.y) * e.height) }
            img = img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": pt(q[0]), "inputTopRight": pt(q[1]),
                "inputBottomRight": pt(q[2]), "inputBottomLeft": pt(q[3]),
            ])
            // keep the full frame when the photo is made smaller (cropping alone would shrink the extent to the photo)
            img = img.composited(over: CIImage(color: .clear).cropped(to: e)).cropped(to: e)
        }
        // Flip (mirror) about the centre
        if s.flipH || s.flipV {
            let e = img.extent
            img = img.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(CGAffineTransform(scaleX: s.flipH ? -1 : 1, y: s.flipV ? -1 : 1))
                .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY)))
        }
        let turns = ((s.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            img = Self.rotateAboutCenter(img, by: -CGFloat(turns) * .pi / 2)
            img = Self.normalized(img)
        }
        let w = img.extent.width, h = img.extent.height
        let theta = CGFloat(abs(s.straighten)) * .pi / 180
        let kfit = 1 / (cos(theta) + sin(theta) * max(w / h, h / w))
        img = Self.rotateAboutCenter(img, by: -CGFloat(s.straighten) * .pi / 180) // original centre is now the origin

        if s.cropVersion != nil {
            // the crop is a share of the whole turned picture, kept on real photo by CropFit (the Crop tool shows it all)
            let u = applyCrop ? s.cropUsed(source: input.extent.size) : CropRect.full
            let rect = CGRect(x: -w / 2 + CGFloat(u.l) * w, y: -h / 2 + CGFloat(1 - u.b) * h,
                              width: CGFloat(u.w) * w, height: CGFloat(u.h) * h).integral
            return Self.normalized(img.cropped(to: rect))
        }

        let w0 = w * kfit, h0 = h * kfit
        var l = 0.0, t = 0.0, r = 1.0, b = 1.0
        if applyCrop {
            l = min(max(s.cropL, 0), 0.95); t = min(max(s.cropT, 0), 0.95)
            r = min(max(s.cropR, l + 0.04), 1); b = min(max(s.cropB, t + 0.04), 1)
        }
        let rect = CGRect(x: -w0 / 2 + CGFloat(l) * w0, y: -h0 / 2 + CGFloat(1 - b) * h0,
                          width: CGFloat(r - l) * w0, height: CGFloat(b - t) * h0).integral
        return Self.normalized(img.cropped(to: rect))
    }

    static func rotateAboutCenter(_ img: CIImage, by angle: CGFloat) -> CIImage {
        let e = img.extent
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(rotationAngle: angle))
        return img.transformed(by: t)
    }

    // MARK: Output

    /// Small renders for thumbnails and presets. Automatic (AI) masks are skipped.
    func renderCGImage(_ s: EditSettings, maxEdge: CGFloat, prepareAutomaticMasks: Bool = true) -> CGImage? {
        heals = s.effective.heals
        denoiseAmount = s.effective.aiDenoise / 100   // uses the cleaned copy if it has been made (thumbnails don't make it)
        // small renders are kept in a buffer (a few MB): the AI masks Lens Blur needs are worked out on it without
        // re-running the RAW engine for each step (21 Oct review)
        guard let src = makeSource(maxEdge: maxEdge, materialize: maxEdge <= 1024) else { return nil }
        // Lens Blur's masks are worked out for thumbnails (on the small source); other AI masks show once the photo
        // has been opened (21 Oct: working them all out for every thumbnail loaded the phone, and the CI simulator
        // enough to cut a UI test's drag short)
        if prepareAutomaticMasks && s.effective.lensBlur.amount > 0 { prepareAutoMasks(s, source: src) }
        return renderCGImage(prepareAutomaticMasks ? s : ThumbnailFiles.basicRecipe(s), source: src)
    }

    /// A thumbnail from a source that is already decoded (the editor's preview): the photo is not decoded again, and the AI
    /// masks the editor has worked out show on it (quality checklist A13; before, a thumbnail was a fresh RAW decode,
    /// ~2 GB at its peak on a 48 MP photo, and showed none of the AI masks).
    func renderThumbnail(_ s: EditSettings, source: ImageSource, maxEdge: CGFloat) -> CGImage? {
        var img = develop(s, source: source, geometry: true)
        let e = img.extent
        let k = min(1, maxEdge / max(e.width, e.height))
        if k < 1 { img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0]) }
        return ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
    }

    func renderCGImage(_ s: EditSettings, source: ImageSource, geometry: Bool = true) -> CGImage? {
        let img = develop(s, source: source, geometry: geometry)
        return ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
    }

    /// Why an export could not be made (quality checklist A17: before this, every failure read as one
    /// unhelpful "Export failed").
    enum ExportFailure: Equatable {
        /// AI Denoise is on but the cleaned copy could not be made (model not here, iCloud restore, damaged file).
        case denoiseMissing
        /// Saved Heal/Remove People edits refer to pixels that are missing or cannot be read.
        case healMissing
        /// The photo could not be decoded (file missing, iCloud not downloaded, damaged).
        case decode
        /// Lens Blur is on but its focus map could not be prepared (depth model absent or failed).
        case depthUnavailable
        /// An automatic selection required by the active edits failed or could not be prepared.
        case automaticMaskUnavailable
        /// The image rendered but could not be encoded to the chosen format.
        case encode
        /// An HDR file was requested: never quietly substitute an SDR rendition if gain-map encoding fails.
        case hdrEncode

        var message: String {
            switch self {
            case .denoiseMissing:
                return "AI Denoise has to clean this photo again before it can be exported (about a minute; the cleaned copy is not kept in backups). Open it, tap AI Denoise in Detail, then export. Or switch AI Denoise off."
            case .healMissing:
                return "A saved Heal fix couldn't be read, so this photo wasn't exported. Reopen the photo and try again, or switch Heal off to export without the fixes."
            case .decode:
                return "The photo could not be read (the file may be missing)."
            case .depthUnavailable:
                return "Lens Blur can't be exported because the depth information couldn't be prepared. Turn Lens Blur off, or reopen the photo and try again."
            case .automaticMaskUnavailable:
                return "An automatic mask couldn't be prepared, so this photo wasn't exported. Open Masks and try again, or switch off the affected mask adjustment."
            case .encode:
                return "The photo could not be written. Try a different format or a smaller size."
            case .hdrEncode:
                return "The HDR photo could not be written. Try a smaller size, or switch HDR off in Export to save an SDR photo."
            }
        }
    }

    enum ExportOutcome {
        case data(Data)
        case failed(ExportFailure)
    }

    /// Export. `quality` 0...1 (JPEG/HEIC), `maxEdge` = long edge in pixels (nil = full size), `includeHDR` adds the
    /// HDR gain map when the photo is edited in HDR. Returns `nil` on failure (the engine tests and the memory
    /// baseline use this); for a user-facing reason, call `renderDataResult`.
    func renderData(_ s: EditSettings, format: ExportFormat, quality: Double, maxEdge: CGFloat? = nil,
                    includeHDR: Bool = true) -> Data? {
        switch renderDataOutcome(s, format: format, quality: quality, maxEdge: maxEdge, includeHDR: includeHDR) {
        case .data(let d): return d
        case .failed: return nil
        }
    }

    /// `allowClean`: make the cleaned copy here when AI Denoise is on and it is missing (the engine tests do). The app does
    /// not: a clean is 1-2 minutes inside an export with no progress and no Cancel (quality checklist A16), so it asks the
    /// user to clean the photo first (`.denoiseMissing`).
    func renderDataOutcome(_ s: EditSettings, format: ExportFormat, quality: Double, maxEdge: CGFloat? = nil,
                           includeHDR: Bool = true, allowClean: Bool = true) -> ExportOutcome {
        heals = s.effective.heals
        let patches = HealStore.retain(Set(heals.map(\.id)))
        defer { patches.close() }
        guard HealStore.unavailable(heals, owner: originalURL).isEmpty else { return .failed(.healMissing) }
        denoiseAmount = s.effective.aiDenoise / 100
        // an export must show the AI Denoise it was asked for: make the cleaned copy now if it isn't there yet
        if denoiseAmount > 0, !hasDenoised {
            guard allowClean, Self.hasDenoiseModel else { return .failed(.denoiseMissing) }
            let ok = makeDenoised() == .done
            Self.releaseDenoiseFallback()
            // never quietly export without the AI Denoise that was asked for
            guard ok else { return .failed(.denoiseMissing) }
        }
        // (Decoding into a buffer first was tried on 19 Oct: same peak, ~1.8 GB more kept afterwards.)
        guard let src = makeSource(maxEdge: nil, materialize: false) else { return .failed(.decode) }
        Self.healProbe?("export: full-size source ready")
        // AI masks are worked out on a 2560 px copy and scaled up, like the editor's preview (at full size the masks'
        // filters and models each re-ran the RAW engine: 21 Oct review for 48 MP; 22 Oct diagnostics showed every 24 MP
        // batch export doing it too); what is still missing is done at full size
        let needsAI = !Self.requiredExportMaskKeys(s).isEmpty
        let small = needsAI && max(nativeSize.width, nativeSize.height) > 2700
            ? makeSource(maxEdge: 2560, materialize: true) : nil
        if let failure = prepareExportMasks(s, source: src, preview: small) { return .failed(failure) }
        Self.healProbe?("export: masks ready")
        // Never quietly export an unblurred photo when a requested focus map could not be prepared.
        if s.effective.lensBlur.amount > 0 && lensBlurMask(s, source: src) == nil { return .failed(.depthUnavailable) }
        var img = develop(s, source: src, geometry: true)
        let q: [CIImageRepresentationOption: Any] = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        // HDR: the SDR rendition is the base image; the gain-map options need iOS 18 / macOS 15.
        let wantHDR = includeHDR && s.hdr && format != .tiff
        if wantHDR && (LumenKernels.shared?.applyGain == nil || LumenKernels.shared?.gain == nil || LumenKernels.shared?.gainLocal == nil) {
            return .failed(.hdrEncode)
        }
        if wantHDR && s.effective.lensBlur.amount > 0 &&
            (LumenKernels.shared?.hdrBlurGain == nil || LumenKernels.shared?.applyRGBGain == nil) {
            return .failed(.hdrEncode)
        }
        var hdrImg: CIImage? = wantHDR ? develop(s, source: src, geometry: true, hdrWeight: 1) : nil
        // smaller sizes are made from the full-size result, so they are as sharp as they can be
        let long = max(img.extent.width, img.extent.height)
        if let m = maxEdge, m > 0, long > m {
            let k = m / long
            img = Self.downscaled(img, k)
            hdrImg = hdrImg.map { Self.downscaled($0, k) }
        }
        // the camera's details go with the photo (Core Image writes an image's properties into the file): date taken,
        // camera, lens, exposure, GPS. Before 19 Oct exports had none, so Photos dated them the day they were exported.
        let meta = exportMetadata()
        img = img.settingProperties(meta)
        hdrImg = hdrImg.map { $0.settingProperties(meta) }
        Self.healProbe?("export: graphs built")
        defer { Self.healProbe?("export: encoded") }
        // Export renders a one-off full-size graph (twice for SDR + HDR gain-map encoding). The caching context
        // can retain its RAW/Heal/filter intermediates beside the encoder; use the same colour/precision options
        // with intermediate caching disabled. Resolution, HDR data and failure handling remain unchanged.
        let outputContext = LumenGPU.drawContext
        // Render both renditions here and wait for the GPU before encoding. The one-call encoders swallow a failed GPU
        // render and still write a file: on 29 Oct (memory-export run 40794138432) the CI Mac's GPU ran out of memory in
        // the first of three exports after a large Heal and that file's HDR gain map came out solid white, while the
        // check passed. A render task reports the failure, so caches are freed and the render tried once more; if it
        // fails again the export fails instead of writing a wrong photo.
        // The HDR rendition keeps its content headroom: the encoder limits the gain map to it (0...+0.64 stops for the
        // test photo). Without it the first version of this change let specular sparkles reach +3.5 stops.
        func rendered(_ i: CIImage, hdr: Bool) -> CIImage? {
            let format: CIFormat = hdr ? .RGBAh : .RGBA8
            let space = hdr ? LumenGPU.workingSpace : LumenGPU.displaySpace
            var headroom: Float?
            if hdr, #available(iOS 18.0, macOS 15.0, *), i.contentHeadroom > 0 { headroom = i.contentHeadroom }
            if let r = Self.renderedChecked(i, context: outputContext, format: format, bytesPerPixel: hdr ? 8 : 4,
                                            colorSpace: space, headroom: headroom) {
                return r.settingProperties(meta)
            }
            Self.healProbe?("export: GPU render failed, freeing caches and trying again")
            outputContext.clearCaches()
            LumenGPU.context.clearCaches()
            return Self.renderedChecked(i, context: outputContext, format: format, bytesPerPixel: hdr ? 8 : 4,
                                        colorSpace: space, headroom: headroom)?.settingProperties(meta)
        }
        guard let readyImg = rendered(img, hdr: false) else { return .failed(wantHDR ? .hdrEncode : .encode) }
        img = readyImg
        if let h = hdrImg {
            guard let readyHDR = rendered(h, hdr: true) else { return .failed(.hdrEncode) }
            hdrImg = readyHDR
        }
        Self.healProbe?("export: rendered")
        switch format {
        case .jpeg:
            if let hdrImg {
                if #available(iOS 18.0, macOS 15.0, *) {
                    var o = q
                    o[.hdrImage] = hdrImg
                    if let d = try? outputContext.jpegRepresentation(of: img, colorSpace: LumenGPU.displaySpace, options: o) { return .data(d) }
                }
                return .failed(.hdrEncode)
            }
            if let d = try? outputContext.jpegRepresentation(of: img, colorSpace: LumenGPU.displaySpace, options: q) { return .data(d) }
            return .failed(.encode)
        case .heic:
            if let hdrImg {
                if #available(iOS 18.0, macOS 15.0, *) {
                    var o = q
                    o[.hdrImage] = hdrImg
                    if let d = try? outputContext.heifRepresentation(of: img, format: .RGBA8, colorSpace: LumenGPU.displaySpace, options: o) { return .data(d) }
                } else if let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
                          let d = try? outputContext.heif10Representation(of: hdrImg, colorSpace: hlg, options: q) {
                    return .data(d)
                }
                return .failed(.hdrEncode)
            }
            if let d = try? outputContext.heifRepresentation(of: img, format: .RGBA8, colorSpace: LumenGPU.displaySpace, options: q) { return .data(d) }
            return .failed(.encode)
        case .tiff:
            if let d = try? outputContext.tiffRepresentation(of: img, format: .RGBA16, colorSpace: LumenGPU.displaySpace, options: [:]) { return .data(d) }
            return .failed(.encode)
        }
    }

    /// Renders `img` into its own bitmap and waits for the GPU; nil when the render reports an error (for example the
    /// GPU running out of memory), which `createCGImage` and the image encoders never report. The bitmap's first row
    /// is the image's top row, as with `createCGImage` (engine test "checked render keeps orientation").
    static func renderedChecked(_ img: CIImage, context: CIContext, format: CIFormat, bytesPerPixel: Int,
                                colorSpace: CGColorSpace, headroom: Float? = nil) -> CIImage? {
        let e = img.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0, e.width.isFinite, e.height.isFinite else { return nil }
        // An HDR rendition goes into a pixel buffer, the only bitmap image that can carry its content headroom.
        if let headroom, format == .RGBAh, #available(iOS 18.0, macOS 15.0, *) {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attributes, &buffer) == kCVReturnSuccess,
                  let buffer else { return nil }
            let destination = CIRenderDestination(pixelBuffer: buffer)
            destination.colorSpace = colorSpace
            do {
                let task = try context.startTask(toRender: img, from: e, to: destination, at: .zero)
                _ = try task.waitUntilCompleted()
            } catch {
                return nil
            }
            return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace, .contentHeadroom: headroom])
        }
        let rowBytes = w * bytesPerPixel
        var data = Data(count: rowBytes * h)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            let destination = CIRenderDestination(bitmapData: base, width: w, height: h, bytesPerRow: rowBytes, format: format)
            destination.colorSpace = colorSpace
            do {
                let task = try context.startTask(toRender: img, from: e, to: destination, at: .zero)
                _ = try task.waitUntilCompleted()
                return true
            } catch {
                return false
            }
        }
        guard ok else { return nil }
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: e.size, format: format, colorSpace: colorSpace)
    }

    /// Only selections that can affect the output are required. Successful empty detections remain valid;
    /// a failed optional Scene assist must not reject a Sky mask successfully made by the fallback finder.
    static func requiredExportMaskKeys(_ edits: EditSettings) -> Set<String> {
        let s = edits.effective
        var keys: Set<String> = []
        let linked = s.lensBlur.amount > 0 ? s.lensBlur.maskID : nil
        for mask in s.masks where mask.amount > 0 && (!mask.adjust.isNeutral || mask.id == linked) {
            for c in mask.components where c.amount > 0 {
                if let key = automaticMaskKey(c) { keys.insert(key) }
            }
        }
        if s.lensBlur.amount > 0 && !s.masks.contains(where: { $0.id == linked }) {
            keys.insert(aiDepth); keys.insert(subjectKey(s.lensBlur.subjectPoint))
        }
        return keys
    }

    /// Shared by real export and deterministic failure fixtures; seeded outcomes need no model inference.
    /// The small-source hand-off preserves errors as well as valid empty/results, so it cannot hide failure.
    func prepareExportMasks(_ edits: EditSettings, source: ImageSource, preview: ImageSource? = nil) -> ExportFailure? {
        let required = Self.requiredExportMaskKeys(edits)
        guard !required.isEmpty else { return nil }
        var s = edits.effective
        let linked = s.lensBlur.amount > 0 ? s.lensBlur.maskID : nil
        s.masks = s.masks.filter { $0.amount > 0 && (!$0.adjust.isNeutral || $0.id == linked) }
        for i in s.masks.indices { s.masks[i].components.removeAll { $0.amount <= 0 } }
        if let preview {
            prepareAutoMasks(s, source: preview)
            source.restoreMasks(preview.snapshotMasks(), scaleX: source.size.width / preview.size.width,
                                scaleY: source.size.height / preview.size.height)
            source.storeDepth(preview.depthField); source.storeScene(preview.sceneField)
        }
        prepareAutoMasks(s, source: source)
        let state = source.snapshotMasks()
        // Depth is a required measurement, unlike a detector legitimately finding no subject/people/sky.
        let missingDepth = required.contains(Self.aiDepth) && state.masks[Self.aiDepth] == nil
        if s.lensBlur.amount > 0, required.contains(Self.aiDepth),
           missingDepth || !state.tried.contains(Self.aiDepth) || state.failures.contains(Self.aiDepth) {
            return .depthUnavailable
        }
        if missingDepth || required.contains(where: { !state.tried.contains($0) || state.failures.contains($0) }) {
            return .automaticMaskUnavailable
        }
        return nil
    }

    /// The original file's EXIF / TIFF / GPS / IPTC details, for an exported file. Orientation is dropped (the pixels
    /// are already turned), and so are sizes, colour and maker notes, which describe the original's pixels.
    func exportMetadata() -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary] as [CFString] {
            if var d = props[key as String] as? [String: Any] {
                if key == kCGImagePropertyExifDictionary {
                    for k in [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifMakerNote,
                              kCGImagePropertyExifColorSpace, kCGImagePropertyExifSubjectArea] as [CFString] { d[k as String] = nil }
                }
                out[key as String] = d
            }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            for k in [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                      kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFCompression,
                      kCGImagePropertyTIFFPhotometricInterpretation] as [CFString] { tiff[k as String] = nil }
            tiff[kCGImagePropertyTIFFSoftware as String] = "Lumen"
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        out[kCGImagePropertyOrientation as String] = 1
        return out
    }

    static func downscaled(_ img: CIImage, _ k: CGFloat) -> CIImage {
        let s = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
        return s.cropped(to: CGRect(x: 0, y: 0, width: floor(s.extent.width), height: floor(s.extent.height)))
    }
}

/// The photo as stored (the source: masks, brush strokes and colour picks live here) versus the photo as shown after
/// 90° turns, straighten and crop (the output). Same maths as `EditSession.geometry`, so mask handles drawn through
/// it sit exactly on the rendered mask. Normalised coordinates are 0...1 with y down on both sides.
/// A projective map between two quadrilaterals, in normalised photo coordinates (0...1, y down).
struct Homography: Equatable {
    var m: [Double]   // row-major 3 x 3

    /// Where the photo's corners go for a transform (TL, TR, BR, BL), or nil when there is no transform.
    static func corners(_ s: EditSettings) -> [Pt]? {
        guard s.hasTransform else { return nil }
        let kv = s.tVertical / 100 * 0.25, kh = s.tHorizontal / 100 * 0.25
        let a = s.tAspect / 100
        let sx = (a > 0 ? 1 + a * 0.5 : 1) * s.tScale / 100
        let sy = (a < 0 ? 1 - a * 0.5 : 1) * s.tScale / 100
        let ox = s.tOffX / 100 * 0.5, oy = -s.tOffY / 100 * 0.5
        // centred corner positions: Vertical widens the top (narrows the bottom), Horizontal heightens the left side
        let c: [(Double, Double)] = [(-0.5 * (1 + kv), -0.5 * (1 + kh)), (0.5 * (1 + kv), -0.5 * (1 - kh)),
                                     (0.5 * (1 - kv), 0.5 * (1 - kh)), (-0.5 * (1 - kv), 0.5 * (1 + kh))]
        func quad(_ k: Double) -> [Pt] { c.map { Pt(x: 0.5 + $0.0 * sx * k + ox, y: 0.5 + $0.1 * sy * k + oy) } }
        // crop version 2 keeps the crop on photo instead (CropFit); only older edits zoom the perspective here
        guard s.tFill, s.cropVersion == nil else { return quad(1) }
        // Fill frame: the smallest extra zoom (about the centre) at which the photo covers the whole frame,
        // i.e. every frame corner lands inside the transformed photo
        func covers(_ k: Double) -> Bool {
            let inv = squareTo(quad(k)).inverse
            return [Pt(x: 0, y: 0), Pt(x: 1, y: 0), Pt(x: 1, y: 1), Pt(x: 0, y: 1)].allSatisfy {
                let q = inv.apply($0)
                return q.x >= -1e-4 && q.x <= 1 + 1e-4 && q.y >= -1e-4 && q.y <= 1 + 1e-4
            }
        }
        if covers(1) { return quad(1) }
        var lo = 1.0, hi = 1.5
        while !covers(hi) && hi < 8 { lo = hi; hi *= 1.5 }
        guard covers(hi) else { return quad(1) }
        for _ in 0..<30 { let mid = (lo + hi) / 2; if covers(mid) { hi = mid } else { lo = mid } }
        return quad(hi)
    }

    /// The unit square's corners (0,0), (1,0), (1,1), (0,1) -> q[0...3] (Heckbert).
    static func squareTo(_ q: [Pt]) -> Homography {
        let x0 = q[0].x, y0 = q[0].y, x1 = q[1].x, y1 = q[1].y, x2 = q[2].x, y2 = q[2].y, x3 = q[3].x, y3 = q[3].y
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        var g = 0.0, h = 0.0
        if abs(sx) > 1e-12 || abs(sy) > 1e-12 {
            let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
            let den = dx1 * dy2 - dx2 * dy1
            g = (sx * dy2 - dx2 * sy) / den
            h = (dx1 * sy - sx * dy1) / den
        }
        return Homography(m: [x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
                              y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
                              g, h, 1])
    }

    func apply(_ p: Pt) -> Pt {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        guard abs(w) > 1e-12 else { return p }
        return Pt(x: (m[0] * p.x + m[1] * p.y + m[2]) / w, y: (m[3] * p.x + m[4] * p.y + m[5]) / w)
    }

    var inverse: Homography {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-15 else { return self }
        let k = 1 / det
        return Homography(m: [A * k, -(b * i - c * h) * k, (b * f - c * e) * k,
                              B * k, (a * i - c * g) * k, -(a * f - c * d) * k,
                              C * k, -(a * h - b * g) * k, (a * e - b * d) * k])
    }
}

struct SourceGeometry: Equatable {
    var source: CGSize
    var turns = 0
    var straighten = 0.0
    /// Transform (photo -> photo, normalised) and flips, applied before the turns
    var warp: Homography?
    var flipH = false
    var flipV = false
    /// crop fractions of the straightened picture: x = left, y = top, width = right - left, height = bottom - top
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Older edits (no crop version): the crop is a share of the largest same-shaped rectangle inside the straightened picture.
    var shareOfInscribed = false

    init(source: CGSize, settings s: EditSettings, applyCrop: Bool = true) {
        self.source = source
        turns = ((s.quarterTurns % 4) + 4) % 4
        straighten = s.straighten
        warp = Homography.corners(s).map { Homography.squareTo($0) }
        flipH = s.flipH
        flipV = s.flipV
        shareOfInscribed = s.cropVersion == nil
        if applyCrop && !shareOfInscribed {
            let u = s.cropUsed(source: source)
            crop = CGRect(x: u.l, y: u.t, width: u.w, height: u.h)
        } else if applyCrop {
            // the same limits EditSession.geometry applies
            let l = min(max(s.cropL, 0), 0.95), t = min(max(s.cropT, 0), 0.95)
            let r = min(max(s.cropR, l + 0.04), 1), b = min(max(s.cropB, t + 0.04), 1)
            crop = CGRect(x: l, y: t, width: r - l, height: b - t)
        }
    }

    /// Pictures turned on their side swap width and height.
    private var turned: CGSize { turns % 2 == 0 ? source : CGSize(width: source.height, height: source.width) }
    /// The largest rectangle with the picture's shape that fits inside it once straightened.
    private var inscribed: CGSize {
        let w = turned.width, h = turned.height
        guard w > 0, h > 0 else { return .zero }
        guard shareOfInscribed else { return turned }
        let th = CGFloat(abs(straighten)) * .pi / 180
        let k = 1 / (cos(th) + sin(th) * max(w / h, h / w))
        return CGSize(width: w * k, height: h * k)
    }
    /// Output size in source pixels.
    var output: CGSize { CGSize(width: inscribed.width * crop.width, height: inscribed.height * crop.height) }
    /// How far the source is turned on screen, clockwise, in degrees.
    var clockwise: Double { Double(turns) * 90 + straighten }
    /// A single flip mirrors angles (a radial turned clockwise in the source shows turned anticlockwise).
    var mirrored: Bool { flipH != flipV }

    /// Source pixels (Core Image, y up, origin bottom left) -> output pixels (same convention).
    private var forward: CGAffineTransform {
        let i = inscribed
        let ox = -i.width / 2 + crop.minX * i.width
        let oy = -i.height / 2 + (1 - crop.maxY) * i.height
        return CGAffineTransform(translationX: -source.width / 2, y: -source.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2 - CGFloat(straighten) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: -ox, y: -oy))
    }

    /// Source -> the photo after transform and flip (still source-sized, normalised).
    private func pre(_ p: Pt) -> Pt {
        var q = warp?.apply(p) ?? p
        if flipH { q.x = 1 - q.x }
        if flipV { q.y = 1 - q.y }
        return q
    }

    private func unpre(_ p: Pt) -> Pt {
        var q = p
        if flipH { q.x = 1 - q.x }
        if flipV { q.y = 1 - q.y }
        return warp?.inverse.apply(q) ?? q
    }

    func toOutput(_ src: Pt) -> Pt {
        let o = output
        guard o.width > 0, o.height > 0 else { return src }
        let p = pre(src)
        let q = CGPoint(x: CGFloat(p.x) * source.width, y: (1 - CGFloat(p.y)) * source.height).applying(forward)
        return Pt(x: Double(q.x / o.width), y: Double(1 - q.y / o.height))
    }

    func toSource(_ p: Pt) -> Pt {
        let o = output
        guard o.width > 0, o.height > 0, source.width > 0, source.height > 0 else { return p }
        let q = CGPoint(x: CGFloat(p.x) * o.width, y: (1 - CGFloat(p.y)) * o.height).applying(forward.inverted())
        return unpre(Pt(x: Double(q.x / source.width), y: Double(1 - q.y / source.height)))
    }
}

extension EditSettings {
    /// The part of the crop frame that is photo (see `CropFit`), for a photo of `source` size before any geometry.
    func cropRegion(source: CGSize) -> [CropFit.P] {
        CropFit.region(source: (Double(source.width), Double(source.height)), turns: quarterTurns, flipH: flipH, flipV: flipV,
                       straighten: straighten, warp: Homography.corners(self)?.map { ($0.x, $0.y) })
    }

    /// The crop frame used (fractions of the turned picture): the one asked for, kept on photo while Keep inside the photo
    /// (`tFill`) is on, 1.5 px inside its edge so a turned or warped picture's soft edge never shows.
    func cropUsed(source: CGSize) -> CropRect {
        let l = min(max(cropL, 0), 0.95), t = min(max(cropT, 0), 0.95)
        let asked = CropRect(l: l, t: t, r: min(max(cropR, l + 0.04), 1), b: min(max(cropB, t + 0.04), 1))
        guard tFill, source.width > 0, source.height > 0 else { return asked }
        let sideways = ((quarterTurns % 2) + 2) % 2 == 1
        let fw = Double(sideways ? source.height : source.width), fh = Double(sideways ? source.width : source.height)
        return CropFit.fit(asked, in: cropRegion(source: source), margin: (1.5 / fw, 1.5 / fh))
    }

    /// Settings from before crop version 2, converted so the same part of the photo stays framed.
    func withUpgradedCrop(source: CGSize) -> EditSettings {
        guard cropVersion == nil, source.width > 0, source.height > 0 else { return self }
        var s = self
        let sideways = ((quarterTurns % 2) + 2) % 2 == 1
        let frame = (w: Double(sideways ? source.height : source.width), h: Double(sideways ? source.width : source.height))
        // how much Fill frame zoomed the perspective (the corners with and without it)
        var zoom = 1.0
        if let a = Homography.corners(self) {
            var plain = self; plain.tFill = false
            if let b = Homography.corners(plain) {
                let da = hypot(a[2].x - a[0].x, a[2].y - a[0].y), db = hypot(b[2].x - b[0].x, b[2].y - b[0].y)
                if db > 1e-9 { zoom = da / db }
            }
        }
        let r = CropFit.upgraded(CropRect(l: cropL, t: cropT, r: cropR, b: cropB), frame: frame, straighten: straighten, fillZoom: zoom)
        s.cropL = r.l; s.cropT = r.t; s.cropR = r.r; s.cropB = r.b
        s.cropVersion = 2
        return s
    }
}
