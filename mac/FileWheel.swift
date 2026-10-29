import AppKit
import AVFoundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Categories and formats

enum Category {
    case image, audio, video, document, pdf

    var title: String {
        switch self {
        case .image: return "Immagine"
        case .audio: return "Audio"
        case .video: return "Video"
        case .document: return "Documento"
        case .pdf: return "PDF"
        }
    }

    var icon: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .document: return "doc.text"
        case .pdf: return "doc.richtext"
        }
    }

    static func detect(_ ext: String) -> Category? {
        let e = ext.lowercased()
        if ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp", "jp2"].contains(e) { return .image }
        if ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac", "ogg", "opus", "wma"].contains(e) { return .audio }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp", "flv", "wmv"].contains(e) { return .video }
        if ["txt", "md", "rtf", "html", "htm", "doc", "docx", "odt"].contains(e) { return .document }
        if e == "pdf" { return .pdf }
        return nil
    }
}

enum Tools {
    /// ffmpeg is optional: when present, it unlocks many more audio/video formats.
    static let ffmpeg: String? = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Maps equivalent extensions to a single form (jpeg→jpg, tif→tiff, ...).
    static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif":  return "tiff"
        case "aif":  return "aiff"
        case "htm":  return "html"
        case let e:  return e
        }
    }

    /// Picks the most sensible target format among the available ones.
    /// If the user already chose a format for that category, it is reused.
    static func smartTarget(for category: Category, source: String) -> String {
        let options = targets(for: category)
        var src = source.lowercased()
        if src == "jpeg" { src = "jpg" }

        if let saved = UserDefaults.standard.string(forKey: "last_\(category.title)"),
           options.contains(saved), saved != src {
            return saved
        }

        let preferred: [String]
        switch category {
        case .image:    preferred = src == "jpg" ? ["png"] : ["jpg", "png"]
        case .audio:    preferred = src == "mp3" ? ["m4a", "wav"] : ["mp3", "m4a"]
        case .video:    preferred = src == "mp4" ? ["mp3", "m4a"] : ["mp4"]
        case .document: preferred = ["pdf"]
        case .pdf:      preferred = ["png", "txt"]
        }
        if let match = preferred.first(where: { options.contains($0) && $0 != src }) { return match }
        return options.first(where: { $0 != src }) ?? options[0]
    }

    /// Half of the cores: keeps the Mac responsive during heavy conversions.
    static let cpuThreads = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)

    static func targets(for category: Category) -> [String] {
        let ff = ffmpeg != nil
        switch category {
        case .image:    return ["png", "jpg", "heic", "tiff", "gif", "bmp", "pdf"] + (ff ? ["webp"] : [])
        case .audio:    return ["m4a", "wav", "aiff", "caf", "flac"] + (ff ? ["mp3", "ogg", "opus"] : [])
        case .video:    return ["mp4", "mov", "m4v", "m4a"] + (ff ? ["mkv", "webm", "gif", "mp3"] : [])
        case .document: return ["pdf", "docx", "doc", "odt", "rtf", "html", "txt"]
        case .pdf:      return ["txt", "png", "jpg"]
        }
    }
}

struct ConvError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Conversion engine

enum Converter {
    static func convert(input: URL, ext: String, category: Category, outputDir: URL) async throws -> URL {
        // Low priority: the Mac stays smooth while converting
        try await Task.detached(priority: .utility) {
            try await Converter.convertInternal(input: input, ext: ext, category: category, outputDir: outputDir)
        }.value
    }

