import Foundation
import LegadoCore
import Observation

@MainActor
@Observable
final class LibraryStore {
    private(set) var index = LibraryIndex()
    var message: LibraryMessage?
    private let files = LibraryFiles()
    let client = SourceClient()
    private var delayedSave: Task<Void, Never>?
    private var canWrite = true

    init() {
        do {
            index = try files.load()
        } catch {
            index = LibraryIndex()
            canWrite = false
            message = LibraryMessage(title: "无法打开书架", detail: error.localizedDescription)
        }
    }

    var books: [LibraryBook] { index.books }
    var sources: [BookSource] { index.sources }
    var replacements: [TextReplacement] { index.replacements }

    func book(_ id: UUID) -> LibraryBook? { books.first { $0.id == id } }
    func source(_ id: String) -> BookSource? { sources.first { $0.id == id } }

    func report(_ title: String, error: any Error) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        message = LibraryMessage(title: title, detail: error.localizedDescription)
    }

    @discardableResult
    func importLocalFile(_ url: URL) async throws -> Bool {
        let fileStore = files
        let fingerprints = Set(books.compactMap(\.localFingerprint))
        let imported = try await Task.detached(priority: .userInitiated) { () -> LibraryBook? in
            let data = try Self.readPickedFile(url, maximum: 128 * 1024 * 1024)
            let fingerprint = LibraryFiles.digest(data)
            guard !fingerprints.contains(fingerprint) else { return nil }
            let local = try LocalBookImporter.importBook(data: data, filename: url.lastPathComponent)
            let id = UUID()
            guard !local.chapters.isEmpty else { throw LibraryError.noChapters }
            let chapters = local.chapters.enumerated().map { index, chapter in
                LibraryChapter(id: String(index), title: chapter.title)
            }
            do {
                for (index, chapter) in local.chapters.enumerated() {
                    try fileStore.write(Data(chapter.text.utf8), bookID: id, key: "chapter:" + String(index))
                }
                if let cover = local.cover { try fileStore.write(cover, bookID: id, key: "cover") }
            } catch {
                fileStore.remove(id)
                throw error
            }
            return LibraryBook(id: id, title: local.title, author: local.author, chapters: chapters,
                               localFingerprint: fingerprint)
        }.value
        guard let book = imported else { return false }
        do {
            try Task.checkCancellation()
            if books.contains(where: { $0.localFingerprint == book.localFingerprint }) {
                files.remove(book.diskID)
                return false
            }
            var updated = index
            updated.books.append(book)
            try commit(updated)
            return true
        } catch {
            files.remove(book.diskID)
            throw error
        }
    }

    func importFolder(_ root: URL) async throws -> (added: Int, skipped: Int, failures: [String]) {
        let hasAccess = root.startAccessingSecurityScopedResource()
        defer { if hasAccess { root.stopAccessingSecurityScopedResource() } }
        let selection = try await Task.detached(priority: .userInitiated) { () -> [URL] in
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants, .skipsHiddenFiles]) else {
                throw CocoaError(.fileReadNoPermission)
            }
            return files.compactMap { entry in
                guard let url = entry as? URL, ["txt", "epub"].contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true else { return nil }
                return url
            }.sorted { $0.path < $1.path }
        }.value
        var added = 0
        var skipped = 0
        var failures: [String] = []
        for url in selection {
            try Task.checkCancellation()
            do {
                if try await importLocalFile(url) { added += 1 } else { skipped += 1 }
            } catch where !Task.isCancelled {
                failures.append("\(url.lastPathComponent) · \(error.localizedDescription)")
            }
        }
        return (added, skipped, failures)
    }

    func importSourceFile(_ url: URL) async throws -> Int {
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.readPickedFile(url, maximum: 16 * 1024 * 1024)
        }.value
        return try await importSources(data)
    }

    func importSources(_ data: Data) async throws -> Int {
        let incoming = try await Task.detached(priority: .userInitiated) {
            try BookSource.decodeImport(data)
        }.value
        try Task.checkCancellation()
        var updated = index
        for source in incoming {
            try Self.validateSource(source)
            if let position = updated.sources.firstIndex(where: { $0.id == source.id }) {
                updated.sources[position] = source
            } else {
                updated.sources.append(source)
            }
        }
        try commit(updated)
        return Set(incoming.map(\.id)).count
    }

    func replaceSource(_ source: BookSource, originalID: String) throws {
        try Self.validateSource(source)
        var updated = index
        guard let position = updated.sources.firstIndex(where: { $0.id == originalID }) else { return }
        if source.id != originalID {
            guard !updated.sources.contains(where: { $0.id == source.id }) else { throw LibraryError.invalidSource }
            for index in updated.books.indices where updated.books[index].sourceID == originalID {
                updated.books[index].sourceID = source.id
            }
        }
        updated.sources[position] = source
        try commit(updated)
    }

    func deleteSource(_ id: String) throws {
        var updated = index
        updated.sources.removeAll { $0.id == id }
        try commit(updated)
    }

    func exportSources() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(sources)
    }

    func saveReplacement(_ rule: TextReplacement) throws {
        try rule.validate()
        var updated = index
        if let position = updated.replacements.firstIndex(where: { $0.id == rule.id }) {
            updated.replacements[position] = rule
        } else {
            updated.replacements.append(rule)
        }
        try commit(updated)
    }

    func deleteReplacements(_ offsets: IndexSet) throws {
        var updated = index
        for offset in offsets.reversed() { updated.replacements.remove(at: offset) }
        try commit(updated)
    }

    func moveReplacements(_ offsets: IndexSet, to destination: Int) throws {
        var updated = index
        let moving = offsets.map { updated.replacements[$0] }
        for offset in offsets.reversed() { updated.replacements.remove(at: offset) }
        let index = destination - offsets.filter { $0 < destination }.count
        updated.replacements.insert(contentsOf: moving, at: index)
        try commit(updated)
    }

    func addRemote(_ match: SourceSearchResult, detail: SourceBookDetail, source: BookSource) async throws -> UUID {
        if let found = existingBook(for: match) { return found.id }
        let list = try await client.chapters(source: source, tocURL: detail.tocURL)
        try Task.checkCancellation()
        if let found = existingBook(for: match) { return found.id }
        let chapters = Self.libraryChapters(list)
        guard !chapters.isEmpty else { throw LibraryError.noChapters }
        let book = LibraryBook(id: UUID(), title: detail.name.isEmpty ? match.name : detail.name,
                               author: detail.author.isEmpty ? match.author : detail.author,
                               intro: detail.intro ?? match.intro, coverURL: detail.coverURL ?? match.coverURL,
                               sourceID: match.sourceID, bookURL: match.bookURL, tocURL: detail.tocURL, chapters: chapters)
        var updated = index
        updated.books.append(book)
        try commit(updated)
        return book.id
    }

    func existingBook(for match: SourceSearchResult) -> LibraryBook? {
        books.first { $0.sourceID == match.sourceID && $0.bookURL == match.bookURL }
    }

    func refresh(_ book: LibraryBook) async throws {
        guard let sourceID = book.sourceID, let tocURL = book.tocURL, let source = source(sourceID) else {
            throw LibraryError.missingSource
        }
        let chapters = Self.libraryChapters(try await client.chapters(source: source, tocURL: tocURL))
        try Task.checkCancellation()
        guard !chapters.isEmpty else { throw LibraryError.noChapters }
        try changeBook(book.id) { current in
            guard current.diskID == book.diskID else { return }
            if let progress = current.progress, !chapters.contains(where: { $0.id == progress.chapterID }) {
                if let previous = current.chapters.firstIndex(where: { $0.id == progress.chapterID }) {
                    let chapter = chapters[min(previous, chapters.count - 1)]
                    current.progress = ReaderProgress(chapterID: chapter.id, paragraphIndex: 0)
                } else {
                    current.progress = nil
                }
            }
            current.bookmarks.removeAll { mark in !chapters.contains { $0.id == mark.progress.chapterID } }
            current.chapters = chapters
        }
    }

    func switchSource(for snapshot: LibraryBook, to match: SourceSearchResult) async throws {
        guard let source = source(match.sourceID) else { throw LibraryError.missingSource }
        let detail = try await client.detail(source: source, bookURL: match.bookURL)
        let chapters = Self.libraryChapters(try await client.chapters(source: source, tocURL: detail.tocURL))
        try Task.checkCancellation()
        guard !chapters.isEmpty else { throw LibraryError.noChapters }
        var updated = index
        guard let position = updated.books.firstIndex(where: { $0.id == snapshot.id && $0.diskID == snapshot.diskID }) else {
            throw LibraryError.missingContent
        }
        if let duplicate = existingBook(for: match), duplicate.id != snapshot.id { throw LibraryError.duplicateBook }
        var book = updated.books[position]
        let oldDisk = book.diskID
        let chaptersByTitle = Dictionary(grouping: chapters, by: { Self.normalizedTitle($0.title) })
        let oldPositions = Dictionary(uniqueKeysWithValues: book.chapters.enumerated().map { ($1.id, $0) })
        func move(_ progress: ReaderProgress, useIndex: Bool) -> ReaderProgress? {
            guard let previous = oldPositions[progress.chapterID] else { return nil }
            let matches = chaptersByTitle[Self.normalizedTitle(book.chapters[previous].title)] ?? []
            let replacement = matches.count == 1 ? matches.first : nil
            guard let chapter = replacement ?? (useIndex ? chapters[min(previous, chapters.count - 1)] : nil) else {
                return nil
            }
            return ReaderProgress(chapterID: chapter.id, paragraphIndex: 0)
        }
        let progress = book.progress.flatMap { move($0, useIndex: true) }
        let bookmarks = book.bookmarks.compactMap { mark in
            move(mark.progress, useIndex: false).map { BookBookmark(progress: $0, id: mark.id, date: mark.date) }
        }
        book.progress = progress
        book.bookmarks = bookmarks
        book.sourceID = source.id
        book.bookURL = match.bookURL
        book.tocURL = detail.tocURL
        book.chapters = chapters
        book.storageID = UUID()
        book.intro = detail.intro ?? match.intro ?? book.intro
        book.coverURL = detail.coverURL ?? match.coverURL ?? book.coverURL
        updated.books[position] = book
        try commit(updated)
        files.remove(oldDisk)
    }

    func setProgress(_ progress: ReaderProgress, for snapshot: LibraryBook) {
        guard canWrite, let position = index.books.firstIndex(where: { $0.id == snapshot.id }),
              index.books[position].diskID == snapshot.diskID,
              index.books[position].chapters.contains(where: { $0.id == progress.chapterID }) else { return }
        if index.books[position].progress == progress,
           let lastRead = index.books[position].lastRead, Date.now.timeIntervalSince(lastRead) < 60 { return }
        index.books[position].progress = progress
        index.books[position].lastRead = .now
        delayedSave?.cancel()
        delayedSave = Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
                flushProgress()
            } catch {}
        }
    }

    func flushProgress() {
        guard let pending = delayedSave else { return }
        pending.cancel()
        delayedSave = nil
        do { try files.save(index) } catch { report("无法保存阅读进度", error: error) }
    }

    func bookmark(_ progress: ReaderProgress, for id: UUID) throws {
        try changeBook(id) { book in
            if !book.bookmarks.contains(where: { $0.progress == progress }) {
                book.bookmarks.append(BookBookmark(progress: progress))
            }
        }
    }

    func deleteBookmark(_ bookmarkID: UUID, for bookID: UUID) throws {
        try changeBook(bookID) { $0.bookmarks.removeAll { $0.id == bookmarkID } }
    }

    func saveNote(_ note: String, for id: UUID) throws {
        try changeBook(id) { $0.note = note }
    }

    func deleteBook(_ book: LibraryBook) throws {
        var updated = index
        updated.books.removeAll { $0.id == book.id }
        try commit(updated)
        files.remove(book.diskID)
    }

    func coverData(_ book: LibraryBook) -> Data? { files.read(book, key: "cover") }

    func contentLoader(for book: LibraryBook, applyReplacements: Bool = true) -> @Sendable (Int) async throws -> String {
        let chapterSource = book.sourceID.flatMap(source)
        let files = files
        let rules = applyReplacements ? replacements : []
        let client = client
        return { @concurrent position in
            guard book.chapters.indices.contains(position) else { throw LibraryError.missingContent }
            let chapter = book.chapters[position]
            let key = "chapter:" + chapter.id
            if let cached = files.read(book, key: key), let text = String(data: cached, encoding: .utf8) {
                return TextReplacement.apply(rules, to: text)
            }
            guard let url = chapter.remoteURL else { throw LibraryError.missingContent }
            guard let chapterSource else { throw LibraryError.missingSource }
            let nextChapterURL = book.chapters.indices.contains(position + 1) ? book.chapters[position + 1].remoteURL : nil
            let text = try await client.content(source: chapterSource, chapterURL: url, nextChapterURL: nextChapterURL)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.missingContent }
            try Task.checkCancellation()
            try files.write(Data(text.utf8), bookID: book.diskID, key: key)
            return TextReplacement.apply(rules, to: text)
        }
    }

    func makeBackup() async throws -> Data {
        let fileStore = files
        let snapshot = index
        let feeds = UserDefaults.standard.data(forKey: LibraryBackup.feedDefaultsKey)
        return try await Task.detached(priority: .userInitiated) {
            try fileStore.makeBackup(snapshot, feedSubscriptions: feeds)
        }.value
    }

    func restoreBackup(from url: URL) async throws {
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.readPickedFile(url, maximum: LibraryBackup.maxBytes)
        }.value
        try await restoreBackup(data)
    }

    func restoreBackup(_ data: Data) async throws {
        let fileStore = files
        let staged = try await Task.detached(priority: .userInitiated) {
            return try fileStore.stageBackup(data)
        }.value
        let old = index
        do {
            try Task.checkCancellation()
            try files.save(staged.index)
        } catch {
            staged.index.books.forEach { files.remove($0.diskID) }
            throw error
        }
        delayedSave?.cancel()
        delayedSave = nil
        index = staged.index
        if let feeds = staged.feedSubscriptions {
            UserDefaults.standard.set(feeds, forKey: LibraryBackup.feedDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LibraryBackup.feedDefaultsKey)
        }
        canWrite = true
        Task.detached(priority: .utility) { old.books.forEach { fileStore.remove($0.diskID) } }
    }

    private func changeBook(_ id: UUID, mutate: (inout LibraryBook) -> Void) throws {
        var updated = index
        guard let position = updated.books.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated.books[position])
        try commit(updated)
    }

    private func commit(_ updated: LibraryIndex) throws {
        guard canWrite else { throw LibraryError.invalidBackup }
        try files.save(updated)
        delayedSave?.cancel()
        delayedSave = nil
        index = updated
    }

    private nonisolated static func libraryChapters(_ items: [RemoteChapter]) -> [LibraryChapter] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard !item.isVolume, seen.insert(item.url).inserted else { return nil }
            return LibraryChapter(id: LibraryFiles.digest(item.url), title: item.title, remoteURL: item.url)
        }
    }

    private nonisolated static func normalizedTitle(_ title: String) -> String {
        let normalized = title.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? title
        return normalized.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    nonisolated static func webURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { throw LibraryError.invalidURL }
        return url
    }

    private nonisolated static func validateSource(_ source: BookSource) throws {
        guard !source.bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? webURL(source.bookSourceUrl)) != nil else { throw LibraryError.invalidSource }
    }

    private nonisolated static func readPickedFile(_ url: URL, maximum: Int) throws -> Data {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, size > maximum { throw LibraryError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximum else { throw LibraryError.tooLarge }
        return data
    }
}
