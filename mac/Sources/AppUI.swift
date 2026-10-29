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
    @Published var selectedCategory: String? = nil
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

// MARK: - Look

func categoryColor(_ category: String) -> Color {
    switch category {
    case "Organize": return .blue
    case "Optimize": return .green
    case "Convert to PDF": return .orange
    case "Convert from PDF": return .purple
    case "Edit": return .pink
    case "Review & security": return .teal
    case "Images": return .indigo
    case "Audio & video": return .cyan
    case "Documents": return .brown
    default: return brandColor
    }
}

func categorySymbol(_ category: String) -> String {
    switch category {
    case "Organize": return "square.stack.3d.up.fill"
    case "Optimize": return "bolt.fill"
    case "Convert to PDF": return "arrow.down.doc.fill"
    case "Convert from PDF": return "arrow.up.doc.fill"
    case "Edit": return "pencil.circle.fill"
    case "Review & security": return "lock.shield.fill"
    case "Images": return "photo.fill"
    case "Audio & video": return "play.rectangle.fill"
    case "Documents": return "doc.text.fill"
    default: return "square.grid.2x2.fill"
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.gray.opacity(0.18)))
            .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

extension View {
    func card() -> some View { return modifier(CardStyle()) }
}

final class FlagState: ObservableObject {
    @Published var on = false
}

struct IconBadge: View {
    let text: String
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.opacity(0.16)))
    }
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
    @StateObject private var hover = FlagState()
    private var hovering: Bool { return hover.on }

    private var missing: Bool { return tool.missingMessage() != nil }
    private var tint: Color { return categoryColor(tool.category) }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(text: tool.icon, color: tint, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name).font(.headline)
                    Text(tool.summary)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if missing {
                        Label("Needs an extra program", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hovering ? tint.opacity(0.7) : Color.gray.opacity(0.18), lineWidth: hovering ? 1.5 : 1)
            )
            .shadow(color: Color.black.opacity(hovering ? 0.14 : 0.05), radius: hovering ? 10 : 4, x: 0, y: hovering ? 4 : 1)
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in hover.on = inside }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct CategoryChip: View {
    let title: String
    let symbol: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(selected ? Color.white : color)
            .background(Capsule().fill(selected ? color : color.opacity(0.13)))
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

    private var visibleCategories: [String] {
        return categories.filter { category in
            let chosen = app.selectedCategory == nil || app.selectedCategory == category
            return chosen && !tools(in: category).isEmpty
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pagewright").font(.system(size: 30, weight: .bold, design: .rounded))
                Label("Everything happens on your Mac. Nothing is uploaded anywhere.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search a tool: merge, compress, resize, mp3, word…", text: $app.search)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
            if !app.search.isEmpty {
                Button(action: { app.search = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.gray.opacity(0.25)))
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryChip(title: "All", symbol: "square.grid.2x2.fill", color: brandColor, selected: app.selectedCategory == nil) {
                    app.selectedCategory = nil
                }
                ForEach(categories, id: \.self) { category in
                    CategoryChip(title: category, symbol: categorySymbol(category), color: categoryColor(category),
                                 selected: app.selectedCategory == category) {
                        app.selectedCategory = (app.selectedCategory == category) ? nil : category
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundColor(.secondary)
            Text("No tool found").font(.headline)
            Text("Try another word, or choose “All”.").foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                searchField
                chips
                if visibleCategories.isEmpty { emptyState }
                ForEach(visibleCategories, id: \.self) { category in
                    CategorySection(app: app, category: category, tools: tools(in: category))
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .background(
            LinearGradient(colors: [brandColor.opacity(0.10), Color.clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                .ignoresSafeArea()
        )
    }
}

struct CategorySection: View {
    @ObservedObject var app: AppState
    let category: String
    let tools: [Tool]

    var body: some View {
        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: categorySymbol(category)).foregroundColor(categoryColor(category))
                    Text(category).font(.title3.weight(.semibold))
                    Text("\(tools.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.gray.opacity(0.15)))
                }
                .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14, alignment: .top)], spacing: 14) {
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
    @StateObject private var drag = FlagState()
    private var dragging: Bool { return drag.on }
    private var dragBinding: Binding<Bool> { return Binding(get: { drag.on }, set: { drag.on = $0 }) }

    private var tint: Color { return categoryColor(model.tool.category) }

    private var visibleFields: [Field] {
        return model.fields.filter { field in
            guard let condition = field.showIf else { return true }
            return (model.values[condition.0] ?? "") == condition.1
        }
    }

    private var errorShown: Binding<Bool> {
        return Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private func fileSymbol(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return "doc.richtext.fill" }
        if pictureExts.contains(ext) { return "photo.fill" }
        if audioExts.contains(ext) { return "music.note" }
        if videoExts.contains(ext) { return "film.fill" }
        return "doc.fill"
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 34))
                .foregroundColor(dragging ? brandColor : Color.secondary)
            Text("Drop files here").font(.headline)
            Text("or").font(.caption).foregroundColor(.secondary)
            Button("Choose files…") { model.chooseFiles() }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dragging ? brandColor.opacity(0.08) : Color.gray.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dragging ? brandColor : Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
    }

    private var filesList: some View {
        List {
            ForEach(model.files, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(systemName: fileSymbol(url)).foregroundColor(tint).frame(width: 20)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(url.deletingLastPathComponent().path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Button(action: { model.remove(url) }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onMove { source, destination in model.files.move(fromOffsets: source, toOffset: destination) }
        }
        .frame(minHeight: 220)
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.files.isEmpty ? "Files" : "Files (\(model.files.count))").font(.headline)
            Text("Accepted: " + model.tool.accepts.prefix(6).map { $0.uppercased() }.joined(separator: ", "))
                .font(.caption).foregroundColor(.secondary)
            if model.files.isEmpty { dropZone } else { filesList }
            if !model.files.isEmpty {
                HStack {
                    Button("Add files…") { model.chooseFiles() }
                    Button("Clear") { model.clear() }
                    Spacer()
                    if model.tool.ordered { Text("Drag the rows to change the order").font(.caption).foregroundColor(.secondary) }
                }
                .disabled(model.running)
            }
        }
        .padding(14)
        .card()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(brandColor, lineWidth: dragging ? 2 : 0))
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
        .card()
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Done: \(plural(model.results.count, "file")) created").font(.headline)
            }
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
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.green.opacity(0.35)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: { app.home() }) {
                Label("All tools", systemImage: "chevron.left").font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(brandColor)
            HStack(spacing: 14) {
                IconBadge(text: model.tool.icon, color: tint, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.tool.name).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(model.tool.summary).foregroundColor(.secondary)
                }
            }
        }
    }

    private var saveRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundColor(.secondary)
            Text("Save to:").foregroundColor(.secondary)
            Text(model.outputPath.isEmpty ? "the same folder as the original file" : model.outputPath)
                .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose folder…") { model.chooseOutput() }
            Button("Next to the original") { model.setOutput("") }
        }
    }

    private var runRow: some View {
        HStack(spacing: 12) {
            Button(action: { model.start() }) {
                Label(model.tool.name, systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                filesPanel
                optionsPanel
            }
            saveRow
            runRow
            if !model.status.isEmpty { Text(model.status).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !model.results.isEmpty { resultsPanel }
            Spacer(minLength: 0)
        }
        .padding(24)
        .onDrop(of: [UTType.fileURL], isTargeted: dragBinding) { providers in model.handleDrop(providers) }
        .alert("Pagewright", isPresented: errorShown) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