    static func convertInternal(input: URL, ext: String, category: Category, outputDir: URL) async throws -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        if category == .pdf {
            return try await Task.detached(priority: .utility) { try pdfConvert(input, outputDir, base, ext) }.value
        }
        let output = uniqueURL(dir: outputDir, base: base, ext: ext)
        switch category {
        case .image:    try await image(input, output, ext)
        case .audio:    try await audio(input, output, ext)
        case .video:    try await video(input, output, ext)
        case .document: try await document(input, output, ext)
        case .pdf:      break
        }
        return output
    }

    static func uniqueURL(dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    // MARK: External processes

    static func runProcess(_ path: String, _ args: [String]) async throws {
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? errHandle.close()
            try? FileManager.default.removeItem(at: errURL)
        }

        let status: Int32 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.qualityOfService = .utility
            p.standardError = errHandle
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }

        if status != 0 {
            let text = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConvError(message: trimmed.isEmpty ? "Conversion failed (code \(status))" : String(trimmed.suffix(300)))
        }
    }

    // MARK: Images

    static func image(_ input: URL, _ output: URL, _ ext: String) async throws {
        if ext == "pdf" {
            guard let img = NSImage(contentsOf: input), let page = PDFPage(image: img) else {
                throw ConvError(message: "Unreadable image")
            }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            if !doc.write(to: output) { throw ConvError(message: "Could not write the PDF") }
            return
        }
        if ext == "webp" {
            guard let ff = Tools.ffmpeg else { throw ConvError(message: "WebP requires ffmpeg (brew install ffmpeg)") }
            try await runProcess(ff, ["-y", "-loglevel", "error", "-i", input.path, output.path])
            return
        }
        try await Task.detached(priority: .utility) { try Converter.imageIO(input, output, ext) }.value
    }

    static func imageIO(_ input: URL, _ output: URL, _ ext: String) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ConvError(message: "Could not read the image")
        }
        let type: UTType
        switch ext {
        case "png":  type = .png
        case "jpg":  type = .jpeg
        case "heic": type = .heic
        case "tiff": type = .tiff
        case "gif":  type = .gif
        case "bmp":  type = .bmp
        default: throw ConvError(message: "Unsupported format: \(ext)")
        }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvError(message: "Output format not supported on this Mac")
        }

        var options: [CFString: Any] = [:]
        if ext == "jpg" || ext == "heic" { options[kCGImageDestinationLossyCompressionQuality] = 0.9 }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let hasAlpha = (props?[kCGImagePropertyHasAlpha] as? Bool) ?? false

        // JPEG and BMP don't support transparency: flatten onto a white background.
        if hasAlpha && (ext == "jpg" || ext == "bmp"), let flat = flattenedOnWhite(src, props) {
            CGImageDestinationAddImage(dest, flat, options as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, src, 0, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw ConvError(message: "Could not write the image")
        }
    }

    static func flattenedOnWhite(_ src: CGImageSource, _ props: [CFString: Any]?) -> CGImage? {
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h)
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let ctx = CGContext(data: nil, width: img.width, height: img.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage()
    }

    // MARK: Audio

    static func audio(_ input: URL, _ output: URL, _ ext: String) async throws {
        if let ff = Tools.ffmpeg {
            try await runProcess(ff, ["-y", "-loglevel", "error", "-i", input.path, "-vn", output.path])
            return
        }
        let format: [String]
        switch ext {
        case "m4a":  format = ["-f", "m4af", "-d", "aac"]
        case "wav":  format = ["-f", "WAVE", "-d", "LEI16"]
        case "aiff": format = ["-f", "AIFF", "-d", "BEI16"]
        case "caf":  format = ["-f", "caff", "-d", "LEI16"]
        case "flac": format = ["-f", "flac", "-d", "flac"]
        default: throw ConvError(message: "\(ext.uppercased()) requires ffmpeg (brew install ffmpeg)")
        }
        try await runProcess("/usr/bin/afconvert", format + [input.path, output.path])
    }

    // MARK: Video

    static func video(_ input: URL, _ output: URL, _ ext: String) async throws {
        if let ff = Tools.ffmpeg {
            let threads = String(Tools.cpuThreads)
            var args = ["-y", "-loglevel", "error", "-threads", threads, "-i", input.path]
            switch ext {
            case "mp3", "m4a": args += ["-vn"]
            case "gif": args += ["-vf", "fps=12,scale=640:-1:flags=lanczos"]
            case "mp4", "mov", "m4v", "mkv": args += ["-preset", "veryfast"]
            default: break
            }
            args += ["-threads", threads]
            args.append(output.path)
            try await runProcess(ff, args)
            return
        }

        let preset: String
        let fileType: AVFileType
        switch ext {
        case "mp4": preset = AVAssetExportPresetHighestQuality; fileType = .mp4
        case "mov": preset = AVAssetExportPresetHighestQuality; fileType = .mov
        case "m4v": preset = AVAssetExportPresetHighestQuality; fileType = .m4v
        case "m4a": preset = AVAssetExportPresetAppleM4A; fileType = .m4a
        default: throw ConvError(message: "\(ext.uppercased()) requires ffmpeg (brew install ffmpeg)")
        }
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvError(message: "Source video is not natively supported (install ffmpeg)")
        }
        session.outputURL = output
        session.outputFileType = fileType
        await session.export()
        if session.status != .completed {
            throw ConvError(message: session.error?.localizedDescription ?? "Video export failed")
        }
    }

    // MARK: Documents

    static func document(_ input: URL, _ output: URL, _ ext: String) async throws {
        if ext == "pdf" {
            try await MainActor.run { try Converter.documentToPDF(input, output) }
            return
        }
        try await runProcess("/usr/bin/textutil", ["-convert", ext, "-output", output.path, input.path])
    }

    @MainActor
    static func documentToPDF(_ input: URL, _ output: URL) throws {
        let ext = input.pathExtension.lowercased()
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if ext == "txt" || ext == "md" {
            opts[.documentType] = NSAttributedString.DocumentType.plain
            opts[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        let attr = try NSAttributedString(url: input, options: opts, documentAttributes: nil)

        let pageW: CGFloat = 595, pageH: CGFloat = 842, margin: CGFloat = 50
        let width = pageW - margin * 2

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: pageW, height: pageH)
        info.leftMargin = margin
        info.rightMargin = margin
        info.topMargin = margin
        info.bottomMargin = margin
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: width, height: 0)
        tv.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = .zero
        tv.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(attr)
        if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }
        tv.sizeToFit()

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() || !FileManager.default.fileExists(atPath: output.path) {
            throw ConvError(message: "PDF creation failed")
        }
    }

    // MARK: PDF → text / images

    static func pdfConvert(_ input: URL, _ dir: URL, _ base: String, _ ext: String) throws -> URL {
        guard let doc = PDFDocument(url: input) else {
            throw ConvError(message: "Unreadable PDF (it may be password-protected)")
        }
        if ext == "txt" {
            let out = uniqueURL(dir: dir, base: base, ext: "txt")
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        }

        var last: URL?
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let img = page.thumbnail(of: NSSize(width: b.width * scale, height: b.height * scale), for: .mediaBox)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
            let data: Data?
            if ext == "png" {
                data = rep.representation(using: .png, properties: [:])
            } else {
                data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }
            guard let bytes = data else { continue }
            let name = doc.pageCount > 1 ? "\(base)_page\(i + 1)" : base
            let out = uniqueURL(dir: dir, base: name, ext: ext)
            try bytes.write(to: out)
            last = out
        }
        guard let result = last else { throw ConvError(message: "No pages were converted") }
        return result
    }
}

