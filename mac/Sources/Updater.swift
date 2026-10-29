import Foundation
import AppKit
import SwiftUI

// The "Update" button: looks for changes in the project folder (and new commits on GitHub, if there is a remote),
// rebuilds the app with build.sh into a temporary folder, swaps it in place of the running one and reopens it.
// The old app is kept in ~/Library/Application Support/Pagewright/Previous.

struct UpdateCheck {
    var changedFiles: [String] = []
    var newCommits: [String] = []
    var note: String = ""
    var hasUpdate: Bool { return !changedFiles.isEmpty || !newCommits.isEmpty }
}

final class ProcessBox: @unchecked Sendable {
    var process: Process? = nil
}

func shellQuote(_ text: String) -> String {
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Run by /bin/sh after the update was built. It waits until the running app has really quit, swaps the apps, keeps the
/// old one as a backup, reopens Pagewright, and writes what it does to update.log. If a step fails it puts things back
/// and shows an alert instead of silently leaving you without the app.
let updateSwapScript = #"""
trap '' HUP
exec >> "$PW_LOG" 2>&1
echo "=== $(date) update started (waiting for pid $PW_PID)"
fail() {
  echo "FAILED: $1"
  if [ -d "$PW_DEST" ]; then open "$PW_DEST"; fi
  osascript -e "display alert \"Pagewright could not update itself\" message \"$1 More details: $PW_LOG\"" >/dev/null 2>&1
  exit 1
}
n=0
while kill -0 "$PW_PID" 2>/dev/null; do
  n=$((n + 1))
  if [ "$n" -gt 150 ]; then fail "The old app did not quit."; fi
  sleep 0.2
done
echo "old app has quit"
mkdir -p "$PW_BACKUP" || fail "Could not create the backup folder."
rm -rf "$PW_BACKUP/Pagewright.app"
mv "$PW_DEST" "$PW_BACKUP/Pagewright.app" || fail "Could not move the old app away (macOS may ask for the App Management permission: System Settings > Privacy & Security)."
if [ -e "$PW_DEST" ]; then
  mv "$PW_BACKUP/Pagewright.app" "$PW_DEST.restored" 2>/dev/null
  fail "The old app is still in place."
fi
if ! mv "$PW_NEW" "$PW_DEST"; then
  mv "$PW_BACKUP/Pagewright.app" "$PW_DEST"
  fail "Could not put the new app in place. The old one was restored."
fi
echo "new app installed in $PW_DEST"
sleep 0.5
open "$PW_DEST"
echo "reopened"
"""#

/// Runs a command with its output merged; calls onLine for every line. Returns the exit code and the whole output.
func runCommand(_ exe: String, _ args: [String], cwd: URL? = nil, timeout: Double? = nil,
                box: ProcessBox? = nil, onLine: ((String) -> Void)? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    if let cwd = cwd { process.currentDirectoryURL = cwd }
    var environment = ProcessInfo.processInfo.environment
    // an app opened from the Finder doesn't get the shell's PATH
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    environment["GIT_TERMINAL_PROMPT"] = "0"           // never wait for a password that nobody can type
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "Could not start \(exe): \(error.localizedDescription)")
    }
    box?.process = process
    if let timeout = timeout {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
    }
    var collected = ""
    var pending = ""
    let handle = pipe.fileHandleForReading
    while true {
        let data = handle.availableData
        if data.isEmpty { break }
        let chunk = String(data: data, encoding: .utf8) ?? ""
        collected += chunk
        pending += chunk
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            onLine?(line)
        }
    }
    if !pending.isEmpty { onLine?(pending) }
    process.waitUntilExit()
    box?.process = nil
    return (process.terminationStatus, collected)
}

enum UpdateInspector {
    static let git = "/usr/bin/git"

    /// Source files modified after the running app was built.
    static func changedFiles(in source: URL, since builtAt: Double) -> [String] {
        if builtAt <= 0 { return [] }
        let fm = FileManager.default
        var files: [URL] = [source.appendingPathComponent("build.sh"), source.appendingPathComponent("Resources/icon.png")]
        if let items = fm.enumerator(at: source.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
            for case let url as URL in items where url.pathExtension == "swift" { files.append(url) }
        }
        var changed: [String] = []
        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, date.timeIntervalSince1970 > builtAt + 1 {
                changed.append(url.lastPathComponent)
            }
        }
        return changed.sorted()
    }

    static func inspect(source: URL, builtAt: Double) -> UpdateCheck {
        var result = UpdateCheck()
        result.changedFiles = changedFiles(in: source, since: builtAt)
        guard FileManager.default.isExecutableFile(atPath: git),
              runCommand(git, ["-C", source.path, "rev-parse", "--is-inside-work-tree"], timeout: 10).status == 0 else {
            return result
        }
        let upstream = runCommand(git, ["-C", source.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: 10)
        if upstream.status != 0 {
            result.note = "No remote repository is set up, so only the files in the folder were checked."
            return result
        }
        let fetch = runCommand(git, ["-C", source.path, "fetch", "--quiet"], timeout: 30)
        if fetch.status != 0 {
            result.note = "Could not reach the remote repository (\(lastChars(fetch.output, 120))). Only the files in the folder were checked."
            return result
        }
        let list = runCommand(git, ["-C", source.path, "log", "--oneline", "-n", "8", "HEAD..@{u}"], timeout: 10)
        if list.status == 0 {
            result.newCommits = list.output.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        }
        return result
    }
}

@MainActor
final class Updater: ObservableObject {
    enum Phase { case idle, checking, upToDate, available, building, failed, finished }

    @Published var phase: Phase = .idle
    @Published var message: String = ""
    @Published var log: [String] = []
    @Published var check = UpdateCheck()
    @Published var sourcePath: String = ""
    private let box = ProcessBox()
    private let flag = CancelFlag()

    init() {
        let embedded = (Bundle.main.object(forInfoDictionaryKey: "PagewrightSourceDir") as? String) ?? ""
        let saved = UserDefaults.standard.string(forKey: "source_dir") ?? ""
        sourcePath = saved.isEmpty ? embedded : saved
    }

    var builtAt: Double {
        return Double((Bundle.main.object(forInfoDictionaryKey: "PagewrightBuiltAt") as? String) ?? "") ?? 0
    }

    /// The project folder, if it really contains build.sh and Sources.
    var sourceURL: URL? {
        if sourcePath.isEmpty { return nil }
        let url = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("build.sh").path) && fm.fileExists(atPath: url.appendingPathComponent("Sources").path) {
            return url
        }
        return nil
    }

    var busy: Bool { return phase == .checking || phase == .building }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder that contains build.sh and Sources (the mac folder of your project)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            UserDefaults.standard.set(url.path, forKey: "source_dir")
            if sourceURL == nil {
                phase = .failed
                message = "That folder doesn't contain build.sh and a Sources folder."
            } else {
                phase = .idle
                message = ""
            }
        }
    }

    // MARK: looking for changes

    func checkForUpdates() {
        if busy { return }
        guard let source = sourceURL else {
            phase = .failed
            message = "Choose the folder of your Pagewright project (the one with build.sh and Sources)."
            return
        }
        phase = .checking
        message = "Looking for changes…"
        log = []
        check = UpdateCheck()
        let built = builtAt
        DispatchQueue.global(qos: .userInitiated).async {
            let result = UpdateInspector.inspect(source: source, builtAt: built)
            Task { @MainActor in self.finishCheck(result) }
        }
    }

    private func finishCheck(_ result: UpdateCheck) {
        check = result
        if result.hasUpdate {
            phase = .available
            message = "There is something new."
        } else {
            phase = .upToDate
            message = result.note.isEmpty ? "Pagewright is up to date." : "Nothing new found. " + result.note
        }
    }

    // MARK: building and replacing the app

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private func fail(_ text: String) {
        phase = .failed
        message = text
    }

    func cancel() {
        if phase == .building {
            flag.isSet = true
            box.process?.terminate()
        }
    }

    func installUpdate() {
        if busy { return }
        guard let source = sourceURL else { checkForUpdates(); return }
        phase = .building
        message = "Building… this takes a minute or two. The current app keeps working meanwhile."
        log = []
        flag.isSet = false
        let pull = !check.newCommits.isEmpty
        let destination = Bundle.main.bundleURL
        let box = self.box
        let flag = self.flag
        DispatchQueue.global(qos: .userInitiated).async {
            func add(_ line: String) { Task { @MainActor in self.appendLog(line) } }
            func stop(_ text: String) { Task { @MainActor in self.fail(text) } }

            if pull {
                add("Getting the new version from the repository…")
                let result = runCommand(UpdateInspector.git, ["-C", source.path, "pull", "--ff-only"], timeout: 90, box: box, onLine: add)
                if result.status != 0 {
                    stop("Could not get the new version automatically. If you changed files in the folder, save or discard those changes first (git status).")
                    return
                }
            }
            if !FileManager.default.isExecutableFile(atPath: "/usr/bin/swiftc") {
                stop("The Command Line Tools are not installed. In Terminal: xcode-select --install")
                return
            }
            let parent = destination.deletingLastPathComponent().path
            if !FileManager.default.isWritableFile(atPath: parent) {
                stop("Pagewright can't replace itself in \(parent) (no permission). Move the app to Applications, or build it by hand.")
                return
            }

            let work = FileManager.default.temporaryDirectory.appendingPathComponent("pagewright-update-" + UUID().uuidString)
            let newApp = work.appendingPathComponent("Pagewright.app")
            add("Building…")
            let build = runCommand("/bin/bash", [source.appendingPathComponent("build.sh").path, work.path], cwd: source, box: box, onLine: add)
            if flag.isSet {
                try? FileManager.default.removeItem(at: work)
                Task { @MainActor in self.phase = .idle; self.message = "Cancelled. Nothing was changed." }
                return
            }
            if build.status != 0 || !FileManager.default.fileExists(atPath: newApp.path) {
                stop("The build failed, so the current app was not touched. The log below shows why.")
                return
            }

            // hand over to a small helper that waits for this app to quit, swaps the apps and reopens it
            let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pagewright")
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", updateSwapScript]
            var environment = ProcessInfo.processInfo.environment
            environment["PW_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment["PW_DEST"] = destination.path
            environment["PW_NEW"] = newApp.path
            environment["PW_BACKUP"] = support.appendingPathComponent("Previous").path
            environment["PW_LOG"] = support.appendingPathComponent("update.log").path
            helper.environment = environment
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            helper.standardInput = FileHandle.nullDevice
            do {
                try helper.run()
            } catch {
                stop("Built, but could not start the installer: \(error.localizedDescription)")
                return
            }
            Task { @MainActor in
                self.phase = .finished
                self.message = "Done. Pagewright is restarting… (if it doesn't come back: ~/Library/Application Support/Pagewright/update.log)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }   // in case something delays the quit
            }
        }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - The window of the Update button

struct UpdateView: View {
    @ObservedObject var updater: Updater
    let close: () -> Void

    private var showLog: Bool { return updater.phase == .building || (updater.phase == .failed && !updater.log.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update Pagewright").font(.title2).bold()
            HStack {
                Text("Project folder:").foregroundColor(.secondary)
                Text(updater.sourcePath.isEmpty ? "not set" : updater.sourcePath).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { updater.chooseSource() }.disabled(updater.busy)
            }
            HStack(spacing: 8) {
                if updater.busy { ProgressView().controlSize(.small) }
                Text(updater.message.isEmpty ? "Press “Check for updates” to look for changes." : updater.message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !updater.check.changedFiles.isEmpty {
                Text("Files changed in the folder: " + updater.check.changedFiles.joined(separator: ", "))
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !updater.check.newCommits.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New on the repository:").font(.callout).foregroundColor(.secondary)
                    ForEach(updater.check.newCommits, id: \.self) { commit in
                        Text(commit).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            if showLog {
                ScrollView {
                    Text(updater.log.suffix(60).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
            }
            HStack {
                if updater.phase == .building {
                    Button("Cancel") { updater.cancel() }
                } else {
                    Button("Check for updates") { updater.checkForUpdates() }.disabled(updater.busy)
                    if updater.phase == .available {
                        Button("Update and restart") { updater.installUpdate() }.buttonStyle(.borderedProminent).tint(brandColor)
                    }
                    if updater.phase == .upToDate || updater.phase == .failed {
                        Button("Rebuild anyway") { updater.installUpdate() }
                    }
                    if updater.phase == .failed && !updater.log.isEmpty { Button("Copy log") { updater.copyLog() } }
                }
                Spacer()
                Button("Close") { close() }.disabled(updater.phase == .building)
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}
