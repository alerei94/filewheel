import Foundation

// MARK: - Errors, progress, options

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CancelledError: Error {}

/// fraction (0...1) and a short message. Throws CancelledError when the user pressed Cancel.
typealias Progress = (Double, String) throws -> Void

let noProgress: Progress = { _, _ in }

struct Options {
    var values: [String: Any] = [:]

    func string(_ key: String, _ fallback: String = "") -> String {
        if let s = values[key] as? String { return s }
        if let n = values[key] as? Int { return String(n) }
        return fallback
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        if let n = values[key] as? Int { return n }
        if let d = values[key] as? Double { return Int(d) }
        if let s = values[key] as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        return fallback
    }

    func double(_ key: String, _ fallback: Double = 0) -> Double {
        if let d = values[key] as? Double { return d }
        if let n = values[key] as? Int { return Double(n) }
        if let s = values[key] as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        return fallback
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        if let b = values[key] as? Bool { return b }
        if let s = values[key] as? String { return s == "true" || s == "1" || s == "yes" }
        return fallback
    }
}

// MARK: - Files and names

func destDir(_ outDir: URL?, _ source: URL) -> URL {
    return outDir ?? source.deletingLastPathComponent()
}

/// name.ext, or "name 2.ext", "name 3.ext"... so nothing is ever overwritten.
func uniqueURL(_ dir: URL, _ stem: String, _ ext: String) -> URL {
    var url = dir.appendingPathComponent(stem).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return url
}

func uniqueFolder(_ dir: URL, _ name: String) throws -> URL {
    var url = dir.appendingPathComponent(name)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(name) \(n)")
        n += 1
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func stem(_ url: URL) -> String {
    return url.deletingPathExtension().lastPathComponent
}

func fileSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attributes?[.size] as? NSNumber { return size.int64Value }
    return 0
}

func humanSize(_ bytes: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func normalizeExt(_ ext: String) -> String {
    let e = ext.lowercased().replacingOccurrences(of: ".", with: "")
    switch e {
    case "jpeg": return "jpg"
    case "tif": return "tiff"
    case "aif": return "aiff"
    case "htm": return "html"
    case "mpeg": return "mpg"
    default: return e
    }
}

func plural(_ n: Int, _ word: String) -> String {
    return "\(n) \(word)\(n == 1 ? "" : "s")"
}

// MARK: - Page ranges

/// "1,3,5-8" -> [0, 2, 4, 5, 6, 7] (0-based, in the order written). Also "5-" (to the end), "-3", "last", "8-1".
func parsePages(_ spec: String, count: Int, defaultAll: Bool = true) throws -> [Int] {
    var text = spec.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    for dash in ["\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"] {
        text = text.replacingOccurrences(of: dash, with: "-")
    }
    if text.isEmpty || text == "all" || text == "*" {
        if defaultAll { return Array(0..<count) }
        throw ToolError("Enter the pages, for example 1,3,5-8")
    }

    func number(_ token: String) throws -> Int {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t == "last" || t == "end" || t == "l" { return count }
        guard let v = Int(t) else { throw ToolError("“\(t)” is not a page number. Use for example 1,3,5-8") }
        if v < 1 || v > count {
            throw ToolError("Page \(v) does not exist (the file has \(plural(count, "page"))).")
        }
        return v
    }

    var pages: [Int] = []
    let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map { String($0) }
    for part in parts {
        if let dash = part.firstIndex(of: "-") {
            let left = String(part[part.startIndex..<dash])
            let right = String(part[part.index(after: dash)...])
            let start = try (left.isEmpty ? 1 : number(left))
            let end = try (right.isEmpty ? count : number(right))
            let step = start <= end ? 1 : -1
            for p in stride(from: start, through: end, by: step) { pages.append(p - 1) }
        } else {
            pages.append(try number(part) - 1)
        }
    }
    if pages.isEmpty { throw ToolError("Enter the pages, for example 1,3,5-8") }
    return pages
}

// MARK: - Programs and processes

func findProgram(_ names: [String], extra: [String] = []) -> String? {
    let fm = FileManager.default
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) }
    // apps opened from the Finder don't get the shell's PATH: look in the usual places too
    dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    for dir in dirs {
        for name in names {
            let path = dir + "/" + name
            if fm.isExecutableFile(atPath: path) { return path }
        }
    }
    for path in extra where fm.isExecutableFile(atPath: path) { return path }
    return nil
}

func ffmpegPath() -> String? { return findProgram(["ffmpeg"]) }

func sofficePath() -> String? {
    return findProgram(["soffice", "libreoffice"], extra: ["/Applications/LibreOffice.app/Contents/MacOS/soffice"])
}

final class DataBox {
    var data = Data()
}

/// Runs a program and returns its exit code and everything it printed.
func runProcess(_ path: String, _ args: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    let outBox = DataBox()
    let errBox = DataBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    process.waitUntilExit()
    group.wait()
    let text = (String(data: errBox.data, encoding: .utf8) ?? "") + (String(data: outBox.data, encoding: .utf8) ?? "")
    return (process.terminationStatus, text)
}

func lastChars(_ text: String, _ count: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= count { return trimmed }
    return String(trimmed.suffix(count))
}