// MARK: - Dragged files and available formats

struct DraggedFile {
    let url: URL
    let category: Category
}

struct FormatOption {
    let ext: String
    let count: Int
}

enum Options {
    static func files(from urls: [URL]) -> [DraggedFile] {
        var result: [DraggedFile] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let cat = Category.detect(url.pathExtension) else { continue }
            result.append(DraggedFile(url: url, category: cat))
        }
        return result
    }

    static func suggested(for files: [DraggedFile]) -> String? {
        guard let first = files.first else { return nil }
        return Tools.smartTarget(for: first.category, source: first.url.pathExtension)
    }

    /// Formats that at least one file can be converted to (the recommended one sits at the top of the wheel).
    static func formats(for files: [DraggedFile]) -> [FormatOption] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for f in files {
            let src = Tools.normalized(f.url.pathExtension)
            for ext in Tools.targets(for: f.category) where ext != src {
                if counts[ext] == nil { order.append(ext) }
                counts[ext, default: 0] += 1
            }
        }
        var result = order.map { FormatOption(ext: $0, count: counts[$0] ?? 0) }
        if let s = suggested(for: files), let i = result.firstIndex(where: { $0.ext == s }) {
            let option = result.remove(at: i)
            result.insert(option, at: 0)
        }
        return Array(result.prefix(12))
    }
}

