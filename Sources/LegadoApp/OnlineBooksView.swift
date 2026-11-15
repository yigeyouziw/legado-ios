import LegadoCore
import SwiftUI

struct OnlineBook: Identifiable, Sendable {
    let result: SourceSearchResult
    let sourceName: String

    var id: String { result.sourceID + "\n" + result.bookURL }
}

struct BookSearchView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var submitted = ""
    @State private var sourceFilter: String?
    @State private var searchedSources: [BookSource] = []
    @State private var matches: [OnlineBook] = []
    @State private var errors: [String] = []
    @State private var page = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var searchID = UUID()
    @State private var searchTask: Task<Void, Never>?
    @State private var selected: OnlineBook?
    @State private var showErrors = false

    private var activeSources: [BookSource] {
        library.sources.filter { $0.enabled && $0.searchUrl != nil }
    }

    var body: some View {
        List {
            ForEach(matches) { match in
                Button { selected = match } label: { row(match) }
            }
            if isLoading {
                HStack { Spacer(); ProgressView("搜索中…"); Spacer() }.padding(.vertical, 10)
            } else if hasMore && !matches.isEmpty {
                Button("继续加载", systemImage: "arrow.down") { start(nextPage: true) }
            }
            if !errors.isEmpty {
                Button("查看 \(errors.count) 条书源报错", systemImage: "exclamationmark.triangle") { showErrors = true }
            }
        }
        .overlay {
            if matches.isEmpty && !isLoading && errors.isEmpty { emptyState }
        }
        .navigationTitle("搜书")
        .searchable(text: $query, prompt: "书名或作者")
        .onSubmit(of: .search) { start() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("筛选书源", systemImage: "line.3.horizontal.decrease") {
                    Picker("搜索范围", selection: $sourceFilter) {
                        Text("所有书源").tag(nil as String?)
                        ForEach(activeSources) { source in
                            Text(source.bookSourceName).tag(Optional(source.id))
                        }
                    }
                }
                .disabled(activeSources.isEmpty)
            }
        }
        .onChange(of: sourceFilter) {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { start() }
        }
        .onChange(of: query) { _, updated in
            guard updated.isEmpty else { return }
            searchTask?.cancel()
            searchID = UUID()
            submitted = ""
            isLoading = false
            matches = []
            errors = []
            hasMore = false
        }
        .sheet(item: $selected) { match in NavigationStack { OnlineBookSheet(match: match) } }
        .sheet(isPresented: $showErrors) {
            NavigationStack {
                List(Array(errors.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.subheadline).textSelection(.enabled)
                }
                .navigationTitle("书源报错")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private var emptyState: some View {
        if activeSources.isEmpty {
            ContentUnavailableView("没有可搜索的书源", systemImage: "globe.badge.chevron.backward",
                                   description: Text("在「管理 → 书源」导入并启用书源。"))
        } else if !submitted.isEmpty {
            ContentUnavailableView.search(text: submitted)
        } else {
            ContentUnavailableView("搜索在线书籍", systemImage: "magnifyingglass",
                                   description: Text("输入书名或作者，在启用的书源中查找。"))
        }
    }

    private func row(_ match: OnlineBook) -> some View {
        BookSummaryRow(title: match.result.name, author: match.result.author,
                       subtitle: match.sourceName, coverURL: match.result.coverURL)
    }

    private func start(nextPage: Bool = false) {
        searchTask?.cancel()
        if !nextPage {
            submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
            searchedSources = activeSources.filter { sourceFilter == nil || $0.id == sourceFilter }
            page = 0
            matches = []
        }
        guard !submitted.isEmpty, !searchedSources.isEmpty else {
            isLoading = false
            hasMore = false
            errors = []
            searchID = UUID()
            return
        }
        let run = UUID()
        let keyword = submitted
        let next = page + 1
        let sources = searchedSources
        let client = library.client
        searchID = run
        isLoading = true
        errors = []
        hasMore = false
        searchTask = Task {
            var known = Set(matches.map(\.id))
            var sourcesWithNewResults = Set<String>()
            await withTaskGroup(of: SearchResponse.self) { group in
                func enqueue(_ source: BookSource) {
                    group.addTask {
                        do {
                            let results = try await client.search(source: source, keyword: keyword, page: next)
                            return SearchResponse(sourceID: source.id, books: results.map {
                                OnlineBook(result: $0, sourceName: source.bookSourceName)
                            }, error: nil)
                        } catch {
                            return SearchResponse(sourceID: source.id, books: [],
                                                  error: "\(source.bookSourceName) · \(error.localizedDescription)")
                        }
                    }
                }
                var pendingSources = sources.makeIterator()
                for _ in 0..<8 { if let source = pendingSources.next() { enqueue(source) } }
                while let response = await group.next() {
                    guard !Task.isCancelled, searchID == run else { group.cancelAll(); return }
                    if let source = pendingSources.next() { enqueue(source) }
                    if let error = response.error { errors.append(error) }
                    let additions = response.books.filter { known.insert($0.id).inserted }
                    if !additions.isEmpty { sourcesWithNewResults.insert(response.sourceID) }
                    matches.append(contentsOf: additions)
                }
            }
            guard searchID == run, !Task.isCancelled else { return }
            searchedSources = sources.filter {
                sourcesWithNewResults.contains($0.id) && SourceClient.supportsPagination($0.searchUrl)
            }
            hasMore = !searchedSources.isEmpty
            page = next
            isLoading = false
        }
    }
}

private struct SearchResponse: Sendable {
    let sourceID: String
    let books: [OnlineBook]
    let error: String?
}

struct DiscoverView: View {
    @Environment(LibraryStore.self) private var library

    private var discoverable: [BookSource] {
        library.sources.filter { $0.enabled && $0.enabledExplore && $0.exploreUrl != nil }
    }

    var body: some View {
        List {
            ForEach(discoverable) { source in
                NavigationLink {
                    ExploreCategoriesView(source: source)
                } label: {
                    Label(source.bookSourceName, systemImage: "globe")
                }
            }
        }
        .overlay {
            if discoverable.isEmpty {
                ContentUnavailableView("暂无发现书源", systemImage: "safari",
                                       description: Text("导入含有发现规则的书源后，即可浏览分类和榜单。"))
            }
        }
        .navigationTitle("发现")
    }
}

private struct ExploreCategoriesView: View {
    @Environment(LibraryStore.self) private var library
    let source: BookSource
    @State private var categories: [SourceExploreCategory] = []
    @State private var failure: String?

    var body: some View {
        List(categories) { category in
            NavigationLink(category.title) { ExploreResultsView(source: source, category: category) }
        }
        .overlay {
            if let failure {
                ContentUnavailableView("无法加载分类", systemImage: "exclamationmark.triangle", description: Text(failure))
            }
        }
        .navigationTitle(source.bookSourceName)
        .task {
            do {
                categories = try library.client.exploreCategories(source: source)
                if categories.isEmpty { failure = "此书源没有可显示的发现分类。" }
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct ExploreResultsView: View {
    @Environment(LibraryStore.self) private var library
    let source: BookSource
    let category: SourceExploreCategory
    @State private var matches: [OnlineBook] = []
    @State private var page = 0
    @State private var loading = false
    @State private var finished = false
    @State private var failure: String?
    @State private var selected: OnlineBook?

    var body: some View {
        List {
            ForEach(matches) { match in
                Button { selected = match } label: {
                    BookSummaryRow(title: match.result.name, author: match.result.author, coverURL: match.result.coverURL)
                }
            }
            if loading {
                ProgressView("加载中…")
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
                Button("重试") { Task { await loadNext() } }
            } else if !finished && page > 0 {
                Button("继续加载", systemImage: "arrow.down") { Task { await loadNext() } }
            } else if matches.isEmpty && finished {
                Text("没有找到书籍").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(category.title)
        .task { if page == 0 { await loadNext() } }
        .sheet(item: $selected) { match in NavigationStack { OnlineBookSheet(match: match) } }
    }

    private func loadNext() async {
        guard !loading && !finished else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let results = try await library.client.explore(source: source, category: category, page: page + 1)
            try Task.checkCancellation()
            var known = Set(matches.map(\.id))
            let additions = results.map { OnlineBook(result: $0, sourceName: source.bookSourceName) }
                .filter { known.insert($0.id).inserted }
            if additions.isEmpty { finished = true }
            matches += additions
            page += 1
        } catch where !Task.isCancelled { failure = error.localizedDescription }
        catch {}
    }
}

private struct OnlineBookSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let match: OnlineBook
    @State private var detail: SourceBookDetail?
    @State private var failure: String?
    @State private var loadingDetail = false
    @State private var adding = false
    @State private var bookID: UUID?
    @State private var reader: ReaderDestination?

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    let name = detail?.name.isEmpty == false ? detail?.name ?? match.result.name : match.result.name
                    let author = detail?.author.isEmpty == false ? detail?.author ?? match.result.author : match.result.author
                    BookCover(title: name, author: author, remoteURL: detail?.coverURL ?? match.result.coverURL)
                        .frame(width: 84)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(name).font(.title2.bold())
                        if !author.isEmpty { Text(author).foregroundStyle(.secondary) }
                        Label(match.sourceName, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                if let intro = detail?.intro ?? match.result.intro, !intro.isEmpty { Text(intro).font(.subheadline) }
                if loadingDetail { ProgressView("正在获取详情…") }
                if let failure {
                    Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                    if detail == nil { Button("重新获取详情") { Task { await fetch() } } }
                }
            }
            if let id = bookID ?? library.existingBook(for: match.result)?.id, let book = library.book(id) {
                Button("开始阅读", systemImage: "book") { reader = ReaderDestination(book: book) }
                NavigationLink("查看目录和书签") { BookDetailsView(bookID: id) }
            } else if let detail {
                Button("加入书架", systemImage: "plus") { Task { await add(detail, read: false) } }
                    .disabled(adding)
                Button("加入书架并阅读", systemImage: "book") { Task { await add(detail, read: true) } }
                    .disabled(adding)
                if adding { ProgressView("正在获取目录…") }
            }
        }
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task { if detail == nil && library.existingBook(for: match.result) == nil { await fetch() } }
        .readerCover($reader)
    }

    private func fetch() async {
        guard !loadingDetail else { return }
        guard let source = library.source(match.result.sourceID) else {
            failure = LibraryError.missingSource.localizedDescription
            return
        }
        loadingDetail = true
        failure = nil
        defer { loadingDetail = false }
        do { detail = try await library.client.detail(source: source, bookURL: match.result.bookURL) }
        catch where !Task.isCancelled { failure = error.localizedDescription }
        catch {}
    }

    private func add(_ detail: SourceBookDetail, read: Bool) async {
        guard !adding else { return }
        guard let source = library.source(match.result.sourceID) else {
            failure = LibraryError.missingSource.localizedDescription
            return
        }
        adding = true
        failure = nil
        defer { adding = false }
        do {
            let id = try await library.addRemote(match.result, detail: detail, source: source)
            bookID = id
            if read, let book = library.book(id) { reader = ReaderDestination(book: book) }
        } catch where !Task.isCancelled { failure = error.localizedDescription }
        catch {}
    }
}
