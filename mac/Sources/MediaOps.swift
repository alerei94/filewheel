import Foundation
import AVFoundation
import AppKit

func ffmpegMessage() -> String? {
    return ffmpegPath() == nil ? "Needs ffmpeg (free). In Terminal: brew install ffmpeg" : nil
}

func officeMessage() -> String? {
    return sofficePath() == nil ? "Needs LibreOffice (free). In Terminal: brew install --cask libreoffice" : nil
}

// MARK: - ffmpeg (optional: more formats)

private func durationOf(_ exe: String, _ source: URL) -> Double? {
    guard let result = try? runProcess(exe, ["-hide_banner", "-i", source.path]) else { return nil }
    guard let range = result.output.range(of: "Duration: ") else { return nil }
    let tail = result.output[range.upperBound...].prefix(11)          // 00:01:23.45
    let parts = tail.split(separator: ":")
    if parts.count < 3 { return nil }
    guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2].prefix(5)) else { return nil }
    return h * 3600 + m * 60 + s
}

/// Runs ffmpeg at low priority, reports the progress, and stops (removing the unfinished file) if cancelled.
func runFFmpeg(_ exe: String, source: URL, output: URL, middle: [String], progress: Progress,
               base: Double, span: Double, label: String) throws {
    let duration = durationOf(exe, source)
    let threads = String(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    let arguments = ["-n", "5", exe, "-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1",
                     "-i", source.path] + middle + ["-threads", threads, output.path]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")     // low priority: the Mac stays responsive
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    let errorBox = DataBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errorBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    var buffer = ""
    let handle = outPipe.fileHandleForReading
    while true {
        let data = handle.availableData
        if data.isEmpty { break }
        buffer += String(data: data, encoding: .utf8) ?? ""
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.hasPrefix("out_time_us="), let micro = Double(line.dropFirst("out_time_us=".count)), let total = duration, total > 0 {
                let fraction = max(0, min(1, micro / 1_000_000 / total))
                do {
                    try progress(base + span * fraction, "\(label) \(Int(fraction * 100))%")
                } catch {
                    process.terminate()
                    process.waitUntilExit()
                    group.wait()
                    try? FileManager.default.removeItem(at: output)
                    throw error
                }
            }
        }
    }
    process.waitUntilExit()
    group.wait()
    if process.terminationStatus != 0 {
        try? FileManager.default.removeItem(at: output)
        let text = String(data: errorBox.data, encoding: .utf8) ?? ""
        if text.contains("Unknown encoder") {
            throw ToolError("This ffmpeg can't write that format (\(lastChars(text, 120))). Try another format.")
        }
        throw ToolError("ffmpeg could not convert “\(source.lastPathComponent)”. \(lastChars(text, 300))")
    }
}

// MARK: - Audio

func ffmpegAudioArgs(_ target: String, _ bitrate: String) throws -> [String] {
    switch target {
    case "mp3": return ["-vn", "-c:a", "libmp3lame", "-b:a", bitrate]
    case "m4a": return ["-vn", "-c:a", "aac", "-b:a", bitrate]
    case "wav": return ["-vn", "-c:a", "pcm_s16le"]
    case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
    case "flac": return ["-vn", "-c:a", "flac"]
    case "ogg":
        let q = ["128k": "4", "192k": "6", "256k": "8", "320k": "10"][bitrate] ?? "6"
        return ["-vn", "-c:a", "libvorbis", "-q:a", q]
    case "opus": return ["-vn", "-c:a", "libopus", "-b:a", bitrate]
    default: throw ToolError("Unsupported audio format: \(target)")
    }
}

func afconvertArgs(_ target: String) -> [String]? {
    switch target {
    case "m4a": return ["-f", "m4af", "-d", "aac"]
    case "wav": return ["-f", "WAVE", "-d", "LEI16"]
    case "aiff": return ["-f", "AIFF", "-d", "BEI16"]
    case "caf": return ["-f", "caff", "-d", "LEI16"]
    case "flac": return ["-f", "flac", "-d", "flac"]
    default: return nil
    }
}

func convertOneAudio(_ file: URL, target: String, bitrate: String, out: URL?, progress: Progress, base: Double, span: Double) throws -> URL {
    let output = uniqueURL(destDir(out, file), stem(file), target)
    if let exe = ffmpegPath() {
        try runFFmpeg(exe, source: file, output: output, middle: try ffmpegAudioArgs(target, bitrate),
                      progress: progress, base: base, span: span, label: file.lastPathComponent)
        return output
    }
    guard let args = afconvertArgs(target) else {
        throw ToolError("\(target.uppercased()) needs ffmpeg. In Terminal: brew install ffmpeg")
    }
    try progress(base, file.lastPathComponent)
    let result = try runProcess("/usr/bin/afconvert", args + [file.path, output.path])
    if result.status != 0 {
        try? FileManager.default.removeItem(at: output)
        throw ToolError("Could not convert “\(file.lastPathComponent)”. \(lastChars(result.output, 200))")
    }
    return output
}

