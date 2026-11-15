import Foundation

enum SourceJSONPath {
    static func select(_ expression: String, in root: SourceJSON) throws -> [SourceJSON] {
        let query = expression.sourceTrimmed
        guard !query.isEmpty else { return [] }
        if let direct = root.fields?[query] { return [direct] }
        var remaining = query[...]
        if remaining.first == "$" || remaining.first == "@" { remaining = remaining.dropFirst() }
        var current = [root]
        while !remaining.isEmpty {
            if remaining.hasPrefix("..") {
                remaining = remaining.dropFirst(2)
                if remaining.hasPrefix("['") || remaining.hasPrefix("[\""),
                   let bracket = consumeGroup(remaining, open: "[", close: "]") {
                    current = recursive(current, key: unquote(bracket.body.sourceTrimmed))
                    remaining = bracket.tail
                } else {
                    let key = readKey(&remaining)
                    guard !key.isEmpty else { throw SourceError.unsupportedRule("JSONPath \(query)") }
                    current = recursive(current, key: key)
                }
            } else if let bracket = consumeGroup(remaining, open: "[", close: "]") {
                current = try selectBracket(bracket.body, from: current)
                remaining = bracket.tail
            } else {
                if remaining.first == "." { remaining = remaining.dropFirst() }
                let key = readKey(&remaining)
                guard !key.isEmpty else { throw SourceError.unsupportedRule("JSONPath \(query)") }
                current = values(for: key, from: current)
            }
        }
        return current
    }

    private static func readKey(_ remaining: inout Substring) -> String {
        let key = remaining.prefix { $0 != "." && $0 != "[" }
        remaining = remaining.dropFirst(key.count)
        return String(key).sourceTrimmed
    }

    private static func values(for key: String, from inputs: [SourceJSON]) -> [SourceJSON] {
        if key == "*" { return inputs.flatMap(childValues) }
        if key == "length()" || key == "size()" {
            return inputs.compactMap { value in
                let count = value.items?.count ?? value.fields?.count ?? value.text?.count
                return count.map { .integer(Int64($0)) }
            }
        }
        return inputs.flatMap { input -> [SourceJSON] in
            if let value = input.fields?[key] { return [value] }
            return (input.items ?? []).compactMap { $0.fields?[key] }
        }
    }

    private static func childValues(_ value: SourceJSON) -> [SourceJSON] {
        if let array = value.items { return array }
        return (value.fields ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    private static func recursive(_ inputs: [SourceJSON], key: String) -> [SourceJSON] {
        var pending = Array(inputs.reversed())
        var results: [SourceJSON] = []
        while let value = pending.popLast() {
            let children = childValues(value)
            if key == "*" {
                results.append(contentsOf: children)
            } else if let matched = value.fields?[key] {
                results.append(matched)
            }
            pending.append(contentsOf: children.reversed())
        }
        return results
    }

    private static func selectBracket(_ expression: String, from inputs: [SourceJSON]) throws -> [SourceJSON] {
        let query = expression.sourceTrimmed
        if query.hasPrefix("?("), query.hasSuffix(")") {
            let filter = String(query.dropFirst(2).dropLast())
            return try inputs.flatMap { try childValues($0).filter { try satisfies(filter, value: $0) } }
        }
        let branches = splitSourceRule(query, on: ",")
        return try branches.flatMap { part -> [SourceJSON] in
            let item = part.sourceTrimmed
            if item.first == "\"" || item.first == "'" { return values(for: unquote(item), from: inputs) }
            if item == "*" { return inputs.flatMap(childValues) }
            if let index = Int(item) {
                return inputs.compactMap { value in
                    guard let items = value.items else { return nil }
                    let position = index < 0 ? items.count + index : index
                    return items.indices.contains(position) ? items[position] : nil
                }
            }
            if item.contains(":") { return try inputs.flatMap { try slice(item, array: $0.items ?? []) } }
            throw SourceError.unsupportedRule("JSONPath 索引 [\(item)]")
        }
    }

    private static func slice(_ input: String, array: [SourceJSON]) throws -> [SourceJSON] {
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), !array.isEmpty else { return [] }
        let requested = parts.count == 3 && !parts[2].isEmpty ? Int(parts[2]) : 1
        guard let requested, requested != 0 else { throw SourceError.unsupportedRule("JSONPath 步长 \(input)") }
        let step = max(-array.count, min(array.count, requested))
        let lower = step > 0 ? 0 : -1
        let upper = step > 0 ? array.count : array.count - 1
        func index(_ input: Substring, fallback: Int) -> Int {
            guard let raw = Int(input) else { return fallback }
            return min(upper, max(lower, raw < 0 ? raw + array.count : raw))
        }
        let start = index(parts[0], fallback: step > 0 ? 0 : array.count - 1)
        let end = index(parts[1], fallback: step > 0 ? array.count : -1)
        return stride(from: start, to: end, by: step).map { array[$0] }
    }

    private static func satisfies(_ expression: String, value: SourceJSON) throws -> Bool {
        let query = expression.sourceTrimmed
        let alternatives = splitSourceRule(query, on: "||")
        if alternatives.count > 1 { return try alternatives.contains { try satisfies($0, value: value) } }
        let combined = splitSourceRule(query, on: "&&")
        if combined.count > 1 { return try combined.allSatisfy { try satisfies($0, value: value) } }
        if let match = sourceCaptures(#"^(@(?:\.[\w-]+|\[['"][^'"]+['"]\])*)\s*(==|!=|<=|>=|<|>)\s*(.*)$"#, in: query) {
            let selected = try select(match[1], in: value)
            let literal = match[3].sourceTrimmed
            let expected: SourceJSON
            if literal.hasPrefix("'") {
                expected = .string(unquote(literal))
            } else if let parsed = try? JSONDecoder().decode(SourceJSON.self, from: Data(literal.utf8)) {
                expected = parsed
            } else {
                throw SourceError.unsupportedRule("JSONPath 条件 \(query)")
            }
            return selected.contains { compare($0, to: expected, using: match[2]) }
        }
        if query.hasPrefix("!@") { return try !satisfies(String(query.dropFirst()), value: value) }
        if query.hasPrefix("@"), !query.contains(where: \.isWhitespace) {
            return try select(query, in: value).contains { $0 != .null }
        }
        throw SourceError.unsupportedRule("JSONPath 条件 \(query)")
    }

    private static func compare(_ left: SourceJSON, to right: SourceJSON, using operation: String) -> Bool {
        let lhs = left.text
        let rhs = right.text
        if operation == "==" { return left == right || (lhs != nil && lhs == rhs) }
        if operation == "!=" { return !compare(left, to: right, using: "==") }
        guard let lhs, let rhs else { return false }
        if let a = Double(lhs), let b = Double(rhs) {
            switch operation {
            case "<": return a < b
            case ">": return a > b
            case "<=": return a <= b
            default: return a >= b
            }
        }
        switch operation {
        case "<": return lhs < rhs
        case ">": return lhs > rhs
        case "<=": return lhs <= rhs
        default: return lhs >= rhs
        }
    }
}
