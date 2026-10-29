import Foundation
import AppKit
import PDFKit
import CoreGraphics

/// `Pagewright --self-test` runs the main operations on files it creates itself, and prints PASS / FAIL for each.
enum SelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : "  (" + detail + ")"))
        if !ok { failures += 1 }
    }

    static func attempt(_ name: String, _ body: () throws -> Bool) {
        do { check(name, try body()) } catch { check(name, false, error.localizedDescription) }
    }

    static func makePDF(_ url: URL, pages: Int, lines: (Int) -> [String]) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for n in 1...pages {
            ctx.beginPDFPage(nil)
            withGraphics(ctx) {
                var y: CGFloat = 780
                for line in lines(n) {
                    (line as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
                    y -= 26
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func text(_ url: URL, page: Int = 0) -> String {
        return PDFDocument(url: url)?.page(at: page)?.string ?? ""
    }

    static func pages(_ url: URL) -> Int { return PDFDocument(url: url)?.pageCount ?? 0 }

    static func solidImage(_ width: Int, _ height: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage? {
        guard let ctx = makeContext(width, height) else { return nil }
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func run() -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pagewright-selftest-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let out = tmp.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let none = Options()
        print("Pagewright self-test, working in \(tmp.path)\n")

        // ---- catalog
        check("catalog: unique ids", Set(allTools.map { $0.id }).count == allTools.count, "\(allTools.count) tools")
        check("catalog: valid categories", allTools.allSatisfy { categories.contains($0.category) })
        check("parsePages", (try? parsePages("1,3,5-6", count: 8)) == [0, 2, 4, 5] && (try? parsePages("last", count: 4)) == [3])

        // ---- PDF
        let a = tmp.appendingPathComponent("a.pdf"), b = tmp.appendingPathComponent("b.pdf")
        makePDF(a, pages: 3) { ["Hello page \($0)", "Marker Alpha\($0)"] + ($0 == 2 ? ["The client is Confidential-ACME."] : []) }
        makePDF(b, pages: 2) { ["Other page \($0)", "Marker Beta\($0)"] }
        check("fixtures: PDFs created", pages(a) == 3 && pages(b) == 2)

        attempt("merge") { let r = try opMerge([a, b], none, out, noProgress); return pages(r[0]) == 5 && text(r[0], page: 3).contains("Other") }
        attempt("split every page") { return try opSplit([a], Options(values: ["mode": "each"]), out, noProgress).count == 3 }
        attempt("split ranges") { return try opSplit([a], Options(values: ["mode": "ranges", "ranges": "1-2, 3"]), out, noProgress).count == 2 }
        attempt("extract pages") { let r = try opExtract([a], Options(values: ["pages": "2-3"]), out, noProgress); return pages(r[0]) == 2 && text(r[0]).contains("Alpha2") }
        attempt("remove pages") { let r = try opRemove([a], Options(values: ["pages": "1"]), out, noProgress); return pages(r[0]) == 2 && text(r[0]).contains("Alpha2") }
        attempt("reorder pages") { let r = try opReorder([a], Options(values: ["order": "3,1"]), out, noProgress); return pages(r[0]) == 3 && text(r[0]).contains("Alpha3") }
        attempt("rotate") { let r = try opRotate([a], Options(values: ["angle": "90", "pages": "2"]), out, noProgress); return PDFDocument(url: r[0])?.page(at: 1)?.rotation == 90 }
        attempt("crop") {
            let r = try opCropPDF([a], Options(values: ["top": "10", "bottom": "10", "left": "10", "right": "10"]), out, noProgress)
            guard let box = PDFDocument(url: r[0])?.page(at: 0)?.bounds(for: .mediaBox) else { return false }
            return box.width < 595 && box.height < 842
        }
        attempt("page numbers") { let r = try opPageNumbers([a], Options(values: ["format": "Page {n} of {total}"]), out, noProgress); return text(r[0], page: 1).contains("Page 2 of 3") }
        attempt("watermark") { let r = try opWatermarkPDF([a], Options(values: ["text": "DRAFTMARK"]), out, noProgress); return text(r[0]).contains("DRAFTMARK") }
        attempt("compress") { let r = try opCompressPDF([a], Options(values: ["level": "high"]), out, noProgress); return pages(r[0]) == 3 }
        attempt("repair a truncated file") {
            guard var data = try? Data(contentsOf: a) else { return false }
            data.removeLast(60)
            let broken = tmp.appendingPathComponent("broken.pdf")
            try data.write(to: broken)
            let r = try opRepair([broken], none, out, noProgress)
            return pages(r[0]) >= 1
        }
        attempt("protect then unlock") {
            let p = try opProtect([a], Options(values: ["new_password": "s3cret"]), out, noProgress)
            guard let locked = PDFDocument(url: p[0]), locked.isLocked, !locked.unlock(withPassword: "wrong"), locked.unlock(withPassword: "s3cret") else { return false }
            let u = try opUnlock([p[0]], Options(values: ["password": "s3cret"]), out, noProgress)
            return PDFDocument(url: u[0])?.isLocked == false && text(u[0]).contains("Hello")
        }
        attempt("redact removes the text") {
            let r = try opRedact([a], Options(values: ["terms": "Confidential-ACME"]), out, noProgress)
            return !text(r[0], page: 1).contains("ACME") && text(r[0], page: 0).contains("Hello")
        }
        attempt("compare") { let r = try opCompare([a, b], none, out, noProgress); return (try String(contentsOf: r[0], encoding: .utf8)).contains("differ") }
        attempt("PDF to images") { return try opPdfToImages([a], Options(values: ["format": "png", "dpi": "72"]), out, noProgress).count == 3 }
        attempt("PDF to text") { let r = try opPdfToText([a], none, out, noProgress); return (try String(contentsOf: r[0], encoding: .utf8)).contains("Alpha3") }

        // ---- pictures
        let png = tmp.appendingPathComponent("pic.png")
        if let image = solidImage(300, 200, 0.2, 0.4, 0.9) { try? saveImage(image, ext: "png", to: png) }
        attempt("images to PDF") { let r = try opImagesToPdf([png, png], Options(values: ["page_size": "A4"]), out, noProgress); return pages(r[0]) == 2 }
        attempt("convert image to JPG") { let r = try opConvertImages([png], Options(values: ["target": "jpg"]), out, noProgress); return try r[0].pathExtension == "jpg" && loadImage(r[0]).image.width == 300 }
        attempt("resize image") { let r = try opResizeImages([png], Options(values: ["mode": "percent", "percent": "50"]), out, noProgress); return (try loadImage(r[0])).image.width == 150 }
        attempt("crop image to a square") { let r = try opCropImages([png], Options(values: ["mode": "ratio", "ratio": "1:1"]), out, noProgress); let i = (try loadImage(r[0])).image; return i.width == i.height }
        attempt("rotate image") { let r = try opRotateImages([png], Options(values: ["angle": "90"]), out, noProgress); let i = (try loadImage(r[0])).image; return i.width == 200 && i.height == 300 }
        attempt("watermark image") { return try opWatermarkImages([png], Options(values: ["text": "Mine"]), out, noProgress).count == 1 }
        attempt("compress image") { return try opCompressImages([png], Options(values: ["level": "high"]), out, noProgress).count == 1 }
        attempt("remove photo data") { return try opStripMetadata([png], none, out, noProgress).count == 1 }

        // ---- updater helpers
        check("update: shell quoting", shellQuote("it's here") == "'it'\\''s here'")
        attempt("update: finds files changed after the build") {
            let project = tmp.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try "let a = 1".write(to: project.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
            try "#!/bin/bash".write(to: project.appendingPathComponent("build.sh"), atomically: true, encoding: .utf8)
            let now = Date().timeIntervalSince1970
            let changed = UpdateInspector.changedFiles(in: project, since: now - 100)
            let none = UpdateInspector.changedFiles(in: project, since: now + 100)
            return changed.contains("A.swift") && changed.contains("build.sh") && none.isEmpty
        }

        // ---- OCR (Vision)
        attempt("OCR makes a scan searchable") {
            guard let ctx = makeContext(1240, 1754) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1240, height: 1754))
            withGraphics(ctx) { ("INVOICE 2026 HELLO WORLD" as NSString).draw(at: CGPoint(x: 100, y: 1400), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black]) }
            guard let image = ctx.makeImage() else { return false }
            let scanPNG = tmp.appendingPathComponent("scan.png")
            try saveImage(image, ext: "png", to: scanPNG)
            let scanPDF = try opImagesToPdf([scanPNG], Options(values: ["page_size": "A4"]), out, noProgress)[0]
            if text(scanPDF).trimmingCharacters(in: .whitespacesAndNewlines) != "" { return false }
            let r = try opOCR([scanPDF], Options(values: ["language": "en-US", "dpi": "200"]), out, noProgress)
            return text(r[0]).uppercased().contains("INVOICE")
        }

        // ---- documents and audio
        let note = tmp.appendingPathComponent("note.txt")
        try? "Hello Zebra42\nSecond line".write(to: note, atomically: true, encoding: .utf8)
        attempt("document to DOCX") { let r = try opConvertDocument([note], Options(values: ["target": "docx"]), out, noProgress); return fileSize(r[0]) > 100 }
        attempt("document to PDF") { let r = try opConvertDocument([note], Options(values: ["target": "pdf"]), out, noProgress); return text(r[0]).contains("Zebra42") }
        attempt("audio to M4A") {
            let wav = tmp.appendingPathComponent("tone.wav")
            try makeWav().write(to: wav)
            let r = try opConvertAudio([wav], Options(values: ["target": "m4a"]), out, noProgress)
            return fileSize(r[0]) > 500
        }

        print("\n" + (failures == 0 ? "ALL PASSED" : "\(failures) FAILED"))
        try? FileManager.default.removeItem(at: tmp)
        return failures == 0 ? 0 : 1
    }

    static func makeWav() -> Data {
        let rate = 22050, seconds = 1
        var samples = Data()
        for i in 0..<(rate * seconds) {
            let value = Int16(12000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
            var little = value.littleEndian
            samples.append(Data(bytes: &little, count: 2))
        }
        func u32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
        func u16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
        var data = Data("RIFF".utf8)
        data.append(u32(36 + samples.count)); data.append(Data("WAVEfmt ".utf8)); data.append(u32(16)); data.append(u16(1)); data.append(u16(1))
        data.append(u32(rate)); data.append(u32(rate * 2)); data.append(u16(2)); data.append(u16(16))
        data.append(Data("data".utf8)); data.append(u32(samples.count)); data.append(samples)
        return data
    }
}