func opConvertAudio(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        results.append(try convertOneAudio(file, target: o.string("target", "mp3"), bitrate: o.string("bitrate", "192k"), out: out,
                                           progress: progress, base: Double(i) / Double(files.count), span: 1 / Double(files.count)))
    }
    try progress(1, "Done")
    return results
}

// MARK: - Video

func exportWithAV(_ source: URL, output: URL, preset: String, fileType: AVFileType, progress: Progress,
                  base: Double, span: Double, label: String) throws {
    let asset = AVURLAsset(url: source)
    // the wanted preset, or the best quality one if this video can't use it
    guard let session = AVAssetExportSession(asset: asset, presetName: preset)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
        throw ToolError("This file can't be converted with the formats built into macOS. Install ffmpeg for more (brew install ffmpeg).")
    }
    session.outputURL = output
    session.outputFileType = fileType
    let finished = DispatchSemaphore(value: 0)
    session.exportAsynchronously { finished.signal() }
    while finished.wait(timeout: .now() + 0.25) == .timedOut {
        do {
            try progress(base + span * Double(session.progress), "\(label) \(Int(session.progress * 100))%")
        } catch {
            session.cancelExport()
            finished.wait()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
    if session.status != .completed {
        try? FileManager.default.removeItem(at: output)
        throw ToolError(session.error?.localizedDescription ?? "The export did not finish.")
    }
}

func avPreset(for cap: String) -> String {
    switch cap {
    case "1080": return AVAssetExportPreset1920x1080
    case "720": return AVAssetExportPreset1280x720
    case "480": return AVAssetExportPreset640x480
    default: return AVAssetExportPresetHighestQuality
    }
}

func scaleFilter(_ cap: String) -> [String] {
    if let height = Int(cap) { return ["-vf", "scale=-2:'min(ih,\(height))'"] }
    return []
}

func ffmpegVideoArgs(_ target: String, _ quality: String, _ cap: String) throws -> [String] {
    let crf = ["small": "28", "balanced": "23", "high": "18"][quality] ?? "23"
    let vp9 = ["small": "36", "balanced": "31", "high": "25"][quality] ?? "31"
    switch target {
    case "mp4", "mov":
        return ["-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
            + scaleFilter(cap) + ["-movflags", "+faststart"]
    case "mkv":
        return ["-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"] + scaleFilter(cap)
    case "webm":
        return ["-c:v", "libvpx-vp9", "-crf", vp9, "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus"] + scaleFilter(cap)
    case "avi":
        return ["-c:v", "mpeg4", "-q:v", ["small": "8", "balanced": "5", "high": "2"][quality] ?? "5", "-c:a", "libmp3lame"] + scaleFilter(cap)
    case "gif":
        let width = Int(cap) ?? 480
        return ["-an", "-vf", "fps=12,scale='min(iw,\(width))':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
    default: throw ToolError("Unsupported video format: \(target)")
    }
}

func opConvertVideo(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let target = o.string("target", "mp4")
    let cap = o.string("max_height", "keep")
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        let base = Double(i) / Double(files.count), span = 1 / Double(files.count)
        let output = uniqueURL(destDir(out, file), stem(file), target)
        if let exe = ffmpegPath() {
            try runFFmpeg(exe, source: file, output: output, middle: try ffmpegVideoArgs(target, o.string("quality", "balanced"), cap),
                          progress: progress, base: base, span: span, label: file.lastPathComponent)
        } else {
            let types: [String: AVFileType] = ["mp4": .mp4, "mov": .mov, "m4v": .m4v]
            guard let type = types[target] else { throw ToolError("\(target.uppercased()) needs ffmpeg. In Terminal: brew install ffmpeg") }
            try exportWithAV(file, output: output, preset: avPreset(for: cap), fileType: type, progress: progress,
                             base: base, span: span, label: file.lastPathComponent)
        }
        results.append(output)
    }
    try progress(1, "Done")
    return results
}

func opCompressVideo(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let level = o.string("level", "medium")
    let cap = o.string("max_height", "keep")
    var results: [URL] = []
    var notes: [String] = []
    for (i, file) in files.enumerated() {
        let base = Double(i) / Double(files.count), span = 1 / Double(files.count)
        let output = uniqueURL(destDir(out, file), stem(file) + "_compressed", "mp4")
        if let exe = ffmpegPath() {
            let crf = ["light": "26", "medium": "29", "strong": "33"][level] ?? "29"
            let middle = ["-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k"]
                + scaleFilter(cap) + ["-movflags", "+faststart"]
            try runFFmpeg(exe, source: file, output: output, middle: middle, progress: progress, base: base, span: span, label: file.lastPathComponent)
        } else {
            let preset = cap != "keep" ? avPreset(for: cap) : (level == "light" ? AVAssetExportPreset1920x1080 : (level == "strong" ? AVAssetExportPreset640x480 : AVAssetExportPreset1280x720))
            try exportWithAV(file, output: output, preset: preset, fileType: .mp4, progress: progress, base: base, span: span, label: file.lastPathComponent)
        }
        let before = fileSize(file), after = fileSize(output)
        notes.append("\(file.lastPathComponent): \(humanSize(before)) to \(humanSize(after))" + (after < before ? " (-\(100 - Int(Double(after) * 100 / Double(max(before, 1))))%)" : " (not smaller: try a stronger level)"))
        results.append(output)
    }
    try progress(1, notes.joined(separator: "; "))
    return results
}

func opExtractAudio(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let target = o.string("target", "mp3")
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        let base = Double(i) / Double(files.count), span = 1 / Double(files.count)
        if ffmpegPath() == nil && target == "m4a" {
            let output = uniqueURL(destDir(out, file), stem(file), "m4a")
            try exportWithAV(file, output: output, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, progress: progress,
                             base: base, span: span, label: file.lastPathComponent)
            results.append(output)
        } else {
            results.append(try convertOneAudio(file, target: target, bitrate: o.string("bitrate", "192k"), out: out,
                                               progress: progress, base: base, span: span))
        }
    }
    try progress(1, "Done")
    return results
}

// MARK: - Documents

func documentToPDF(_ input: URL, _ output: URL) throws {
    if Thread.isMainThread {
        try documentToPDFOnMain(input, output)
        return
    }
    var failure: Error? = nil
    DispatchQueue.main.sync {          // printing must happen on the main thread
        do { try documentToPDFOnMain(input, output) } catch { failure = error }
    }
    if let failure = failure { throw failure }
}

private func documentToPDFOnMain(_ input: URL, _ output: URL) throws {
    let ext = input.pathExtension.lowercased()
    var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
    if ext == "txt" || ext == "md" {
        options[.documentType] = NSAttributedString.DocumentType.plain
        options[.characterEncoding] = String.Encoding.utf8.rawValue
    }
    let attributed = try NSAttributedString(url: input, options: options, documentAttributes: nil)
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

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.minSize = NSSize(width: width, height: 0)
    textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = .zero
    textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.textStorage?.setAttributedString(attributed)
    if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
    textView.sizeToFit()

    let operation = NSPrintOperation(view: textView, printInfo: info)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    if !operation.run() || !FileManager.default.fileExists(atPath: output.path) {
        throw ToolError("Could not create the PDF.")
    }
}

func opConvertDocument(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    let target = o.string("target", "pdf")
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), "Converting \(file.lastPathComponent)")
        let output = uniqueURL(destDir(out, file), stem(file), target)
        if target == "pdf" {
            do { try documentToPDF(file, output) } catch let error as ToolError { throw error }
            catch { throw ToolError("Could not read “\(file.lastPathComponent)”. \(error.localizedDescription)") }
        } else {
            // textutil is part of macOS
            let result = try runProcess("/usr/bin/textutil", ["-convert", target, "-output", output.path, file.path])
            if result.status != 0 || !FileManager.default.fileExists(atPath: output.path) {
                throw ToolError("Could not convert “\(file.lastPathComponent)”. \(lastChars(result.output, 200))")
            }
        }
        results.append(output)
    }
    try progress(1, "Done")
    return results
}

