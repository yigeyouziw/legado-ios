import CryptoKit
import Foundation
import LegadoCore

struct LibraryFiles: Sendable {
    let root: URL

    init() {
        root = URL.applicationSupportDirectory.appending(path: "Legado", directoryHint: .isDirectory)
    }

    func load() throws -> LibraryIndex {
        let file = root.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return LibraryIndex() }
        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: file))
        try validate(index)
        return index
    }

    func save(_ index: LibraryIndex) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(index)
        try data.write(to: root.appending(path: "library.json"), options: .atomic)
    }

    func read(_ book: LibraryBook, key: String) -> Data? {
        try? Data(contentsOf: file(book.diskID, key: key), options: .mappedIfSafe)
    }

    func write(_ data: Data, bookID: UUID, key: String) throws {
        try FileManager.default.createDirectory(at: directory(bookID), withIntermediateDirectories: true)
        try data.write(to: file(bookID, key: key), options: .atomic)
    }

    func remove(_ bookID: UUID) {
        try? FileManager.default.removeItem(at: directory(bookID))
    }

    func makeBackup(_ index: LibraryIndex, feedSubscriptions: Data?) throws -> Data {
        var byteCount = 0
        var payloads: [UUID: [String: Data]] = [:]
        for book in index.books {
            try Task.checkCancellation()
            let keys = ["cover"] + book.chapters.map { "chapter:" + $0.id }
            let available = try keys.compactMap { key -> (String, Data)? in
                guard let data = read(book, key: key) else {
                    if book.isLocal && key != "cover" { throw LibraryError.missingContent }
                    return nil
                }
                byteCount += data.count
                guard byteCount <= 180 * 1024 * 1024 else { throw LibraryError.tooLarge }
                return (key, data)
            }
            if !available.isEmpty { payloads[book.id] = Dictionary(uniqueKeysWithValues: available) }
        }
        let backup = LibraryBackup(index: index, payloads: payloads, feedSubscriptions: feedSubscriptions)
        let data = try JSONEncoder().encode(backup)
        guard data.count <= LibraryBackup.maxBytes else { throw LibraryError.tooLarge }
        return data
    }

    func stageBackup(_ data: Data) throws -> (index: LibraryIndex, feedSubscriptions: Data?) {
        guard data.count <= LibraryBackup.maxBytes else { throw LibraryError.tooLarge }
        let backup = try JSONDecoder().decode(LibraryBackup.self, from: data)
        guard backup.format == "legado-ios-backup" else { throw LibraryError.invalidBackup }
        try validate(backup.index)
        var index = backup.index
        var staged: [UUID] = []
        do {
            for position in index.books.indices {
                try Task.checkCancellation()
                let id = UUID()
                index.books[position].storageID = id
                staged.append(id)
                let payload = backup.payloads[index.books[position].id] ?? [:]
                let keys = index.books[position].chapters.map { "chapter:" + $0.id }
                if index.books[position].isLocal && keys.contains(where: { payload[$0] == nil }) {
                    throw LibraryError.invalidBackup
                }
                for key in keys + ["cover"] {
                    if let bytes = payload[key] { try write(bytes, bookID: id, key: key) }
                }
            }
        } catch {
            staged.forEach(remove)
            throw error
        }
        return (index, backup.feedSubscriptions)
    }

    private func validate(_ index: LibraryIndex) throws {
        guard index.version == 1, Set(index.books.map(\.id)).count == index.books.count,
              Set(index.books.map(\.diskID)).count == index.books.count,
              Set(index.sources.map(\.id)).count == index.sources.count,
              Set(index.replacements.map(\.id)).count == index.replacements.count,
              index.books.allSatisfy({ Set($0.chapters.map(\.id)).count == $0.chapters.count }) else {
            throw LibraryError.invalidBackup
        }
    }

    private func directory(_ id: UUID) -> URL {
        root.appending(path: "Books", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func file(_ id: UUID, key: String) -> URL {
        directory(id).appending(path: Self.digest(key))
    }

    static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }
}