// MARK: - The wheel (hand-drawn: extremely light)

enum WheelPhase {
    case choosing
    case working(done: Int, total: Int)
    case finished(success: Bool, message: String)
}

final class WheelView: NSView {
    static let bubble: CGFloat = 46
    static let captionHeight: CGFloat = 30

    var options: [FormatOption] = []
    var fileCount = 1
    var title = ""
    var iconName = "doc"
    var suggested: String? = nil
    var hovered: Int? = nil
    var phase: WheelPhase = .choosing
    var openProgress: CGFloat = 1

    var onChoose: ((String, [URL]?) -> Void)?
    var onDismiss: (() -> Void)?
    var onReveal: (() -> Void)?

    private var animTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Geometry

    static func radius(count: Int) -> CGFloat {
        max(92, CGFloat(count) * 54 / (2 * CGFloat.pi))
    }

    static func panelSize(count: Int) -> NSSize {
        let side = 2 * (radius(count: count) + bubble / 2 + 16)
        return NSSize(width: side, height: side + captionHeight)
    }

    private var wheelCenter: NSPoint {
        NSPoint(x: bounds.midX, y: bounds.midY + WheelView.captionHeight / 2)
    }

    private func bubbleCenter(_ i: Int) -> NSPoint {
        let n = max(options.count, 1)
        let angle = CGFloat.pi / 2 - 2 * CGFloat.pi * CGFloat(i) / CGFloat(n)
        let c = wheelCenter
        let r = WheelView.radius(count: options.count)
        return NSPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
    }

