import LegadoCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct ManageView: View {
    @Environment(LibraryStore.self) private var library
    @State private var importingBackup = false
    @State private var export: JSONExport?
    @State private var exportingBackup = false
    @State private var activeOperation = false
    @State private var pendingRestore: URL?
    @State private var confirmRestore = false

    var body: some View {
        List {
            Section("内容") {
                NavigationLink {
                    BookSourcesView()
                } label: {
                    LabeledContent {
                        Text(library.sources.count.formatted())
                    } label: { Label("书源", systemImage: "globe") }
                }
                NavigationLink {
                    ReplacementRulesView()
                } label: {
                    LabeledContent {
                        Text(library.replacements.count.formatted())
                    } label: { Label("净化替换", systemImage: "text.badge.minus") }
                }
                NavigationLink {
                    FeedSubscriptionsView()
                } label: {
                    Label("RSS 订阅", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            Section {
                Button("导出备份", systemImage: "square.and.arrow.up") { exportBackup() }
                Button("恢复备份", systemImage: "arrow.clockwise") { importingBackup = true }
                NavigationLink {
                    WebDAVBackupView()
                } label: { Label("WebDAV 备份", systemImage: "externaldrive.badge.icloud") }
                if activeOperation { ProgressView("处理中…") }
            } header: {
                Text("备份与恢复")
            } footer: {
                Text("备份包含书架、正文缓存、阅读进度、书签、书源、净化规则和订阅列表。")
            }
            .disabled(activeOperation)
            Section("关于") {
                LabeledContent("阅读", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Link(destination: URL(string: "https://github.com/HapeLee/legado-with-MD3")!) {
                    Label("参考项目 · Legado with MD3", systemImage: "arrow.up.right.square")
                }
            }
        }
        .navigationTitle("管理")
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let error): library.report("无法打开备份", error: error)
            case .success(let url):
                pendingRestore = url
                confirmRestore = true
            }
        }
        .fileExporter(isPresented: $exportingBackup, item: export, contentTypes: [.json], defaultFilename: "阅读备份",
                      onCompletion: { result in
                          if case .failure(let error) = result { library.report("导出失败", error: error) }
                          export = nil
                      }, onCancellation: { export = nil })
        .confirmationDialog("恢复此备份？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复并替换", role: .destructive) { restore() }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("应用中的书架、进度、书源和净化规则将替换为备份内容。")
        }
    }

    private func exportBackup() {
        activeOperation = true
        Task {
            defer { activeOperation = false }
            do {
                export = JSONExport(data: try await library.makeBackup())
                exportingBackup = true
            } catch { library.report("备份失败", error: error) }
        }
    }

    private func restore() {
        guard let url = pendingRestore else { return }
        pendingRestore = nil
        activeOperation = true
        Task {
            defer { activeOperation = false }
            do {
                try await library.restoreBackup(from: url)
                library.message = LibraryMessage(title: "恢复成功", detail: "已恢复 \(library.books.count) 本书和 \(library.sources.count) 个书源。")
            } catch { library.report("恢复失败", error: error) }
        }
    }
}

private struct JSONExport: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { item in item.data }
    }
}

private struct BookSourcesView: View {
    @Environment(LibraryStore.self) private var library
    @State private var importing = false
    @State private var showURL = false
    @State private var showPaste = false
    @State private var sourceURL = ""
    @State private var editor: SourceEditorItem?
    @State private var search = ""
    @State private var pendingRemoval: BookSource?
    @State private var confirmRemoval = false
    @State private var busy = false
    @State private var export: JSONExport?
    @State private var exporting = false

    private var visibleSources: [BookSource] {
        library.sources.filter { source in
            search.isEmpty || source.bookSourceName.localizedCaseInsensitiveContains(search) ||
            source.bookSourceUrl.localizedCaseInsensitiveContains(search) ||
            (source.bookSourceGroup?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        List {
            if busy { ProgressView("导入中…") }
            ForEach(visibleSources) { source in
                HStack(spacing: 10) {
                    Button {
                        openEditor(source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.bookSourceName).font(.headline).foregroundStyle(.primary)
                            Text(source.bookSourceGroup ?? source.bookSourceUrl)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Toggle("启用 \(source.bookSourceName)", isOn: Binding(get: {
                        library.source(source.id)?.enabled ?? false
                    }, set: { enabled in
                        var edit = source
                        edit.enabled = enabled
                        do { try library.replaceSource(edit, originalID: source.id) }
                        catch { library.report("保存失败", error: error) }
                    }))
                    .labelsHidden()
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        pendingRemoval = source
                        confirmRemoval = true
                    }
                }
            }
        }
        .overlay {
            if visibleSources.isEmpty && !busy {
                if search.isEmpty {
                    ContentUnavailableView("没有书源", systemImage: "globe",
                                           description: Text("使用右上角的添加菜单导入 Legado 3.0 书源。"))
                } else { ContentUnavailableView.search(text: search) }
            }
        }
        .navigationTitle("书源")
        .searchable(text: $search, prompt: "名称、分组或地址")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("添加和导出书源", systemImage: "plus") {
                    Button("从文件导入", systemImage: "folder") { importing = true }
                    Button("从网址导入", systemImage: "link") { showURL = true }
                    Button("粘贴书源 JSON", systemImage: "doc.on.clipboard") { showPaste = true }
                    Button("新建书源", systemImage: "square.and.pencil") {
                        editor = SourceEditorItem(text: Self.template)
                    }
                    Button("导出书源", systemImage: "square.and.arrow.up") {
                        do {
                            export = JSONExport(data: try library.exportSources())
                            exporting = true
                        } catch { library.report("导出失败", error: error) }
                    }
                    .disabled(library.sources.isEmpty)
                }
                .disabled(busy)
            }
        }
        .alert("从网址导入", isPresented: $showURL) {
            TextField("https://", text: $sourceURL).keyboardType(.URL).textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {}
            Button("导入") { importURL() }
        }
        .confirmationDialog("删除此书源？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let source = pendingRemoval else { return }
                do { try library.deleteSource(source.id) }
                catch { library.report("删除失败", error: error) }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("此书源的已缓存章节仍可阅读。")
        }
        .sheet(isPresented: $showPaste) { SourceEditorView(item: SourceEditorItem(text: "", isImport: true)) }
        .sheet(item: $editor) { SourceEditorView(item: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .failure(let error): library.report("无法打开书源文件", error: error)
            case .success(let url): performImport { try await library.importSourceFile(url) }
            }
        }
        .fileExporter(isPresented: $exporting, item: export, contentTypes: [.json], defaultFilename: "myBookSource",
                      onCompletion: { result in
                          if case .failure(let error) = result { library.report("导出失败", error: error) }
                          export = nil
                      }, onCancellation: { export = nil })
    }

