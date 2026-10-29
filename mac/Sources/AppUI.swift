import SwiftUI
import AppKit
import UniformTypeIdentifiers

let brandColor = Color(red: 0.9, green: 0.2, blue: 0.18)

// MARK: - State

@MainActor
final class AppState: ObservableObject {
    @Published var page: ToolPageModel? = nil
    @Published var search: String = ""
    @Published var showUpdate = false
    let updater = Updater()

    func open(_ tool: Tool, files: [URL] = []) {
        if let message = tool.missingMessage() {
            let alert = NSAlert()
            alert.messageText = "\(tool.name) needs an extra free program"
            alert.informativeText = message
            alert.runModal()
            return
        }
        let model = ToolPageModel(tool: tool)
        model.addFiles(files)
        page = model
    }

    func home() {
        page?.cancel()
        page = nil
    }
}

final class CancelFlag: @unchecked Sendable {
    var isSet = false
}

@MainActor
final class ToolPageModel: ObservableObject {
    let tool: Tool
    let fields: [Field]
    @Published var files: [URL] = []
    @Published var values: [String: String] = [:]
    @Published var running = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var results: [URL] = []
    @Published var errorMessage: String? = nil
    @Published var outputPath: String
    private let flag = CancelFlag()

    init(tool: Tool) {
        self.tool = tool
        var list = tool.fields
        if tool.askPassword {
            list.append(Field(key: "password", label: "PDF password", kind: .password, help: "Only needed if the PDF is protected."))
        }
        self.fields = list
        self.outputPath = UserDefaults.standard.string(forKey: "output_dir") ?? ""
        var initial: [String: String] = [:]
        for field in list { initial[field.key] = field.defaultValue }
        self.values = initial
    }

    var canRun: Bool {
        return !running && files.count >= tool.minFiles && tool.missingMessage() == nil
    }

    // MARK: files

    func addFiles(_ urls: [URL]) {
        var expanded: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let inner = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                expanded += inner.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                expanded.append(url)
            }
        }
        var added = 0
        var refused = false
        for url in expanded {
            if !tool.accepts.contains(url.pathExtension.lowercased()) { continue }
            if files.contains(url) { continue }
            if let limit = tool.maxFiles, files.count >= limit { refused = true; break }
            files.append(url)
            added += 1
        }
        if refused {
            status = "This tool takes at most \(tool.maxFiles ?? 0) files."
        } else if added == 0 && !urls.isEmpty {
            status = "None of those files can be used with this tool."
        } else {
            status = ""
        }
        if added > 0 { results = [] }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { Task { @MainActor in self.addFiles([url]) } }
            }
        }
        return true
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
    func clear() { files = []; results = []; status = "" }

    // MARK: output folder

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { setOutput(url.path) }
    }

    func setOutput(_ path: String) {
        outputPath = path
        UserDefaults.standard.set(path, forKey: "output_dir")
    }

    // MARK: running

    func start() {
        if !canRun { return }
        running = true
        progress = 0
        status = ""
        results = []
        let inputs = files
        let options = Options(values: values.mapValues { $0 as Any })
        let out: URL? = outputPath.isEmpty ? nil : URL(fileURLWithPath: outputPath, isDirectory: true)
        let tool = self.tool
        let flag = self.flag
        flag.isSet = false
        let report: Progress = { fraction, message in
            if flag.isSet { throw CancelledError() }
            Task { @MainActor in
                self.progress = fraction
                if !message.isEmpty { self.status = message }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var outputs: [URL] = []
            var failure: String? = nil
            var wasCancelled = false
            do {
                outputs = try tool.run(inputs, options, out, report)
            } catch is CancelledError {
                wasCancelled = true
            } catch {
                failure = error.localizedDescription
            }
            Task { @MainActor in self.finish(outputs, failure, wasCancelled) }
        }
    }

    private func finish(_ outputs: [URL], _ failure: String?, _ cancelled: Bool) {
        running = false
        if cancelled {
            status = "Cancelled."
        } else if let failure = failure {
            status = ""
            errorMessage = failure
        } else {
            results = outputs
            progress = 1
        }
    }

    func cancel() {
        if running {
            flag.isSet = true
            status = "Cancelling…"
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

// MARK: - Views

struct RootView: View {
    @ObservedObject var app: AppState

    var body: some View {
        Group {
            if let page = app.page {
                ToolPageView(model: page, app: app)
            } else {
                HomeView(app: app)
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .sheet(isPresented: $app.showUpdate) {
            UpdateView(updater: app.updater) { app.showUpdate = false }
        }
    }
}

struct ToolCardView: View {
    let tool: Tool
    let action: () -> Void

    private var missing: Bool { return tool.missingMessage() != nil }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(tool.icon).font(.system(size: 24))
                    Text(tool.name).font(.headline)
                    Spacer(minLength: 0)
                }
                Text(missing ? "Needs an extra program. Click to see which." : tool.summary)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3)))
            .opacity(missing ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }
}

struct HomeView: View {
    @ObservedObject var app: AppState

    private func matches(_ tool: Tool) -> Bool {
        let words = app.search.lowercased().split(separator: " ").map { String($0) }
        if words.isEmpty { return true }
        let haystack = "\(tool.name) \(tool.summary) \(tool.keywords) \(tool.category)".lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    private func tools(in category: String) -> [Tool] {
        return allTools.filter { $0.category == category && matches($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pagewright").font(.system(size: 30, weight: .bold))
                Text("PDF, picture, audio, video and document tools, all on your Mac. Nothing is uploaded anywhere.")
                    .foregroundColor(.secondary)
                TextField("Search a tool: merge, compress, resize, mp3, word…", text: $app.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.bottom, 6)
                ForEach(categories, id: \.self) { category in
                    CategorySection(app: app, category: category, tools: tools(in: category))
                }
            }
            .padding(28)
        }
    }
}

struct CategorySection: View {
    @ObservedObject var app: AppState
    let category: String
    let tools: [Tool]

    var body: some View {
        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(category).font(.title3).bold().padding(.top, 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(tools, id: \.id) { tool in
                        ToolCardView(tool: tool) { app.open(tool) }
                    }
                }
            }
        }
    }
}

