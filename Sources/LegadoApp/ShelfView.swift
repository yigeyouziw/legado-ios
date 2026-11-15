import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("shelf.list") private var listLayout = false
    @State private var importing = false
    @State private var pickFolder = false
    @State private var importTask: Task<Void, Never>?
    @State private var reader: ReaderDestination?
    @State private var filter = ShelfFilter.all

    private var visibleBooks: [LibraryBook] {
        library.books.filter { book in
            switch filter {
            case .all: true
            case .local: book.isLocal
            case .online: !book.isLocal
            }
        }.sorted { ($0.lastRead ?? $0.addedAt) > ($1.lastRead ?? $1.addedAt) }
    }

    var body: some View {
        Group {
            if library.books.isEmpty {
                ContentUnavailableView {
                    Label("书架还是空的", systemImage: "books.vertical")
                } description: {
                    Text("从文件导入 TXT 或 EPUB，也可以到「搜书」添加在线书籍。")
                } actions: {
                    Button("导入书籍", systemImage: "plus") { openPicker(folder: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(importTask != nil)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let featured = visibleBooks.filter({ $0.lastRead != nil }).max(by: {
                            ($0.lastRead ?? .distantPast) < ($1.lastRead ?? .distantPast)
                        }) {
                            continueCard(featured)
                        }
                        Picker("书籍类型", selection: $filter) {
                            ForEach(ShelfFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if visibleBooks.isEmpty {
                            ContentUnavailableView("此分类没有书籍", systemImage: "book.closed")
                        } else if listLayout {
                            LazyVStack(spacing: 0) {
                                ForEach(visibleBooks) { book in
                                    NavigationLink(value: book.id) {
                                        BookSummaryRow(title: book.title, author: book.author,
                                                       subtitle: book.currentChapter?.title, coverURL: book.coverURL,
                                                       coverData: library.coverData(book))
                                            .padding(.vertical, 10)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 18)], spacing: 22) {
                                ForEach(visibleBooks) { book in
                                    NavigationLink(value: book.id) { shelfTile(book) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 15)
                    .frame(maxWidth: 1050)
                    .frame(maxWidth: .infinity)
                }
                .background(ReaderPalette.paper)
            }
        }
        .navigationTitle("书架")
        .navigationDestination(for: UUID.self) { BookDetailsView(bookID: $0) }
        .toolbar {
            if #available(iOS 27.0, *) {
                ToolbarItem(placement: .topBarPinnedTrailing) { importButton }
                ToolbarOverflowMenu { layoutButton }
            } else {
                ToolbarItem(placement: .topBarTrailing) { importButton }
                ToolbarItem(placement: .topBarLeading) { layoutButton }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: pickFolder ? [.folder] : [.plainText, .readerEPUB],
                      allowsMultipleSelection: !pickFolder) {
            result in
            switch result {
            case .failure(let error): library.report("无法访问文件", error: error)
            case .success(let urls):
                importTask = Task {
                    defer { importTask = nil }
                    if pickFolder, let root = urls.first {
                        do {
                            let result = try await library.importFolder(root)
                            let detail = ["导入 \(result.added) 本，跳过 \(result.skipped) 本重复书籍。"] + result.failures
                            library.message = LibraryMessage(title: "扫描完成", detail: detail.joined(separator: "\n"))
                        } catch { library.report("无法扫描文件夹", error: error) }
                        return
                    }
                    var failures: [String] = []
                    for url in urls {
                        do { try await library.importLocalFile(url) }
                        catch { failures.append("\(url.lastPathComponent) · \(error.localizedDescription)") }
                    }
                    if !failures.isEmpty {
                        library.message = LibraryMessage(title: "有文件未能导入", detail: failures.joined(separator: "\n"))
                    }
                }
            }
        }
        .readerCover($reader)
    }

    private var importButton: some View {
        Menu {
            Button("导入书籍", systemImage: "doc") { openPicker(folder: false) }
            Button("扫描文件夹", systemImage: "folder") { openPicker(folder: true) }
        } label: {
            if importTask != nil { ProgressView().controlSize(.small) } else { Label("添加书籍", systemImage: "plus") }
        }
        .disabled(importTask != nil)
    }

    private func openPicker(folder: Bool) {
        pickFolder = folder
        importing = true
    }

    private var layoutButton: some View {
        Button(listLayout ? "封面视图" : "列表视图", systemImage: listLayout ? "square.grid.2x2" : "list.bullet") {
            listLayout.toggle()
        }
        .disabled(library.books.isEmpty)
    }

    private func shelfTile(_ book: LibraryBook) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            BookCover(title: book.title, author: book.author, remoteURL: book.coverURL, data: library.coverData(book))
                .shadow(color: .black.opacity(0.13), radius: 5, x: 0, y: 3)
            Text(book.title).font(.subheadline.bold()).lineLimit(2, reservesSpace: true)
            Text(book.author.isEmpty ? (book.isLocal ? "本地书籍" : "在线书籍") : book.author)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func continueCard(_ book: LibraryBook) -> some View {
        Button {
            reader = ReaderDestination(book: book)
        } label: {
            HStack(spacing: 17) {
                BookCover(title: book.title, author: book.author, remoteURL: book.coverURL, data: library.coverData(book))
                    .frame(width: 74)
                VStack(alignment: .leading, spacing: 6) {
                    Label("继续阅读", systemImage: "clock.arrow.circlepath").font(.subheadline.bold())
                        .foregroundStyle(ReaderPalette.accent)
                    Text(book.title).font(.title2.bold()).lineLimit(2)
                    if let chapter = book.currentChapter { Text(chapter.title).font(.subheadline).lineLimit(1) }
                    ProgressView(value: book.readingFraction).padding(.top, 5).accessibilityLabel("章节进度")
                }
                .frame(maxWidth: 460, alignment: .leading)
                Image(systemName: "arrow.right").font(.headline).foregroundStyle(ReaderPalette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background, in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(ReaderPalette.accent.opacity(0.13)) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private enum ShelfFilter: String, CaseIterable {
    case all = "全部"
    case local = "本地"
    case online = "在线"
}
