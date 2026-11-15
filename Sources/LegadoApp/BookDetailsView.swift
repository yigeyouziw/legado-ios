import SwiftUI

struct ReaderDestination: Identifiable {
    let id = UUID()
    let book: LibraryBook
    var start: ReaderProgress?
}

extension View {
    func readerCover(_ destination: Binding<ReaderDestination?>) -> some View {
        modifier(ReaderPresentation(destination: destination))
    }
}

private struct ReaderPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var library
    @Binding var destination: ReaderDestination?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $destination, onDismiss: { library.flushProgress() }) { destination in
            let book = destination.book
            ReaderView(
                title: book.title,
                chapters: book.chapters.map { ReaderChapter(id: $0.id, title: $0.title) },
                initialProgress: destination.start ?? book.progress,
                loadContent: library.contentLoader(for: book),
                onProgress: { library.setProgress($0, for: book) },
                onBookmark: { try library.bookmark($0, for: book.id) }
            )
        }
    }
}

struct BookDetailsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @State private var reader: ReaderDestination?
    @State private var note = ""
    @State private var editNote = false
    @State private var confirmDelete = false
    @State private var switching = false
    @State private var downloading = false
    @State private var downloadProgress = 0
    @State private var downloadTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let book = library.book(bookID) { details(book) }
            else { ContentUnavailableView("书籍已移除", systemImage: "book.closed") }
        }
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .readerCover($reader)
        .sheet(isPresented: $switching) {
            if let book = library.book(bookID) { SwitchSourceView(book: book) }
        }
        .onDisappear { refreshTask?.cancel() }
    }

    private func details(_ book: LibraryBook) -> some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 18) {
                    BookCover(title: book.title, author: book.author, remoteURL: book.coverURL, data: library.coverData(book))
                        .frame(width: 86)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(book.title).font(.title2.bold())
                        if !book.author.isEmpty { Text(book.author).foregroundStyle(.secondary) }
                        Label(sourceLabel(book), systemImage: book.isLocal ? "folder" : "globe")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(book.progress == nil ? "开始阅读" : "继续阅读", systemImage: "book") {
                            reader = ReaderDestination(book: book)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(book.chapters.isEmpty)
                    }
                }
                .padding(.vertical, 8)
                if let intro = book.intro, !intro.isEmpty { Text(intro).font(.subheadline) }
                if !book.note.isEmpty { Label(book.note, systemImage: "note.text").font(.subheadline) }
                if downloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(downloadProgress), total: Double(max(book.chapters.count, 1)))
                        HStack {
                            Text("缓存进度 \(downloadProgress) / \(book.chapters.count)").font(.caption)
                            Spacer()
                            Button("停止缓存", role: .cancel) { downloadTask?.cancel() }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            if !book.bookmarks.isEmpty {
                Section("书签") {
                    ForEach(book.bookmarks.reversed()) { mark in
                        Button {
                            reader = ReaderDestination(book: book, start: mark.progress)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.chapters.first { $0.id == mark.progress.chapterID }?.title ?? "章节")
                                    .foregroundStyle(.primary)
                                Text(mark.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                do { try library.deleteBookmark(mark.id, for: book.id) }
                                catch { library.report("删除失败", error: error) }
                            }
                        }
                    }
                }
            }
            Section("目录 · \(book.chapters.count) 章") {
                ForEach(book.chapters) { chapter in
                    Button {
                        let progress = ReaderProgress(chapterID: chapter.id, paragraphIndex: 0)
                        reader = ReaderDestination(book: book, start: progress)
                    } label: {
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            if chapter.id == book.progress?.chapterID {
                                Image(systemName: "book.fill").accessibilityLabel("上次读到这里")
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("书籍操作", systemImage: "ellipsis.circle") {
                    Button("书籍备注", systemImage: "note.text") {
                        note = book.note
                        editNote = true
                    }
                    if !book.isLocal {
                        Button("更换书源", systemImage: "arrow.triangle.swap") { switching = true }.disabled(downloading)
                        Button("更新目录", systemImage: "arrow.clockwise") { refresh(book) }.disabled(refreshTask != nil)
                        Button("缓存全书", systemImage: "arrow.down.to.line") { download(book) }.disabled(downloading)
                    }
                    Button("移出书架", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .alert("书籍备注", isPresented: $editNote) {
            TextField("备注", text: $note)
            Button("取消", role: .cancel) {}
            Button("保存") {
                do { try library.saveNote(note, for: book.id) }
                catch { library.report("保存失败", error: error) }
            }
        }
        .confirmationDialog("移出书架？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移除书籍", role: .destructive) {
                downloadTask?.cancel()
                do { try library.deleteBook(book); dismiss() }
                catch { library.report("移除失败", error: error) }
            }
        } message: {
            Text("书架中的阅读进度、书签和章节缓存也会删除。")
        }
    }

    private func sourceLabel(_ book: LibraryBook) -> String {
        guard let id = book.sourceID else { return "本地书籍" }
        return library.source(id)?.bookSourceName ?? "书源已移除"
    }

    private func refresh(_ book: LibraryBook) {
        refreshTask = Task {
            defer { refreshTask = nil }
            do { try await library.refresh(book) }
            catch { library.report("无法更新目录", error: error) }
        }
    }

    private func download(_ book: LibraryBook) {
        downloading = true
        downloadProgress = 0
        let load = library.contentLoader(for: book, applyReplacements: false)
        downloadTask = Task {
            defer { downloading = false; downloadTask = nil }
            var failures = 0
            for index in book.chapters.indices {
                if Task.isCancelled { return }
                do { _ = try await load(index) }
                catch { failures += 1 }
                downloadProgress = index + 1
            }
            guard !Task.isCancelled else { return }
            library.message = failures == 0
                ? LibraryMessage(title: "已缓存全书", detail: "共 \(book.chapters.count) 章，可离线阅读。")
                : LibraryMessage(title: "缓存完成", detail: "\(failures) 章未下载，可重试。")
        }
    }
}