    private func bubbleIndex(at point: NSPoint) -> Int? {
        guard case .choosing = phase else { return nil }
        let hit = WheelView.bubble / 2 + 10
        var best: Int? = nil
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in options.indices {
            let bc = bubbleCenter(i)
            let d = hypot(bc.x - point.x, bc.y - point.y)
            if d < hit && d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    // MARK: Configuration and opening animation

    func configure(options: [FormatOption], files: [DraggedFile], suggested: String?) {
        self.options = options
        self.fileCount = files.count
        self.suggested = suggested
        self.hovered = nil
        self.phase = .choosing
        self.iconName = files.count == 1 ? (files.first?.category.icon ?? "doc") : "doc.on.doc.fill"
        self.title = files.count == 1 ? (files.first?.url.lastPathComponent ?? "") : "\(files.count) files"
    }

    func reset() {
        animTimer?.invalidate()
        animTimer = nil
        hovered = nil
        phase = .choosing
        options = []
    }

    /// Short animation (about a quarter of a second): then the timer stops and uses nothing.
    func startOpening() {
        animTimer?.invalidate()
        openProgress = 0
        needsDisplay = true
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let x = min(1.0, (ProcessInfo.processInfo.systemUptime - start) / 0.24)
                self.openProgress = CGFloat(1 - pow(1 - x, 3))
                self.needsDisplay = true
                if x >= 1 {
                    self.animTimer?.invalidate()
                    self.animTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    // MARK: Drawing

    private func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    private func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ]
        let h = (s as NSString).size(withAttributes: attrs).height
        let r = NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        (s as NSString).draw(in: r, withAttributes: attrs)
    }

    private func drawSymbol(_ name: String, color: NSColor, center: NSPoint, size: CGFloat) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = base.withSymbolConfiguration(cfg) ?? base
        let s = img.size
        img.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    }

    private var caption: String {
        switch phase {
        case .choosing:
            if let h = hovered, h < options.count { return "Convert to \(options[h].ext.uppercased())" }
            return title
        case .working:
            return "Converting…"
        case .finished(_, let message):
            return message
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = wheelCenter
        let r = WheelView.radius(count: options.count)
        let p = openProgress

        // Background disc
        let discR = (r + WheelView.bubble / 2 + 10) * (0.55 + 0.45 * p)
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))
        NSColor.windowBackgroundColor.withAlphaComponent(0.90 * p).setFill()
        disc.fill()
        NSColor.separatorColor.withAlphaComponent(p).setStroke()
        disc.lineWidth = 1
        disc.stroke()

        // Star rays
        for i in options.indices {
            let bc = bubbleCenter(i)
            let tip = NSPoint(x: c.x + (bc.x - c.x) * p, y: c.y + (bc.y - c.y) * p)
            let ray = NSBezierPath()
            ray.move(to: c)
            ray.line(to: tip)
            ray.lineWidth = 1.5
            NSColor.controlAccentColor.withAlphaComponent(0.25 * p).setStroke()
            ray.stroke()
        }

        // Format bubbles
        for (i, option) in options.enumerated() {
            let bc = bubbleCenter(i)
            let pos = NSPoint(x: c.x + (bc.x - c.x) * p, y: c.y + (bc.y - c.y) * p)
            let isHover = hovered == i
            let d = WheelView.bubble * (isHover ? 1.25 : 1) * (0.4 + 0.6 * p)
            let rect = NSRect(x: pos.x - d / 2, y: pos.y - d / 2, width: d, height: d)
            let path = NSBezierPath(ovalIn: rect)

            if isHover {
                NSColor.controlAccentColor.withAlphaComponent(p).setFill()
            } else {
                NSColor.controlAccentColor.withAlphaComponent(0.15 * p).setFill()
            }
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent((isHover ? 1 : 0.55) * p).setStroke()
            path.lineWidth = option.ext == suggested ? 2.5 : 1
            path.stroke()

            drawText(option.ext.uppercased(), in: rect,
                     font: roundedFont(12, .bold),
                     color: (isHover ? NSColor.white : NSColor.labelColor).withAlphaComponent(p))

            if option.ext == suggested {
                drawText("★", in: NSRect(x: rect.maxX - 12, y: rect.maxY - 12, width: 14, height: 14),
                         font: NSFont.systemFont(ofSize: 11), color: NSColor.systemYellow.withAlphaComponent(p))
            }
            if option.count < fileCount {
                drawText("\(option.count)", in: NSRect(x: rect.maxX - 12, y: rect.minY - 2, width: 14, height: 14),
                         font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         color: NSColor.secondaryLabelColor.withAlphaComponent(p))
            }
        }

        // Center: the file
        let cr: CGFloat = 34
        let center = NSBezierPath(ovalIn: NSRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2))
        NSColor.controlBackgroundColor.setFill()
        center.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        center.lineWidth = 2
        center.stroke()

        switch phase {
        case .choosing:
            drawSymbol(iconName, color: NSColor.controlAccentColor, center: c, size: 26)
        case .working(let done, let total):
            let frac = total == 0 ? 0 : CGFloat(done) / CGFloat(total)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: c, radius: cr - 3, startAngle: 90,
                           endAngle: 90 - 360 * max(frac, 0.05), clockwise: true)
            ring.lineWidth = 4
            ring.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
            drawText("\(done)/\(total)", in: NSRect(x: c.x - 24, y: c.y - 9, width: 48, height: 18),
                     font: roundedFont(12, .semibold), color: NSColor.labelColor)
        case .finished(let success, _):
            drawSymbol(success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                       color: success ? NSColor.systemGreen : NSColor.systemOrange, center: c, size: 30)
        }

        // Caption
        let pill = NSRect(x: 10, y: 4, width: bounds.width - 20, height: 22)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
        drawText(caption, in: pill.insetBy(dx: 8, dy: 0), font: NSFont.systemFont(ofSize: 12),
                 color: NSColor.secondaryLabelColor)
    }

    // MARK: Dropping the file on the wheel

    private func updateHover(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let idx = bubbleIndex(at: point)
        if idx != hovered {
            hovered = idx
            needsDisplay = true
        }
        return idx == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if hovered != nil {
            hovered = nil
            needsDisplay = true
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovered != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idx = hovered, idx < options.count else { return false }
        let ext = options[idx].ext
        hovered = nil
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        onChoose?(ext, urls.isEmpty ? nil : urls)
        return true
    }

    // MARK: Click usage (when opened from "Convert files…")

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let idx = bubbleIndex(at: convert(event.locationInWindow, from: nil))
        if idx != hovered {
            hovered = idx
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil {
            hovered = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .choosing:
            if let idx = bubbleIndex(at: point) {
                onChoose?(options[idx].ext, nil)
            } else {
                onDismiss?()
            }
        case .finished:
            onReveal?()
        case .working:
            break
        }
    }
}

