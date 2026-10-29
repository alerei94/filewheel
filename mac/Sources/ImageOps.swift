import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - Loading and saving pictures (ImageIO: built into macOS)

func imageType(for ext: String) -> UTType? {
    switch normalizeExt(ext) {
    case "jpg": return .jpeg
    case "png": return .png
    case "tiff": return .tiff
    case "gif": return .gif
    case "bmp": return .bmp
    case "heic": return .heic
    case "ico": return .ico
    default: return nil
    }
}

/// The picture with the camera's rotation applied, and its format ("jpg", "png"...).
func loadImage(_ url: URL) throws -> (image: CGImage, ext: String) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw ToolError("Could not read the picture “\(url.lastPathComponent)”.")
    }
    var ext = normalizeExt(url.pathExtension)
    if let typeId = CGImageSourceGetType(source) as String?, let type = UTType(typeId) {
        if type.conforms(to: .jpeg) { ext = "jpg" }
        else if type.conforms(to: .png) { ext = "png" }
        else if type.conforms(to: .heic) { ext = "heic" }
        else if type.conforms(to: .tiff) { ext = "tiff" }
        else if type.conforms(to: .gif) { ext = "gif" }
        else if type.conforms(to: .bmp) { ext = "bmp" }
    }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
    let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,          // applies the camera's rotation
        kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw ToolError("Could not read the picture “\(url.lastPathComponent)”.")
    }
    return (image, ext == "ico" ? "png" : ext)
}

func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: return true
    }
}

func makeContext(_ width: Int, _ height: Int) -> CGContext? {
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// The picture on a white background (JPEG and BMP can't be transparent).
func flattened(_ image: CGImage) -> CGImage {
    guard let ctx = makeContext(image.width, image.height) else { return image }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(rect)
    ctx.draw(image, in: rect)
    return ctx.makeImage() ?? image
}

func encodeImage(_ image: CGImage, ext: String, quality: Double = 0.9) throws -> Data {
    let e = normalizeExt(ext)
    guard let type = imageType(for: e) else { throw ToolError("Can't write .\(e) pictures.") }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        throw ToolError("This Mac can't write \(e.uppercased()) pictures.")
    }
    var props: [CFString: Any] = [:]
    if e == "jpg" || e == "heic" { props[kCGImageDestinationLossyCompressionQuality] = quality }
    var source = image
    if (e == "jpg" || e == "bmp") && hasAlpha(image) { source = flattened(image) }
    CGImageDestinationAddImage(dest, source, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) { throw ToolError("Could not write the picture.") }
    return data as Data
}

func saveImage(_ image: CGImage, ext: String, to url: URL, quality: Double = 0.92) throws {
    let data = try encodeImage(image, ext: ext, quality: quality)
    try data.write(to: url)
}

func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard let ctx = makeContext(width, height) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

// MARK: - Picture tools

func opCompressImages(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let level = o.string("level", "medium")
    let quality: Double = level == "low" ? 0.9 : (level == "high" ? 0.55 : 0.75)
    let maxSide = o.int("max_side", 0)
    var results: [URL] = []
    var notes: [String] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        var (image, ext) = try loadImage(file)
        if ext == "bmp" || ext == "tiff" || ext == "gif" { ext = hasAlpha(image) ? "png" : "jpg" }   // formats that can't be compressed as they are
        if maxSide > 0 && max(image.width, image.height) > maxSide {
            let scale = Double(maxSide) / Double(max(image.width, image.height))
            if let small = resized(image, width: max(1, Int(Double(image.width) * scale)), height: max(1, Int(Double(image.height) * scale))) {
                image = small
            }
        }
        let data = try encodeImage(image, ext: ext, quality: quality)
        let original = fileSize(file)
        let target = uniqueURL(destDir(out, file), stem(file) + "_compressed", ext)
        if Int64(data.count) >= original && maxSide == 0 {
            try FileManager.default.copyItem(at: file, to: target)
            notes.append("\(file.lastPathComponent): already small (\(humanSize(original)))")
        } else {
            try data.write(to: target)
            let saved = max(0, 100 - Int(Double(data.count) * 100 / Double(max(original, 1))))
            notes.append("\(file.lastPathComponent): \(humanSize(original)) to \(humanSize(Int64(data.count))) (-\(saved)%)")
        }
        results.append(target)
    }
    try progress(1, notes.joined(separator: "; "))
    return results
}