// MARK: - LibreOffice (optional: Office files, PDF to Word / PowerPoint)

func sofficeConvert(_ source: URL, target: String, ext: String, out: URL?, infilter: String? = nil) throws -> URL {
    guard let exe = sofficePath() else { throw ToolError(officeMessage() ?? "Needs LibreOffice.") }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("pagewright-" + UUID().uuidString)
    let profile = work.appendingPathComponent("profile")        // a private profile lets this work even if LibreOffice is open
    let produced = work.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: produced, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    var args = ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore", "--nolockcheck"]
    if let infilter = infilter { args.append("--infilter=" + infilter) }
    args += ["--convert-to", target, "--outdir", produced.path, source.path]
    let result = try runProcess(exe, args)
    let items = (try? FileManager.default.contentsOfDirectory(at: produced, includingPropertiesForKeys: nil)) ?? []
    guard let first = items.first else {
        throw ToolError("LibreOffice could not convert “\(source.lastPathComponent)”. \(lastChars(result.output, 200))")
    }
    let final = uniqueURL(destDir(out, source), stem(source), ext)
    try FileManager.default.moveItem(at: first, to: final)
    return final
}

func opOfficeToPDF(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), "Converting \(file.lastPathComponent)")
        results.append(try sofficeConvert(file, target: "pdf", ext: "pdf", out: out))
    }
    try progress(1, "Done")
    return results
}

func opPdfToWord(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), "Converting \(file.lastPathComponent)")
        results.append(try sofficeConvert(file, target: "docx:MS Word 2007 XML", ext: "docx", out: out, infilter: "writer_pdf_import"))
    }
    try progress(1, "Done: layout is approximate, check the result")
    return results
}

func opPdfToPowerPoint(_ files: [URL], _ o: Options, _ out: URL?, _ progress: Progress) throws -> [URL] {
    var results: [URL] = []
    for (i, file) in files.enumerated() {
        try progress(Double(i) / Double(files.count), "Converting \(file.lastPathComponent)")
        results.append(try sofficeConvert(file, target: "pptx:Impress MS PowerPoint 2007 XML", ext: "pptx", out: out, infilter: "impress_pdf_import"))
    }
    try progress(1, "Done: layout is approximate, check the result")
    return results
}