// MARK: - Menu bar app

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let panel: NSPanel
    private let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: 300, height: 330))
    private var statusItem: NSStatusItem?
    private let dragPB = NSPasteboard(name: .drag)

    private var baseline = 0
    private var files: [DraggedFile] = []
    private var lastOutputs: [URL] = []
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var visible = false
    private var fixedMode = false
    private var busy = false

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 330),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = wheel

        wheel.onChoose = { [weak self] ext, urls in self?.choose(ext: ext, urls: urls) }
        wheel.onDismiss = { [weak self] in self?.hide() }
        wheel.onReveal = { [weak self] in self?.revealOutputs() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        installMonitors()
        showIntroIfNeeded()
    }

    // MARK: Drag detection (system-wide)

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            Task { @MainActor in self?.handleMouseDown() }
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            // Very fast check: proceed only if Shift is held
            guard NSEvent.modifierFlags.contains(.shift) else { return }
            Task { @MainActor in self?.handleMouseDragged() }
        }) {
            monitors.append(m)
        }
    }

    private func handleMouseDown() {
        baseline = dragPB.changeCount
        if visible && fixedMode, case .choosing = wheel.phase {
            hide()
        }
    }

    private func handleMouseDragged() {
        guard !visible, !busy else { return }
        let change = dragPB.changeCount
        guard change != baseline else { return }   // no file drag in progress

        let urls = (dragPB.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let found = Options.files(from: urls)
        if found.isEmpty {
            baseline = change                       // not convertible files: don't check again
            return
        }
        show(files: found, at: NSEvent.mouseLocation, fixed: false)
    }

    // MARK: Showing / hiding the wheel

    private func show(files: [DraggedFile], at point: NSPoint, fixed: Bool) {
        let options = Options.formats(for: files)
        guard !options.isEmpty else { return }

        self.files = files
        fixedMode = fixed
        wheel.configure(options: options, files: files, suggested: Options.suggested(for: files))

        let size = WheelView.panelSize(count: options.count)
        var origin = NSPoint(x: point.x - size.width / 2,
                             y: point.y - size.height / 2 - WheelView.captionHeight / 2)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - size.width - 4)
            origin.y = min(max(origin.y, vis.minY + 4), vis.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        wheel.frame = NSRect(origin: .zero, size: size)
        wheel.startOpening()
        panel.orderFrontRegardless()
        visible = true
        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTick() }
        }
    }

    /// While the mouse button is down the drag is in progress; when you release it the wheel disappears.
    private func pollTick() {
        guard visible, !fixedMode, !busy else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        panel.orderOut(nil)
        wheel.reset()
        visible = false
        busy = false
        fixedMode = false
        baseline = dragPB.changeCount
    }

    // MARK: Conversion

    private func outputDirectory(for source: URL) -> URL {
        if let path = UserDefaults.standard.string(forKey: "outputDir"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return source.deletingLastPathComponent()
    }

    private func choose(ext: String, urls: [URL]?) {
        guard !busy else { return }
        var targets = files
        if let urls = urls {
            let dropped = Options.files(from: urls)
            if !dropped.isEmpty { targets = dropped }
        }
        let batch = targets.filter { f in
            Tools.targets(for: f.category).contains(ext) && Tools.normalized(f.url.pathExtension) != ext
        }
        guard !batch.isEmpty else {
            hide()
            return
        }

        busy = true
        wheel.phase = .working(done: 0, total: batch.count)
        wheel.needsDisplay = true

        Task { @MainActor in
            var ok = 0
            var fail = 0
            var outputs: [URL] = []
            var lastError = "Conversion failed"

            for (i, f) in batch.enumerated() {
                do {
                    let out = try await Converter.convert(input: f.url, ext: ext, category: f.category,
                                                          outputDir: outputDirectory(for: f.url))
                    outputs.append(out)
                    ok += 1
                    UserDefaults.standard.set(ext, forKey: "last_\(f.category.title)")
                } catch {
                    fail += 1
                    lastError = error.localizedDescription
                }
                wheel.phase = .working(done: i + 1, total: batch.count)
                wheel.needsDisplay = true
            }

            lastOutputs = outputs
            let message: String
            if fail == 0 {
                message = ok == 1 ? "Done · \(outputs[0].lastPathComponent)" : "Done · \(ok) files in \(ext.uppercased())"
            } else if ok == 0 {
                message = lastError
            } else {
                message = "\(ok) converted, \(fail) failed"
            }
            wheel.phase = .finished(success: fail == 0, message: message)
            wheel.needsDisplay = true
            if ok > 0 { NSSound(named: NSSound.Name("Glass"))?.play() }

            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                self.hide()
            }
        }
    }

    private func revealOutputs() {
        if !lastOutputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(lastOutputs)
        }
        hide()
    }

    // MARK: Icon and menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle",
                                accessibilityDescription: "FileWheel")
            image?.isTemplate = true
            button.image = image
        }
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let hint = NSMenuItem(title: "Hold ⇧ while dragging a file", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let pick = NSMenuItem(title: "Convert files…", action: #selector(pickFiles), keyEquivalent: "o")
        pick.target = self
        menu.addItem(pick)
        menu.addItem(.separator())

        let customPath = UserDefaults.standard.string(forKey: "outputDir")

        let same = NSMenuItem(title: "Save next to the original file", action: #selector(useSourceFolder), keyEquivalent: "")
        same.target = self
        same.state = customPath == nil ? .on : .off
        menu.addItem(same)

        let folderTitle = customPath != nil
            ? "Save to: \(URL(fileURLWithPath: customPath ?? "").lastPathComponent)…"
            : "Choose a destination folder…"
        let folder = NSMenuItem(title: folderTitle, action: #selector(chooseFolder), keyEquivalent: "")
        folder.target = self
        folder.state = customPath != nil ? .on : .off
        menu.addItem(folder)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func pickFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let op = NSOpenPanel()
        op.allowsMultipleSelection = true
        op.canChooseFiles = true
        op.canChooseDirectories = false
        guard op.runModal() == .OK else { return }
        let found = Options.files(from: op.urls)
        guard !found.isEmpty else {
            NSSound.beep()
            return
        }
        let spot = NSScreen.main.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
        show(files: found, at: spot, fixed: true)
    }

    @objc private func useSourceFolder() {
        UserDefaults.standard.removeObject(forKey: "outputDir")
        rebuildMenu()
    }

    @objc private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let op = NSOpenPanel()
        op.canChooseFiles = false
        op.canChooseDirectories = true
        op.canCreateDirectories = true
        if op.runModal() == .OK, let url = op.url {
            UserDefaults.standard.set(url.path, forKey: "outputDir")
            rebuildMenu()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showIntroIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "didShowIntro") else { return }
        UserDefaults.standard.set(true, forKey: "didShowIntro")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "FileWheel is running in the menu bar"
        alert.informativeText = "Hold Shift (⇧) while dragging a file: a wheel with the available formats appears next to your cursor. Drop the file on the one you need."
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }
}

@main
struct FileWheelApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}
