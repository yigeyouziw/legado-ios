import Foundation

// EPUB uses ZIP local headers and the central directory defined in the PKWARE APPNOTE.
struct EPUBArchive {
    private struct Entry {
        let flags: Int
        let method: Int
        let checksum: UInt32
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        (0 ..< 8).reduce(UInt32(index)) { crc, _ in
            (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320)
        }
    }

    private let bytes: [UInt8]
    private let directoryOffset: Int
    private let entries: [String: Entry]

    init(data: Data) throws {
        guard data.count >= 22 else { throw LocalBookImportError.invalidEPUB }
        let bytes = Array(data)
        let possibleRecords = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
        guard let end = possibleRecords.first(where: {
            Self.number32(bytes, $0) == 0x0605_4b50 && $0 + 22 + Self.number16(bytes, $0 + 20) == bytes.count
        }) else { throw LocalBookImportError.invalidEPUB }

        let entryCount = Self.number16(bytes, end + 10)
        let directorySize = Int(Self.number32(bytes, end + 12))
        let directoryOffset = Int(Self.number32(bytes, end + 16))
        guard Self.number16(bytes, end + 4) == 0, Self.number16(bytes, end + 6) == 0,
              Self.number16(bytes, end + 8) == entryCount, entryCount < 65_535,
              directoryOffset + directorySize <= end else { throw LocalBookImportError.invalidEPUB }

        let directoryEnd = directoryOffset + directorySize
        var position = directoryOffset
        var entries: [String: Entry] = [:]
        for _ in 0 ..< entryCount {
            guard position + 46 <= directoryEnd, Self.number32(bytes, position) == 0x0201_4b50,
                  Self.number16(bytes, position + 34) == 0 else { throw LocalBookImportError.invalidEPUB }
            let nameStart = position + 46
            let nameEnd = nameStart + Self.number16(bytes, position + 28)
            let next = nameEnd + Self.number16(bytes, position + 30) + Self.number16(bytes, position + 32)
            guard next <= directoryEnd, let name = String(bytes: bytes[nameStart ..< nameEnd], encoding: .utf8),
                  entries[name] == nil else { throw LocalBookImportError.invalidEPUB }
            entries[name] = Entry(
                flags: Self.number16(bytes, position + 8),
                method: Self.number16(bytes, position + 10),
                checksum: Self.number32(bytes, position + 16),
                compressedSize: Int(Self.number32(bytes, position + 20)),
                size: Int(Self.number32(bytes, position + 24)),
                headerOffset: Int(Self.number32(bytes, position + 42))
            )
            position = next
        }
        self.bytes = bytes
        self.directoryOffset = directoryOffset
        self.entries = entries
    }

    func data(at path: String, maximumSize: Int = 24 * 1024 * 1024) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        guard entry.size <= maximumSize else { throw LocalBookImportError.fileTooLarge }
        guard entry.flags & 1 == 0 else { throw LocalBookImportError.encryptedEPUB }
        let header = entry.headerOffset
        guard header + 30 <= directoryOffset, Self.number32(bytes, header) == 0x0403_4b50,
              Self.number16(bytes, header + 6) & 1 == 0,
              Self.number16(bytes, header + 8) == entry.method else { throw LocalBookImportError.invalidEPUB }
        let nameStart = header + 30
        let nameEnd = nameStart + Self.number16(bytes, header + 26)
        let start = nameEnd + Self.number16(bytes, header + 28)
        let end = start + entry.compressedSize
        guard end <= directoryOffset,
              String(bytes: bytes[nameStart ..< nameEnd], encoding: .utf8) == path else {
            throw LocalBookImportError.invalidEPUB
        }

        let inflated: [UInt8]
        switch entry.method {
        case 0:
            guard entry.size == entry.compressedSize else { throw LocalBookImportError.invalidEPUB }
            inflated = Array(bytes[start ..< end])
        case 8:
            inflated = try EPUBDeflate.decode(bytes[start ..< end], expectedSize: entry.size)
        default:
            throw LocalBookImportError.invalidEPUB
        }
        let crc = inflated.reduce(UInt32.max) { crc, byte in
            (crc >> 8) ^ Self.crcTable[Int((crc ^ UInt32(byte)) & 255)]
        } ^ UInt32.max
        guard crc == entry.checksum else { throw LocalBookImportError.invalidEPUB }
        return Data(inflated)
    }

    private static func number16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private static func number32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(number16(bytes, offset)) | (UInt32(number16(bytes, offset + 2)) << 16)
    }
}
