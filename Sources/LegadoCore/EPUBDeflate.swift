// The three block types and canonical Huffman coding are defined in RFC 1951.
enum EPUBDeflate {
    private struct Bits {
        let bytes: ArraySlice<UInt8>
        var offset: Int
        var buffer = 0
        var count = 0

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            self.offset = bytes.startIndex
        }

        mutating func read(_ width: Int) throws -> Int {
            while count < width {
                guard offset < bytes.endIndex else { throw LocalBookImportError.invalidEPUB }
                buffer |= Int(bytes[offset]) << count
                count += 8
                offset += 1
            }
            let value = buffer & ((1 << width) - 1)
            buffer >>= width
            count -= width
            return value
        }

        mutating func readStoredBytes(_ length: Int) throws -> ArraySlice<UInt8> {
            guard count == 0, offset + length <= bytes.endIndex else { throw LocalBookImportError.invalidEPUB }
            let start = offset
            offset += length
            return bytes[start ..< offset]
        }
    }

    private struct Huffman {
        let counts: [Int]
        let orderedSymbols: [Int]

        init(_ lengths: [Int]) throws {
            var counts = Array(repeating: 0, count: 16)
            for length in lengths where length > 0 { counts[length] += 1 }
            var capacity = 1
            var offsets = [0]
            for width in 1 ... 15 {
                capacity = capacity * 2 - counts[width]
                guard capacity >= 0 else { throw LocalBookImportError.invalidEPUB }
                offsets.append(offsets[width - 1] + counts[width - 1])
            }
            var symbols = Array(repeating: 0, count: counts.reduce(0, +))
            for (symbol, length) in lengths.enumerated() where length > 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
            self.counts = counts
            self.orderedSymbols = symbols
        }

        func read(from bits: inout Bits) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for width in 1 ... 15 {
                code = (code << 1) | (try bits.read(1))
                let count = counts[width]
                if code >= first, code < first + count { return orderedSymbols[index + code - first] }
                first = (first + count) << 1
                index += count
            }
            throw LocalBookImportError.invalidEPUB
        }
    }

    private static let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35,
                                      43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthWidths = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3,
                                       3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
                                        385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]

    static func decode(_ bytes: ArraySlice<UInt8>, expectedSize: Int) throws -> [UInt8] {
        guard expectedSize >= 0 else { throw LocalBookImportError.invalidEPUB }
        var bits = Bits(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(expectedSize)
        var fixed: (Huffman, Huffman)?
        var isFinal: Bool
        repeat {
            isFinal = try bits.read(1) == 1
            let type = try bits.read(2)
            switch type {
            case 0:
                _ = try bits.read(bits.count)
                let size = try bits.read(16)
                let complement = try bits.read(16)
                guard size ^ complement == 65_535, size <= expectedSize - output.count else {
                    throw LocalBookImportError.invalidEPUB
                }
                output.append(contentsOf: try bits.readStoredBytes(size))
            case 1:
                let (literals, distances) = try fixed ?? fixedTrees()
                fixed = (literals, distances)
                try decodeBlock(&bits, literals: literals, distances: distances, limit: expectedSize, output: &output)
            case 2:
                let (literals, distances) = try dynamicTrees(from: &bits)
                try decodeBlock(&bits, literals: literals, distances: distances, limit: expectedSize, output: &output)
            default:
                throw LocalBookImportError.invalidEPUB
            }
        } while !isFinal
        guard output.count == expectedSize else { throw LocalBookImportError.invalidEPUB }
        return output
    }

    private static func fixedTrees() throws -> (Huffman, Huffman) {
        var lengths = Array(repeating: 8, count: 144)
        lengths.append(contentsOf: repeatElement(9, count: 112))
        lengths.append(contentsOf: repeatElement(7, count: 24))
        lengths.append(contentsOf: repeatElement(8, count: 8))
        return (try Huffman(lengths), try Huffman(Array(repeating: 5, count: 32)))
    }

    private static func dynamicTrees(from bits: inout Bits) throws -> (Huffman, Huffman) {
        let literalCount = try bits.read(5) + 257
        let distanceCount = try bits.read(5) + 1
        let codeCount = try bits.read(4) + 4
        guard literalCount <= 286 else { throw LocalBookImportError.invalidEPUB }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = Array(repeating: 0, count: 19)
        for symbol in order.prefix(codeCount) { codeLengths[symbol] = try bits.read(3) }
        let codes = try Huffman(codeLengths)
        var lengths: [Int] = []
        let total = literalCount + distanceCount
        while lengths.count < total {
            let code = try codes.read(from: &bits)
            let length: Int
            let count: Int
            switch code {
            case 16:
                guard let previous = lengths.last else { throw LocalBookImportError.invalidEPUB }
                length = previous
                count = try bits.read(2) + 3
            case 17:
                length = 0
                count = try bits.read(3) + 3
            case 18:
                length = 0
                count = try bits.read(7) + 11
            default:
                length = code
                count = 1
            }
            guard lengths.count + count <= total else { throw LocalBookImportError.invalidEPUB }
            lengths.append(contentsOf: repeatElement(length, count: count))
        }
        guard lengths[256] != 0 else { throw LocalBookImportError.invalidEPUB }
        return (try Huffman(Array(lengths.prefix(literalCount))), try Huffman(Array(lengths.dropFirst(literalCount))))
    }

    private static func decodeBlock(
        _ bits: inout Bits, literals: Huffman, distances: Huffman, limit: Int, output: inout [UInt8]
    ) throws {
        while true {
            let symbol = try literals.read(from: &bits)
            switch symbol {
            case 0 ... 255:
                guard output.count < limit else { throw LocalBookImportError.invalidEPUB }
                output.append(UInt8(symbol))
            case 256:
                return
            case 257 ... 285:
                let index = symbol - 257
                let length = try lengthBases[index] + bits.read(lengthWidths[index])
                let distanceCode = try distances.read(from: &bits)
                guard distanceCode < distanceBases.count else { throw LocalBookImportError.invalidEPUB }
                let distanceWidth = max(0, distanceCode / 2 - 1)
                let distance = try distanceBases[distanceCode] + bits.read(distanceWidth)
                guard distance <= output.count, length <= limit - output.count else {
                    throw LocalBookImportError.invalidEPUB
                }
                for _ in 0 ..< length {
                    let value = output[output.count - distance]
                    output.append(value)
                }
            default:
                throw LocalBookImportError.invalidEPUB
            }
        }
    }
}
