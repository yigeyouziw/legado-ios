import LegadoCore
import SwiftUI

@MainActor
struct SwitchSourceView: View {
    let book: LibraryBook

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Candidate] = []
    @State private var failures: [Failure] = []
    @State private var completedSources = 0
    @State private var totalSources = 0
    @State private var searchID = 0
    @State private var searching = true
    @State private var selected: Candidate?
    @State private var confirming = false
    @State private var switching = false
    @State private var switchFailure: String?

    init(book: LibraryBook) {
        self.book = book
    }

    private var sources: [BookSource] {
        library.sources.filter { source in
            source.id != book.sourceID && source.enabled && source.searchUrl?.isEmpty == false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("当前书籍") {
                    BookSummaryRow(
                        title: book.title, author: book.author,
                        subtitle: book.sourceID.flatMap { library.source($0)?.bookSourceName },
                        coverURL: book.coverURL
                    )
                }

                if switching {
                    Section { ProgressView("正在获取新目录…") }
                } else if searching, totalSources > 0 {
                    Section {
                        ProgressView(value: Double(completedSources), total: Double(totalSources)) {
                            Text("正在搜索其他书源")
                        } currentValueLabel: {
                            Text("\(completedSources) / \(totalSources)").monospacedDigit()
                        }
                    }
                }

                candidateSection("书名和作者相符", candidates.filter { $0.quality == .titleAndAuthor })
                candidateSection("其他候选", candidates.filter { $0.quality != .titleAndAuthor })

                if !searching && candidates.isEmpty {
                    Section {
                        if totalSources == 0 {
                            ContentUnavailableView("没有可换的书源", systemImage: "globe", description: Text("请在「管理 → 书源」启用另一个可搜索的书源。"))
                        } else {
                            ContentUnavailableView("未找到相符书籍", systemImage: "magnifyingglass", description: Text("已用当前书名搜索其他启用的书源。"))
                            Button("重新搜索", systemImage: "arrow.clockwise") { searchID += 1 }
                        }
                    }
                }

                if !failures.isEmpty {
                    Section {
                        DisclosureGroup("\(failures.count) 个书源搜索失败") {
                            ForEach(failures) { failure in
                                LabeledContent(failure.name, value: failure.message)
                                    .font(.caption)
                            }
                        }
                        if !searching && !switching && !candidates.isEmpty {
                            Button("重新搜索", systemImage: "arrow.clockwise") { searchID += 1 }
                        }
                    }
                }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(switching)
                }
            }
            .confirmationDialog("切换书源？", isPresented: $confirming, titleVisibility: .visible, presenting: selected) { candidate in
                Button("确认换源") { Task { await switchTo(candidate) } }
            } message: { candidate in
                Text("将切换到「\(candidate.book.sourceName)」的《\(candidate.book.result.name)》。进度优先按同名章节匹配，其次沿用章序，位置回到章首。书签迁移需要章节名唯一匹配，旧章节缓存将清除。")
            }
            .alert("换源失败", isPresented: Binding(
                get: { switchFailure != nil },
                set: { if !$0 { switchFailure = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(switchFailure ?? "")
            }
            .task(id: searchID) { await search() }
        }
        .interactiveDismissDisabled(switching)
    }

    @ViewBuilder
    private func candidateSection(_ title: String, _ items: [Candidate]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { candidate in
                    Button {
                        selected = candidate
                        confirming = true
                    } label: {
                        BookSummaryRow(
                            title: candidate.book.result.name, author: candidate.book.result.author,
                            subtitle: candidate.book.sourceName, coverURL: candidate.book.result.coverURL
                        )
                    }
                    .disabled(switching)
                }
            }
        }
    }

    private func search() async {
        let providers = sources
        let client = library.client
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = Matcher(title: title, author: book.author)
        candidates = []
        failures = []
        completedSources = 0
        totalSources = providers.count
        searching = !providers.isEmpty
        guard searching else { return }

        var seen = Set<String>()
        await withTaskGroup(of: SearchResponse.self) { group in
            func enqueue(_ source: BookSource) {
                group.addTask {
                    do {
                        let results = try await client.search(source: source, keyword: title)
                        let matches = results.compactMap { result -> Candidate? in
                            guard let quality = matcher.quality(of: result) else { return nil }
                            return Candidate(book: OnlineBook(result: result, sourceName: source.bookSourceName), quality: quality)
                        }
                        return SearchResponse(candidates: matches, failure: nil)
                    } catch {
                        return SearchResponse(candidates: [], failure: Failure(
                            id: source.id, name: source.bookSourceName, message: error.localizedDescription
                        ))
                    }
                }
            }

            var queue = providers.makeIterator()
            for _ in 0..<8 { if let source = queue.next() { enqueue(source) } }
            while let result = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let source = queue.next() { enqueue(source) }
                completedSources += 1
                if let failure = result.failure { failures.append(failure) }
                let additions = result.candidates.filter { seen.insert($0.id).inserted }
                if !additions.isEmpty {
                    candidates.append(contentsOf: additions)
                    candidates.sort(by: Candidate.ranksBefore)
                }
            }
        }
        if !Task.isCancelled { searching = false }
    }

    private func switchTo(_ candidate: Candidate) async {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        do {
            try await library.switchSource(for: book, to: candidate.book.result)
            dismiss()
        } catch where !Task.isCancelled {
            switchFailure = error.localizedDescription
        } catch {}
    }

    private enum MatchQuality: Int, Sendable {
        case closeTitle, exactTitle, titleAndAuthor
    }

    private struct Candidate: Identifiable, Sendable {
        let book: OnlineBook
        let quality: MatchQuality
        var id: String { book.id }

        static func ranksBefore(_ first: Self, _ second: Self) -> Bool {
            if first.quality != second.quality { return first.quality.rawValue > second.quality.rawValue }
            let sourceOrder = first.book.sourceName.localizedStandardCompare(second.book.sourceName)
            if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
            let titleOrder = first.book.result.name.localizedStandardCompare(second.book.result.name)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return first.id < second.id
        }
    }

    private struct Failure: Identifiable, Sendable {
        let id: String
        let name: String
        let message: String
    }

    private struct SearchResponse: Sendable {
        let candidates: [Candidate]
        let failure: Failure?
    }

    private struct Matcher: Sendable {
        let title: String
        let author: String

        init(title: String, author: String) {
            self.title = Self.normalize(title)
            self.author = Self.normalizeAuthor(author)
        }

        func quality(of result: SourceSearchResult) -> MatchQuality? {
            let resultTitle = Self.normalize(result.name)
            guard !resultTitle.isEmpty, !title.isEmpty else { return nil }
            if resultTitle == title {
                return !author.isEmpty && author == Self.normalizeAuthor(result.author) ? .titleAndAuthor : .exactTitle
            }
            if min(resultTitle.count, title.count) >= 3,
               resultTitle.contains(title) || title.contains(resultTitle) {
                return .closeTitle
            }
            return nil
        }

        private static func normalizeAuthor(_ author: String) -> String {
            let prefix = #"^\s*(?:(?:作者|著者)\s*[:：]\s*|by\s+)"#
            return normalize(author.replacingOccurrences(of: prefix, with: "", options: [.caseInsensitive, .regularExpression]))
        }

        private static func normalize(_ value: String) -> String {
            let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
            let folded = simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
    }
}