struct FieldRow: View {
    @ObservedObject var model: ToolPageModel
    let field: Field

    private var text: Binding<String> {
        return Binding(get: { model.values[field.key] ?? "" }, set: { model.values[field.key] = $0 })
    }

    private var flag: Binding<Bool> {
        return Binding(get: { (model.values[field.key] ?? "") == "true" }, set: { model.values[field.key] = $0 ? "true" : "false" })
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { model.values[field.key] = url.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch field.kind {
            case .bool:
                Toggle(field.label, isOn: flag)
            case .choice:
                HStack {
                    Text(field.label)
                    Spacer()
                    Picker("", selection: text) {
                        ForEach(field.choices, id: \.value) { choice in Text(choice.label).tag(choice.value) }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            case .password:
                Text(field.label)
                SecureField("", text: text).textFieldStyle(.roundedBorder)
            case .multiline:
                Text(field.label)
                TextEditor(text: text).frame(height: 80).border(Color.gray.opacity(0.4))
            case .file:
                Text(field.label)
                HStack {
                    TextField("", text: text).textFieldStyle(.roundedBorder)
                    Button("Browse…") { browse() }
                }
            default:
                Text(field.label)
                TextField(field.placeholder, text: text).textFieldStyle(.roundedBorder)
            }
            if !field.help.isEmpty {
                Text(field.help).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ToolPageView: View {
    @ObservedObject var model: ToolPageModel
    @ObservedObject var app: AppState

    private var visibleFields: [Field] {
        return model.fields.filter { field in
            guard let condition = field.showIf else { return true }
            return (model.values[condition.0] ?? "") == condition.1
        }
    }

    private var errorShown: Binding<Bool> {
        return Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.files.isEmpty ? "Files" : "Files (\(model.files.count))").font(.headline)
            Text("Drop files here, or use “Add files”.  Accepted: " + model.tool.accepts.prefix(6).map { $0.uppercased() }.joined(separator: ", "))
                .font(.caption).foregroundColor(.secondary)
            List {
                ForEach(model.files, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(url.deletingLastPathComponent().path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Button("✕") { model.remove(url) }.buttonStyle(.plain).foregroundColor(.secondary)
                    }
                }
                .onMove { source, destination in model.files.move(fromOffsets: source, toOffset: destination) }
            }
            .frame(minHeight: 220)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in model.handleDrop(providers) }
            HStack {
                Button("Add files…") { model.chooseFiles() }
                Button("Clear") { model.clear() }
                Spacer()
                if model.tool.ordered { Text("Drag the rows to change the order").font(.caption).foregroundColor(.secondary) }
            }
            .disabled(model.running)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Options").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.fields.isEmpty {
                        Text("This tool has no options. Add your files and press the button.").foregroundColor(.secondary)
                    }
                    ForEach(visibleFields, id: \.key) { field in
                        FieldRow(model: model, field: field)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("✓ Done: \(plural(model.results.count, "file")) created").foregroundColor(.green).font(.headline)
            if !model.tool.hint.isEmpty { Text(model.tool.hint).font(.caption).foregroundColor(.secondary) }
            ForEach(model.results.prefix(6), id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show") { model.reveal(url) }
                    Button("Open") { model.open(url) }
                }
            }
            if model.results.count > 6 { Text("…and \(model.results.count - 6) more").font(.caption).foregroundColor(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("← All tools") { app.home() }.buttonStyle(.link)
                Spacer()
            }
            Text("\(model.tool.icon)  \(model.tool.name)").font(.system(size: 26, weight: .bold))
            Text(model.tool.summary).foregroundColor(.secondary)
            HStack(alignment: .top, spacing: 14) {
                filesPanel
                optionsPanel
            }
            HStack {
                Text("Save to:").foregroundColor(.secondary)
                Text(model.outputPath.isEmpty ? "the same folder as the original file" : model.outputPath)
                    .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose folder…") { model.chooseOutput() }
                Button("Next to the original") { model.setOutput("") }
            }
            HStack(spacing: 12) {
                Button(action: { model.start() }) {
                    Text(model.tool.name).fontWeight(.bold).padding(.horizontal, 16).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(brandColor)
                .controlSize(.large)
                .disabled(!model.canRun)
                if model.running {
                    Button("Cancel") { model.cancel() }
                    ProgressView(value: model.progress)
                }
            }
            if !model.status.isEmpty { Text(model.status).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !model.results.isEmpty { resultsPanel }
            Spacer(minLength: 0)
        }
        .padding(24)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in model.handleDrop(providers) }
        .alert("Pagewright", isPresented: errorShown) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
