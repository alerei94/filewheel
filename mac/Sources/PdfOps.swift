import Foundation
import PDFKit
import AppKit
import Vision
import CoreText

// MARK: - Opening and saving (PDFKit: built into macOS)

func openPDF(_ url: URL, _ password: String = "") throws -> PDFDocument {
    guard let doc = PDFDocument(url: url) else {
        throw ToolError("Could not read “\(url.lastPathComponent)”. It may be damaged (try Repair PDF).")
    }
    if doc.isLocked {
        if password.isEmpty || !doc.unlock(withPassword: password) {
            throw ToolError("“\(url.lastPathComponent)” is password-protected. Enter the password in the options, or use Unlock PDF first.")
        }
    }
    return doc
}

func savePDF(_ doc: PDFDocument, _ url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
    var ok: Bool
    if let options = options { ok = doc.write(to: url, withOptions: options) } else { ok = doc.write(to: url) }
    if !ok { throw ToolError("Could not save “\(url.lastPathComponent)”.") }
}

func copyPage(_ page: PDFPage) -> PDFPage {
    return (page.copy() as? PDFPage) ?? page
}

private func documentWith(_ doc: PDFDocument, pages: [Int]) -> PDFDocument {
    let result = PDFDocument()
    for index in pages {
        if let page = doc.page(at: index) { result.insert(copyPage(page), at: result.pageCount) }
    }
    return result
}

// MARK: - Organize

func opMerge(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    if files.count < 2 { throw ToolError("Add at least two PDF files to merge.") }
    let result = PDFDocument()
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), "Adding \(file.lastPathComponent)")
        let doc = try openPDF(file, o.string("password"))
        for p in 0..<doc.pageCount {
            if let page = doc.page(at: p) { result.insert(copyPage(page), at: result.pageCount) }
        }
    }
    let target = uniqueURL(destDir(out, files[0]), stem(files[0]) + "_merged", "pdf")
    try savePDF(result, target)
    try progress(1, "Done")
    return [target]
}

func opSplit(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let mode = o.string("mode", "ranges")
    var results: [URL] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        let total = doc.pageCount
        var parts: [(String, [Int])] = []
        if mode == "each" {
            for p in 0..<total { parts.append(("page\(p + 1)", [p])) }
        } else if mode == "every" {
            let n = max(1, o.int("every", 1))
            var start = 0
            while start < total {
                let end = min(start + n, total)
                parts.append((end - start > 1 ? "pages\(start + 1)-\(end)" : "page\(start + 1)", Array(start..<end)))
                start = end
            }
        } else {
            let spec = o.string("ranges").trimmingCharacters(in: .whitespacesAndNewlines)
            if spec.isEmpty { throw ToolError("Enter the ranges to split at, for example 1-3, 4-6, 7-") }
            for chunk in spec.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let c = chunk.trimmingCharacters(in: .whitespaces)
                if c.isEmpty { continue }
                parts.append(("pages" + c.replacingOccurrences(of: " ", with: ""), try parsePages(c, count: total)))
            }
        }
        if parts.isEmpty { throw ToolError("Nothing to split.") }
        let folder = try uniqueFolder(destDir(out, file), stem(file) + " split")
        for (pi, part) in parts.enumerated() {
            try progress((Double(fi) + Double(pi) / Double(parts.count)) / Double(files.count), "\(file.lastPathComponent): \(part.0)")
            let piece = documentWith(doc, pages: part.1)
            let target = uniqueURL(folder, "\(stem(file))_\(part.0)", "pdf")
            try savePDF(piece, target)
            results.append(target)
        }
    }
    try progress(1, "Done")
    return results
}