    private func importURL() {
        let input = sourceURL
        performImport {
            let url = try LibraryStore.webURL(input)
            var request = URLRequest(url: url, timeoutInterval: 25)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw LibraryError.rejectedHTTP(http.statusCode)
            }
            let size = try data.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= 16 * 1024 * 1024 else { throw LibraryError.tooLarge }
            return try await library.importSources(Data(contentsOf: data, options: .mappedIfSafe))
        }
    }

    private func performImport(_ operation: @escaping () async throws -> Int) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let count = try await operation()
                library.message = LibraryMessage(title: "书源已导入", detail: "共处理 \(count) 个书源。")
            } catch { library.report("导入失败", error: error) }
        }
    }

    private func openEditor(_ source: BookSource) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(source)
            editor = SourceEditorItem(originalID: source.id, text: String(decoding: data, as: UTF8.self))
        } catch { library.report("无法打开书源", error: error) }
    }

    private static let template = """
    {
      "bookSourceName": "",
      "bookSourceUrl": "https://",
      "enabled": true,
      "searchUrl": "",
      "ruleSearch": {"bookList": "", "name": "", "author": "", "bookUrl": ""},
      "ruleBookInfo": {"tocUrl": ""},
      "ruleToc": {"chapterList": "", "chapterName": "", "chapterUrl": ""},
      "ruleContent": {"content": ""}
    }
    """
}

private struct SourceEditorItem: Identifiable {
    let id = UUID()
    var originalID: String?
    let text: String
    var isImport = false
}

private struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    let item: SourceEditorItem
    @State private var text: String
    @State private var editingError: String?
    @State private var saving = false

    init(item: SourceEditorItem) {
        self.item = item
        text = item.text
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let editingError {
                    Text(editingError).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("书源 JSON")
                    .padding(.horizontal, 8)
            }
            .navigationTitle(item.isImport ? "粘贴书源 JSON" : "编辑书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item.isImport ? "导入" : "保存") { save() }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        saving = true
        let data = Data(text.utf8)
        Task {
            defer { saving = false }
            do {
                if let id = item.originalID {
                    let sources = try BookSource.decodeImport(data)
                    guard sources.count == 1, let source = sources.first else { throw LibraryError.invalidSource }
                    try library.replaceSource(source, originalID: id)
                } else {
                    _ = try await library.importSources(data)
                }
                dismiss()
            } catch { editingError = error.localizedDescription }
        }
    }
}

private struct ReplacementRulesView: View {
    @Environment(LibraryStore.self) private var library
    @State private var editor: TextReplacement?

    var body: some View {
        List {
            ForEach(library.replacements) { rule in
                Button {
                    editor = rule
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.name.isEmpty ? rule.pattern : rule.name).foregroundStyle(.primary).lineLimit(2)
                        Text(rule.isEnabled ? (rule.isRegex ? "正则表达式" : "纯文本") : "已停用")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                do { try library.deleteReplacements(offsets) }
                catch { library.report("删除失败", error: error) }
            }
            .onMove { offsets, destination in
                do { try library.moveReplacements(offsets, to: destination) }
                catch { library.report("排序失败", error: error) }
            }
        }
        .overlay {
            if library.replacements.isEmpty {
                ContentUnavailableView("没有净化规则", systemImage: "text.badge.minus",
                                       description: Text("添加纯文本或正则表达式规则，用来删除或替换正文。"))
            }
        }
        .navigationTitle("净化替换")
        .toolbar {
            if !library.replacements.isEmpty { ToolbarItem(placement: .topBarLeading) { EditButton() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加规则", systemImage: "plus") { editor = TextReplacement() }
            }
        }
        .sheet(item: $editor) { ReplacementEditor(rule: $0) }
    }
}

private struct ReplacementEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @State var rule: TextReplacement
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("规则名称", text: $rule.name)
                TextField("匹配内容", text: $rule.pattern, axis: .vertical).autocorrectionDisabled()
                TextField("替换为（留空则删除）", text: $rule.replacement, axis: .vertical).autocorrectionDisabled()
                Toggle("使用正则表达式", isOn: $rule.isRegex)
                Toggle("启用", isOn: $rule.isEnabled)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("编辑净化规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try library.saveReplacement(rule); dismiss() }
                        catch { failure = error.localizedDescription }
                    }
                    .disabled(rule.pattern.isEmpty)
                }
            }
        }
    }
}