func opResizeImages(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let mode = o.string("mode", "percent")
    let percent = o.double("percent", 50)
    let width = o.int("width", 0)
    let height = o.int("height", 0)
    let noEnlarge = o.bool("no_enlarge", true)
    if (mode == "width" && width < 1) || (mode == "height" && height < 1) || (mode == "fit" && (width < 1 || height < 1)) {
        throw ToolError("Enter the size in pixels.")
    }
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let (image, ext) = try loadImage(file)
        let w = Double(image.width), h = Double(image.height)
        var scale: Double
        switch mode {
        case "percent": scale = percent / 100
        case "width": scale = Double(width) / w
        case "height": scale = Double(height) / h
        default: scale = min(Double(width) / w, Double(height) / h)
        }
        if noEnlarge { scale = min(scale, 1) }
        let newW = max(1, Int((w * scale).rounded())), newH = max(1, Int((h * scale).rounded()))
        let result = (newW == image.width && newH == image.height) ? image : (resized(image, width: newW, height: newH) ?? image)
        let target = uniqueURL(destDir(out, file), stem(file) + "_resized", ext)
        try saveImage(result, ext: ext, to: target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func opCropImages(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let mode = o.string("mode", "ratio")
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let (image, ext) = try loadImage(file)
        let w = image.width, h = image.height
        var box: CGRect
        if mode == "ratio" {
            let parts = o.string("ratio", "1:1").split(separator: ":").compactMap { Double($0) }
            let target = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 1
            var newW = Double(w), newH = Double(h)
            if Double(w) / Double(h) > target { newW = (Double(h) * target).rounded() } else { newH = (Double(w) / target).rounded() }
            var fx = 0.5, fy = 0.5
            switch o.string("anchor", "center") {
            case "top": fy = 0
            case "bottom": fy = 1
            case "left": fx = 0
            case "right": fx = 1
            default: break
            }
            box = CGRect(x: (Double(w) - newW) * fx, y: (Double(h) - newH) * fy, width: newW, height: newH)
        } else {
            let t = o.int("top"), r = o.int("right"), b = o.int("bottom"), l = o.int("left")
            if t == 0 && r == 0 && b == 0 && l == 0 { throw ToolError("Enter how many pixels to cut from at least one side.") }
            box = CGRect(x: l, y: t, width: w - l - r, height: h - t - b)
            if box.width < 1 || box.height < 1 { throw ToolError("“\(file.lastPathComponent)” would be left empty: use smaller margins.") }
        }
        guard let cropped = image.cropping(to: box.integral) else { throw ToolError("Could not crop “\(file.lastPathComponent)”.") }
        let target = uniqueURL(destDir(out, file), stem(file) + "_cropped", ext)
        try saveImage(cropped, ext: ext, to: target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func opRotateImages(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let angle = o.int("angle", 90)
    let flip = o.string("flip", "none")
    if angle == 0 && flip == "none" { throw ToolError("Choose a rotation or a flip.") }
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let (image, ext) = try loadImage(file)
        let turned = angle == 90 || angle == 270
        let newW = turned ? image.height : image.width
        let newH = turned ? image.width : image.height
        guard let ctx = makeContext(newW, newH) else { throw ToolError("Not enough memory for this picture.") }
        ctx.interpolationQuality = .high
        // draw the picture rotated clockwise (and mirrored if asked)
        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        ctx.rotate(by: -CGFloat(angle) * .pi / 180)
        ctx.scaleBy(x: flip == "horizontal" ? -1 : 1, y: flip == "vertical" ? -1 : 1)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let result = ctx.makeImage() else { throw ToolError("Could not rotate the picture.") }
        let target = uniqueURL(destDir(out, file), stem(file) + "_rotated", ext)
        try saveImage(result, ext: ext, to: target, quality: 0.95)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func convertTargets() -> [Choice] {
    return [Choice("jpg", "JPG"), Choice("png", "PNG"), Choice("tiff", "TIFF"), Choice("gif", "GIF"),
            Choice("bmp", "BMP"), Choice("heic", "HEIC"), Choice("ico", "ICO (icon)")]
}

func opConvertImages(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let target = normalizeExt(o.string("target", "jpg"))
    let quality = Double(max(1, min(100, o.int("quality", 90)))) / 100
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        var (image, _) = try loadImage(file)
        if target == "ico" && max(image.width, image.height) > 256 {
            let scale = 256.0 / Double(max(image.width, image.height))
            image = resized(image, width: max(1, Int(Double(image.width) * scale)), height: max(1, Int(Double(image.height) * scale))) ?? image
        }
        let url = uniqueURL(destDir(out, file), stem(file), target)
        try saveImage(image, ext: target, to: url, quality: quality)
        results.append(url)
    }
    try progress(1, "Done")
    return results
}

// MARK: - Drawing text on pictures

func withGraphics(_ ctx: CGContext, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func colorNamed(_ name: String) -> NSColor {
    switch name {
    case "black": return NSColor.black
    case "gray": return NSColor.gray
    case "red": return NSColor(calibratedRed: 0.86, green: 0.12, blue: 0.12, alpha: 1)
    case "blue": return NSColor(calibratedRed: 0.12, green: 0.27, blue: 0.82, alpha: 1)
    case "green": return NSColor(calibratedRed: 0.1, green: 0.55, blue: 0.25, alpha: 1)
    default: return NSColor.white
    }
}

let gridPositions: [String: (Double, Double)] = [
    "top left": (0, 1), "top center": (0.5, 1), "top right": (1, 1),
    "middle left": (0, 0.5), "center": (0.5, 0.5), "middle right": (1, 0.5),
    "bottom left": (0, 0), "bottom center": (0.5, 0), "bottom right": (1, 0),
]

func opWatermarkImages(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let text = o.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { throw ToolError("Enter the watermark text.") }
    let opacity = max(0.05, min(1, o.double("opacity", 60) / 100))
    let sizePct = max(1, o.double("size", 6))
    let angle = o.double("angle", 0)
    let color = colorNamed(o.string("color", "white")).withAlphaComponent(CGFloat(opacity))
    let grid = gridPositions[o.string("position", "bottom right")] ?? (1, 0)
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let (image, ext) = try loadImage(file)
        guard let ctx = makeContext(image.width, image.height) else { throw ToolError("Not enough memory for this picture.") }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let font = NSFont.boldSystemFont(ofSize: max(10, w * CGFloat(sizePct) / 100))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let margin = min(w, h) * 0.03
        let cx = margin + CGFloat(grid.0) * (w - 2 * margin - textSize.width) + textSize.width / 2
        let cy = margin + CGFloat(grid.1) * (h - 2 * margin - textSize.height) + textSize.height / 2
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: CGFloat(angle) * .pi / 180)
        withGraphics(ctx) {
            (text as NSString).draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2), withAttributes: attributes)
        }
        ctx.restoreGState()
        guard let result = ctx.makeImage() else { throw ToolError("Could not draw on the picture.") }
        let target = uniqueURL(destDir(out, file), stem(file) + "_watermarked", ext)
        try saveImage(result, ext: ext, to: target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

// MARK: - Removing the hidden data of photos

private func hasHiddenData(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
    return props[kCGImagePropertyGPSDictionary] != nil || props[kCGImagePropertyExifDictionary] != nil
        || props[kCGImagePropertyTIFFDictionary] != nil || props[kCGImagePropertyIPTCDictionary] != nil
}

private func orientationOf(_ url: URL) -> Int {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 1 }
    return (props[kCGImagePropertyOrientation] as? Int) ?? 1
}

/// Copies the picture without recompressing it and without its metadata. Returns false if the system refuses.
private func stripLossless(_ url: URL, to out: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
          let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return false }
    let options: [CFString: Any] = [
        kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
        kCGImageDestinationMergeMetadata: false,
        kCGImageMetadataShouldExcludeGPS: true,
        kCGImageMetadataShouldExcludeXMP: true,
    ]
    var error: Unmanaged<CFError>?
    return CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error)
}

func opStripMetadata(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    var notes: [String] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let ext = normalizeExt(file.pathExtension) == "jpeg" ? "jpg" : normalizeExt(file.pathExtension)
        let target = uniqueURL(destDir(out, file), stem(file) + "_clean", ext)
        var done = false
        if orientationOf(file) == 1 && stripLossless(file, to: target) && !hasHiddenData(target) {
            done = true
            notes.append("\(file.lastPathComponent): metadata removed, picture untouched")
        } else {
            try? FileManager.default.removeItem(at: target)
        }
        if !done {
            // turn the picture if the camera tag asked for it, then save it without any metadata
            let (image, realExt) = try loadImage(file)
            try saveImage(image, ext: realExt, to: target, quality: 0.95)
            notes.append("\(file.lastPathComponent): metadata removed (re-saved)")
        }
        results.append(target)
    }
    try progress(1, notes.joined(separator: "; "))
    return results
}