func opExtract(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let doc = try openPDF(file, o.string("password"))
        let indexes = try parsePages(o.string("pages"), count: doc.pageCount, defaultAll: false)
        let target = uniqueURL(destDir(out, file), stem(file) + "_pages", "pdf")
        try savePDF(documentWith(doc, pages: indexes), target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func opRemove(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let doc = try openPDF(file, o.string("password"))
        let removed = Set(try parsePages(o.string("pages"), count: doc.pageCount, defaultAll: false))
        if removed.count >= doc.pageCount { throw ToolError("That would remove every page of the file.") }
        let keep = (0..<doc.pageCount).filter { !removed.contains($0) }
        let target = uniqueURL(destDir(out, file), stem(file) + "_edited", "pdf")
        try savePDF(documentWith(doc, pages: keep), target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func opReorder(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let doc = try openPDF(file, o.string("password"))
        var order = try parsePages(o.string("order"), count: doc.pageCount, defaultAll: false)
        if o.bool("append_rest", true) {
            let used = Set(order)
            order += (0..<doc.pageCount).filter { !used.contains($0) }
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_reordered", "pdf")
        try savePDF(documentWith(doc, pages: order), target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func opRotate(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let angle = o.int("angle", 90)
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let doc = try openPDF(file, o.string("password"))
        let selected = Set(try parsePages(o.string("pages"), count: doc.pageCount))
        for index in selected {
            if let page = doc.page(at: index) { page.rotation = (page.rotation + angle) % 360 }
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_rotated", "pdf")
        try savePDF(doc, target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

// MARK: - Optimize

func opCompressPDF(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let level = o.string("level", "medium")
    var results: [URL] = []
    var notes: [String] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let doc = try openPDF(file, o.string("password"))
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {       // these two PDFKit options exist from macOS 13.4
            if level != "low" { options[.saveImagesAsJPEGOption] = true }
            if level == "high" { options[.optimizeImagesForScreenOption] = true }
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_compressed", "pdf")
        try savePDF(doc, target, options: options)
        let before = fileSize(file), after = fileSize(target)
        if after >= before {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)     // never hand back a bigger file
            notes.append("\(file.lastPathComponent): already well optimized (\(humanSize(before)))")
        } else {
            notes.append("\(file.lastPathComponent): \(humanSize(before)) to \(humanSize(after)) (-\(100 - Int(Double(after) * 100 / Double(before)))%)")
        }
        results.append(target)
    }
    try progress(1, notes.joined(separator: "; "))
    return results
}

func opRepair(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    var notes: [String] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        var document = PDFDocument(url: file)
        if document == nil || document?.pageCount == 0 {
            // a file cut short: close it properly and let the system rebuild the index
            if var data = try? Data(contentsOf: file) {
                data.append(Data("\n%%EOF\n".utf8))
                document = PDFDocument(data: data)
            }
        }
        guard let doc = document, doc.pageCount > 0 else {
            throw ToolError("“\(file.lastPathComponent)” is too damaged to recover: no page could be read.")
        }
        if doc.isLocked, !doc.unlock(withPassword: o.string("password")) {
            throw ToolError("“\(file.lastPathComponent)” is password-protected. Enter the password in the options.")
        }
        let clean = PDFDocument()
        var recovered = 0
        for p in 0..<doc.pageCount {
            if let page = doc.page(at: p) { clean.insert(copyPage(page), at: clean.pageCount); recovered += 1 }
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_repaired", "pdf")
        try savePDF(clean, target)
        notes.append("\(file.lastPathComponent): \(plural(recovered, "page")) recovered")
        results.append(target)
    }
    try progress(1, notes.joined(separator: "; "))
    return results
}

// MARK: - Rendering a page (rotation-aware)

func renderPage(_ page: PDFPage, dpi: Double) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    let turned = page.rotation % 180 != 0
    let width = (turned ? box.height : box.width) * CGFloat(dpi / 72)
    let height = (turned ? box.width : box.height) * CGFloat(dpi / 72)
    let image = page.thumbnail(of: NSSize(width: width, height: height), for: .mediaBox)
    var rect = CGRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    return flattened(cg)       // white behind transparent areas
}

func displaySize(_ page: PDFPage) -> CGSize {
    let box = page.bounds(for: .mediaBox)
    return page.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
}

// MARK: - OCR (Vision: built into macOS)

func opOCR(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let languages = o.string("language", "en-US").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let dpi = Double(o.int("dpi", 300))
    var results: [URL] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        let total = doc.pageCount
        let target = uniqueURL(destDir(out, file), stem(file) + "_ocr", "pdf")
        var first = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(target as CFURL, mediaBox: &first, nil) else { throw ToolError("Could not create the PDF.") }
        for index in 0..<total {
            try progress((Double(fi) + Double(index) / Double(max(total, 1))) / Double(files.count),
                         "\(file.lastPathComponent): page \(index + 1) of \(total)")
            guard let page = doc.page(at: index), let image = renderPage(page, dpi: dpi) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty { request.recognitionLanguages = languages }
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                throw ToolError("Text recognition failed: \(error.localizedDescription). (Language codes look like en-US, it-IT, de-DE.)")
            }
            var box = CGRect(origin: .zero, size: displaySize(page))
            let info = [kCGPDFContextMediaBox as String: withUnsafeBytes(of: &box) { Data($0) }] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.draw(image, in: box)
            let observations: [VNRecognizedTextObservation] = request.results ?? []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let bb = observation.boundingBox       // normalized, origin at the bottom-left
                let rect = CGRect(x: bb.minX * box.width, y: bb.minY * box.height, width: bb.width * box.width, height: bb.height * box.height)
                let font = NSFont.systemFont(ofSize: max(4, rect.height * 0.9))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: candidate.string, attributes: [.font: font]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                ctx.saveGState()
                ctx.setTextDrawingMode(.invisible)       // searchable and copyable, but not drawn
                ctx.textMatrix = CGAffineTransform(scaleX: width > 0 ? rect.width / width : 1, y: 1)
                ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        results.append(target)
    }
    try progress(1, "Done: the text can now be searched and copied")
    return results
}

// MARK: - Stamps drawn on pages (page numbers, watermark, picture)

final class DrawnAnnotation: PDFAnnotation {
    var drawer: ((CGContext, CGRect) -> Void)? = nil

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        drawer?(context, bounds)
        context.restoreGState()
    }
}

func addStamp(_ page: PDFPage, _ draw: @escaping (CGContext, CGRect) -> Void) {
    let box = page.bounds(for: .mediaBox)
    let annotation = DrawnAnnotation(bounds: box, forType: .stamp, withProperties: nil)
    annotation.drawer = draw
    page.addAnnotation(annotation)
}

private func saveBurned(_ doc: PDFDocument, _ target: URL) throws {
    try savePDF(doc, target, options: [.burnInAnnotationsOption: true])
}

func opPageNumbers(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let grid = gridPositions[o.string("position", "bottom center")] ?? (0.5, 0)
    let start = o.int("start", 1)
    let template = o.string("format", "{n}").isEmpty ? "{n}" : o.string("format", "{n}")
    let size = CGFloat(o.double("size", 11))
    let skipFirst = o.bool("skip_first", false)
    let margin: CGFloat = 28
    var results: [URL] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        let total = doc.pageCount
        let selected = Set(try parsePages(o.string("pages"), count: total))
        for index in 0..<total {
            try progress((Double(fi) + Double(index) / Double(total)) / Double(files.count), "\(file.lastPathComponent): page \(index + 1)")
            guard let page = doc.page(at: index), selected.contains(index), !(skipFirst && index == 0) else { continue }
            let number = start + index - (skipFirst ? 1 : 0)
            let count = total - (skipFirst ? 1 : 0) + start - 1
            let label = template.replacingOccurrences(of: "{n}", with: String(number)).replacingOccurrences(of: "{total}", with: String(count))
            addStamp(page) { ctx, rect in
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
                let textSize = (label as NSString).size(withAttributes: attributes)
                let x = rect.minX + margin + CGFloat(grid.0) * (rect.width - 2 * margin - textSize.width)
                let y = rect.minY + margin + CGFloat(grid.1) * (rect.height - 2 * margin - textSize.height)
                withGraphics(ctx) { (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes) }
            }
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_numbered", "pdf")
        try saveBurned(doc, target)
        results.append(target)
    }
    try progress(1, "Done (on rotated pages the number may sit on a side)")
    return results
}

func opWatermarkPDF(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let text = o.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { throw ToolError("Enter the watermark text.") }
    let size = CGFloat(o.double("size", 64))
    let opacity = CGFloat(max(0.05, min(1, o.double("opacity", 25) / 100)))
    let angle = CGFloat(o.double("angle", 45))
    let color = colorNamed(o.string("color", "gray")).withAlphaComponent(opacity)
    let grid = gridPositions[o.string("position", "center")] ?? (0.5, 0.5)
    var results: [URL] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        let total = doc.pageCount
        let selected = Set(try parsePages(o.string("pages"), count: total))
        for index in 0..<total {
            try progress((Double(fi) + Double(index) / Double(total)) / Double(files.count), "\(file.lastPathComponent): page \(index + 1)")
            guard let page = doc.page(at: index), selected.contains(index) else { continue }
            addStamp(page) { ctx, rect in
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: color]
                let textSize = (text as NSString).size(withAttributes: attributes)
                let cx = rect.minX + (grid.0 == 0 ? size : (grid.0 == 1 ? rect.width - size : rect.width * CGFloat(grid.0)))
                let cy = rect.minY + (grid.1 == 0 ? size : (grid.1 == 1 ? rect.height - size : rect.height * CGFloat(grid.1)))
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: angle * .pi / 180)
                withGraphics(ctx) { (text as NSString).draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2), withAttributes: attributes) }
            }
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_watermarked", "pdf")
        try saveBurned(doc, target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func opStampImage(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let path = o.string("image")
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path), let picture = NSImage(contentsOfFile: path) else {
        throw ToolError("Choose the image to add (for example a PNG of your signature).")
    }
    let opacity = CGFloat(max(0.05, min(1, o.double("opacity", 100) / 100)))
    let widthFraction = CGFloat(max(1, min(100, o.double("width", 25))) / 100)
    let grid = gridPositions[o.string("position", "bottom right")] ?? (1, 0)
    let margin = CGFloat(o.double("margin", 36))
    let ratio = picture.size.height / max(picture.size.width, 1)
    var results: [URL] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        let total = doc.pageCount
        let selected = Set(try parsePages(o.string("pages"), count: total))
        for index in 0..<total {
            try progress((Double(fi) + Double(index) / Double(total)) / Double(files.count), "\(file.lastPathComponent): page \(index + 1)")
            guard let page = doc.page(at: index), selected.contains(index) else { continue }
            addStamp(page) { ctx, rect in
                let w = rect.width * widthFraction
                let h = w * ratio
                let x = rect.minX + margin + CGFloat(grid.0) * (rect.width - 2 * margin - w)
                let y = rect.minY + margin + CGFloat(grid.1) * (rect.height - 2 * margin - h)
                withGraphics(ctx) {
                    picture.draw(in: NSRect(x: x, y: y, width: w, height: h), from: .zero, operation: .sourceOver, fraction: opacity)
                }
            }
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_stamped", "pdf")
        try saveBurned(doc, target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

func opCropPDF(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let mm = 72.0 / 25.4
    let top = o.double("top") * mm, right = o.double("right") * mm, bottom = o.double("bottom") * mm, left = o.double("left") * mm
    if top == 0 && right == 0 && bottom == 0 && left == 0 { throw ToolError("Enter how much to cut from at least one side.") }
    var results: [URL] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        let total = doc.pageCount
        let selected = Set(try parsePages(o.string("pages"), count: total))
        for index in 0..<total {
            try progress((Double(fi) + Double(index) / Double(total)) / Double(files.count), "\(file.lastPathComponent): page \(index + 1)")
            guard let page = doc.page(at: index), selected.contains(index) else { continue }
            // margins are given as the reader sees the page: turn them into the page's own directions
            var t = top, r = right, b = bottom, l = left
            switch page.rotation % 360 {
            case 90: (t, r, b, l) = (right, bottom, left, top)
            case 180: (t, r, b, l) = (bottom, left, top, right)
            case 270: (t, r, b, l) = (left, top, right, bottom)
            default: break
            }
            let box = page.bounds(for: .mediaBox)
            let cropped = CGRect(x: box.minX + l, y: box.minY + b, width: box.width - l - r, height: box.height - t - b)
            if cropped.width < 20 || cropped.height < 20 { throw ToolError("Page \(index + 1) would be left almost empty: use smaller margins.") }
            page.setBounds(cropped, for: .cropBox)
            page.setBounds(cropped, for: .mediaBox)
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_cropped", "pdf")
        try savePDF(doc, target)
        results.append(target)
    }
    try progress(1, "Done")
    return results
}

// MARK: - Security

func opProtect(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let user = o.string("new_password")
    if user.isEmpty { throw ToolError("Enter the password to set.") }
    let owner = o.string("owner_password").isEmpty ? user : o.string("owner_password")
    // permission bits from the PDF specification
    var permissions = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11)
    if !o.bool("allow_print", true) { permissions &= ~((1 << 2) | (1 << 11)) }
    if !o.bool("allow_copy", true) { permissions &= ~((1 << 4) | (1 << 9)) }
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let doc = try openPDF(file, o.string("password"))
        let target = uniqueURL(destDir(out, file), stem(file) + "_protected", "pdf")
        try savePDF(doc, target, options: [.userPasswordOption: user, .ownerPasswordOption: owner,
                                           .accessPermissionsOption: NSNumber(value: permissions)])
        results.append(target)
    }
    try progress(1, "Done: remember the password, it can't be recovered")
    return results
}

func opUnlock(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    var notes: [String] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        guard let doc = PDFDocument(url: file) else { throw ToolError("Could not read “\(file.lastPathComponent)”.") }
        if doc.isLocked && !doc.unlock(withPassword: o.string("password")) {
            throw ToolError("Wrong password for “\(file.lastPathComponent)”. A password is needed to remove the protection.")
        }
        if !doc.isEncrypted { notes.append("\(file.lastPathComponent) was not protected") }
        let target = uniqueURL(destDir(out, file), stem(file) + "_unlocked", "pdf")
        try savePDF(doc, target)
        results.append(target)
    }
    try progress(1, notes.isEmpty ? "Done" : notes.joined(separator: "; "))
    return results
}

func opRedact(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let terms = o.string("terms").split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if terms.isEmpty { throw ToolError("Enter the words to black out, separated by commas.") }
    let matchCase = o.bool("match_case", false)
    let dpi = Double(o.int("dpi", 200))
    let scale = CGFloat(dpi / 72)
    var results: [URL] = []
    var notes: [String] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        var rectsByPage: [Int: [CGRect]] = [:]
        var hits = 0
        for term in terms {
            let found = doc.findString(term, withOptions: matchCase ? [] : [.caseInsensitive])
            for selection in found {
                hits += 1
                for line in selection.selectionsByLine() {
                    for page in line.pages {
                        rectsByPage[doc.index(for: page), default: []].append(line.bounds(for: page))
                    }
                }
            }
        }
        if hits == 0 {
            throw ToolError("No matches found in “\(file.lastPathComponent)”, so nothing was redacted. (Only text that can be selected is searched: scanned pages need OCR PDF first.)")
        }
        let result = PDFDocument()
        for index in 0..<doc.pageCount {
            try progress((Double(fi) + Double(index) / Double(doc.pageCount)) / Double(files.count), "\(file.lastPathComponent): page \(index + 1)")
            guard let page = doc.page(at: index) else { continue }
            guard let rects = rectsByPage[index] else { result.insert(copyPage(page), at: result.pageCount); continue }
            if page.rotation != 0 { throw ToolError("Page \(index + 1) is rotated: use Rotate PDF to straighten it first, then redact.") }
            let box = page.bounds(for: .mediaBox)
            guard let image = renderPage(page, dpi: dpi), let ctx = makeContext(image.width, image.height) else {
                throw ToolError("Could not draw page \(index + 1).")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            for r in rects {
                let pad: CGFloat = 1.2 * scale
                ctx.fill(CGRect(x: (r.minX - box.minX) * scale - pad, y: (r.minY - box.minY) * scale - pad,
                                width: r.width * scale + 2 * pad, height: r.height * scale + 2 * pad))
            }
            guard let burned = ctx.makeImage(), let newPage = PDFPage(image: NSImage(cgImage: burned, size: NSSize(width: box.width, height: box.height))) else {
                throw ToolError("Could not rebuild page \(index + 1).")
            }
            result.insert(newPage, at: result.pageCount)
        }
        let target = uniqueURL(destDir(out, file), stem(file) + "_redacted", "pdf")
        try savePDF(result, target)
        notes.append("\(file.lastPathComponent): \(plural(hits, "match")) on \(plural(rectsByPage.count, "page"))")
        results.append(target)
    }
    try progress(1, notes.joined(separator: "; ") + ". Pages with redactions became pictures (text can't be recovered)")
    return results
}

func htmlEscape(_ text: String) -> String {
    return text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func opCompare(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    if files.count != 2 { throw ToolError("Add exactly two PDF files to compare.") }
    let a = try openPDF(files[0], o.string("password")), b = try openPDF(files[1], o.string("password"))
    func lines(_ page: PDFPage?) -> [String] {
        return (page?.string ?? "").replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }
    let longest = max(a.pageCount, b.pageCount)
    var sections = ""
    var changed = 0
    for index in 0..<longest {
        try progress(Double(index) / Double(max(longest, 1)), "Comparing page \(index + 1)")
        let left = lines(index < a.pageCount ? a.page(at: index) : nil)
        let right = lines(index < b.pageCount ? b.page(at: index) : nil)
        if left == right { continue }
        changed += 1
        let difference = right.difference(from: left)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows = ""
        var li = 0, ri = 0
        while li < left.count || ri < right.count {
            if li < left.count && removed.contains(li) {
                rows += "<div class=\"del\">− \(htmlEscape(left[li]))</div>"; li += 1
            } else if ri < right.count && inserted.contains(ri) {
                rows += "<div class=\"add\">+ \(htmlEscape(right[ri]))</div>"; ri += 1
            } else {
                if ri < right.count { rows += "<div>  \(htmlEscape(right[ri]))</div>" }
                li += 1; ri += 1
            }
        }
        sections += "<h2>Page \(index + 1)</h2>\(rows)"
    }
    let summary = changed == 0 ? "<p><b>No differences in the text.</b> (Only the text of the pages is compared.)</p>"
                               : "<p><b>\(changed)</b> of \(longest) page\(longest == 1 ? "" : "s") differ.</p>"
    let page = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Compare PDF</title>
    <style>body{font-family:-apple-system,sans-serif;margin:24px;color:#222}div{font-family:Menlo,monospace;font-size:12px;white-space:pre-wrap;padding:1px 6px}
    .add{background:#c7f0c7}.del{background:#f6c4c4}</style></head>
    <body><h1>Compare PDF</h1><p>\(htmlEscape(files[0].lastPathComponent)) &rarr; \(htmlEscape(files[1].lastPathComponent))</p>\(summary)\(sections)</body></html>
    """
    let target = uniqueURL(destDir(out, files[0]), "\(stem(files[0]))_vs_\(stem(files[1]))", "html")
    try page.write(to: target, atomically: true, encoding: .utf8)
    try progress(1, changed == 0 ? "Done: no differences" : "Done: \(plural(changed, "page")) differ")
    return [target]
}

// MARK: - Convert from / to PDF

func opPdfToImages(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let format = o.string("format", "png")
    let dpi = Double(o.int("dpi", 150))
    var results: [URL] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        let total = doc.pageCount
        let indexes = try parsePages(o.string("pages"), count: total)
        let folder = try uniqueFolder(destDir(out, file), stem(file) + " images")
        let digits = String(total).count
        for (n, index) in indexes.enumerated() {
            try progress((Double(fi) + Double(n) / Double(indexes.count)) / Double(files.count), "\(file.lastPathComponent): page \(index + 1)")
            guard let page = doc.page(at: index), let image = renderPage(page, dpi: dpi) else { continue }
            let number = String(index + 1).leftPadded(digits)
            let target = folder.appendingPathComponent("\(stem(file))_page\(number).\(format == "jpg" ? "jpg" : "png")")
            try saveImage(image, ext: format == "jpg" ? "jpg" : "png", to: target, quality: 0.9)
            results.append(target)
        }
    }
    try progress(1, "Done")
    return results
}

extension String {
    func leftPadded(_ length: Int) -> String {
        if count >= length { return self }
        return String(repeating: "0", count: length - count) + self
    }
}

func opPdfToText(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let marks = o.bool("page_marks", true)
    var results: [URL] = []
    var notes: [String] = []
    for (fi, file) in files.enumerated() {
        let doc = try openPDF(file, o.string("password"))
        var chunks: [String] = []
        for index in 0..<doc.pageCount {
            try progress((Double(fi) + Double(index) / Double(max(doc.pageCount, 1))) / Double(files.count), "\(file.lastPathComponent): page \(index + 1)")
            let text = (doc.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            chunks.append((marks ? "----- Page \(index + 1) -----\n" : "") + text)
        }
        let body = chunks.joined(separator: "\n\n")
        if body.replacingOccurrences(of: "\\s|----- Page \\d+ -----", with: "", options: .regularExpression).isEmpty {
            notes.append("\(file.lastPathComponent): no text found (a scan? try OCR PDF first)")
        }
        let target = uniqueURL(destDir(out, file), stem(file), "txt")
        try body.write(to: target, atomically: true, encoding: .utf8)
        results.append(target)
    }
    try progress(1, notes.isEmpty ? "Done" : notes.joined(separator: "; "))
    return results
}

func opImagesToPdf(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    if files.isEmpty { throw ToolError("Add at least one image.") }
    let sizeName = o.string("page_size", "A4")
    let margin = CGFloat(o.int("margin", 18))
    let target = uniqueURL(destDir(out, files[0]), files.count > 1 ? stem(files[0]) + "_images" : stem(files[0]), "pdf")
    var first = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    guard let ctx = CGContext(target as CFURL, mediaBox: &first, nil) else { throw ToolError("Could not create the PDF.") }
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), file.lastPathComponent)
        let (image, _) = try loadImage(file)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var page: CGRect
        var drawRect: CGRect
        if sizeName == "A4" || sizeName == "Letter" {
            var pw: CGFloat = sizeName == "A4" ? 595.28 : 612
            var ph: CGFloat = sizeName == "A4" ? 841.89 : 792
            if w > h { swap(&pw, &ph) }                       // a landscape picture gets a landscape page
            page = CGRect(x: 0, y: 0, width: pw, height: ph)
            let scale = min((pw - 2 * margin) / w, (ph - 2 * margin) / h)
            drawRect = CGRect(x: (pw - w * scale) / 2, y: (ph - h * scale) / 2, width: w * scale, height: h * scale)
        } else {                                              // same shape as the picture, scaled to an A4-sized page
            let scale = 841.89 / max(w, h)
            page = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
            drawRect = page
        }
        let info = [kCGPDFContextMediaBox as String: withUnsafeBytes(of: &page) { Data($0) }] as CFDictionary
        ctx.beginPDFPage(info)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(page)
        ctx.draw(image, in: drawRect)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    try progress(1, "Done")
    return [target]
}