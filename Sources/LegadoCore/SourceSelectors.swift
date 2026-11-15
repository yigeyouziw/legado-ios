import Foundation

private let groupClosings: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

func splitSourceRule(_ value: String, on delimiter: String, limit: Int = .max) -> [String] {
    var parts: [String] = []
    var start = value.startIndex
    var cursor = start
    var closing: [Character] = []
    var quote: Character?
    var escaped = false
    while cursor < value.endIndex, parts.count + 1 < limit {
        let character = value[cursor]
        if escaped {
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if let activeQuote = quote {
            if character == activeQuote { quote = nil }
        } else if closing.isEmpty, value[cursor...].hasPrefix(delimiter) {
            parts.append(String(value[start..<cursor]))
            cursor = value.index(cursor, offsetBy: delimiter.count)
            start = cursor
            continue
        } else if character == "\"" || character == "'" {
            quote = character
        } else if let close = groupClosings[character] {
            closing.append(close)
        } else if closing.last == character {
            closing.removeLast()
        }
        cursor = value.index(after: cursor)
    }
    parts.append(String(value[start...]))
    return parts
}

func sourceCaptures(_ pattern: String, in value: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
    return (0..<match.numberOfRanges).map {
        guard let range = Range(match.range(at: $0), in: value) else { return "" }
        return String(value[range])
    }
}

func uniqueSourceNodes(_ nodes: [SourceHTMLNode]) -> [SourceHTMLNode] {
    var seen: Set<ObjectIdentifier> = []
    return nodes.filter { seen.insert(ObjectIdentifier($0)).inserted }
}

enum SourceCSS {
    private enum Relation {
        case descendant, child, adjacent, sibling

        func candidates(from node: SourceHTMLNode, includeSelf: Bool) -> [SourceHTMLNode] {
            switch self {
            case .descendant: includeSelf ? [node] + node.descendants : node.descendants
            case .child: node.elements
            case .adjacent: Array(following(node).prefix(1))
            case .sibling: following(node)
            }
        }

        private func following(_ node: SourceHTMLNode) -> [SourceHTMLNode] {
            guard let siblings = node.parent?.elements,
                  let index = siblings.firstIndex(where: { $0 === node }) else { return [] }
            return Array(siblings.dropFirst(index + 1))
        }
    }

    private typealias Predicate = (SourceHTMLNode) -> Bool

    static func select(_ rule: String, in node: SourceHTMLNode) throws -> [SourceHTMLNode] {
        let parts = splitSourceRule(rule, on: ",")
        let matches = try parts.flatMap { group -> [SourceHTMLNode] in
            var elements = [node]
            for (index, part) in tokens(group).enumerated() {
                let predicate = try parseSimple(part.selector)
                elements = uniqueSourceNodes(elements.flatMap { part.relation.candidates(from: $0, includeSelf: index == 0) })
                    .filter(predicate)
            }
            return elements
        }
        if parts.count == 1 { return matches }
        let members = Set(matches.map(ObjectIdentifier.init))
        return ([node] + node.descendants).filter { members.contains(ObjectIdentifier($0)) }
    }

    private static func tokens(_ input: String) -> [(relation: Relation, selector: String)] {
        var result: [(Relation, String)] = []
        var relation = Relation.descendant
        var token = ""
        var closing: [Character] = []
        var quote: Character?
        var escaped = false

        func finish() {
            if !token.isEmpty {
                result.append((relation, token))
                token = ""
                relation = .descendant
            }
        }

        for character in input {
            if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                token.append(character)
                escaped = true
            } else if let activeQuote = quote {
                token.append(character)
                if activeQuote == character { quote = nil }
            } else if character == "\"" || character == "'" {
                token.append(character)
                quote = character
            } else if let close = groupClosings[character] {
                token.append(character)
                closing.append(close)
            } else if closing.last == character {
                token.append(character)
                closing.removeLast()
            } else if closing.isEmpty, character.isWhitespace || ">+~".contains(character) {
                finish()
                switch character {
                case ">": relation = .child
                case "+": relation = .adjacent
                case "~": relation = .sibling
                default: break
                }
            } else {
                token.append(character)
            }
        }
        finish()
        return result
    }

    private static func parseSimple(_ input: String) throws -> Predicate {
        var rules: [Predicate] = []
        var remaining = input[...]
        if let element = sourceCaptures(#"^(\*|[\p{L}_][\p{L}\p{N}_-]*)"#, in: String(remaining)) {
            let tag = element[0].lowercased()
            rules.append { $0.tag != "#document" && (tag == "*" || $0.tag == tag) }
            remaining = remaining.dropFirst(element[0].count)
        }
        while let first = remaining.first {
            if first == "#" || first == "." {
                guard let match = sourceCaptures(#"^((?:\\.|[\p{L}\p{N}_-])+)"#, in: String(remaining.dropFirst())) else {
                    throw SourceError.unsupportedRule("CSS 选择器 \(input)")
                }
                let name = match[1].replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
                if first == "#" {
                    rules.append { $0.attributes["id"] == name }
                } else {
                    rules.append { $0.attributes["class"]?.split(whereSeparator: \.isWhitespace).contains { $0 == name } == true }
                }
                remaining = remaining.dropFirst(match[0].count + 1)
            } else if first == "[" {
                guard let bracket = consumeGroup(remaining, open: "[", close: "]") else {
                    throw SourceError.unsupportedRule("CSS 属性选择器 \(input)")
                }
                rules.append(try attributePredicate(bracket.body))
                remaining = bracket.tail
            } else if first == ":" {
                guard let match = sourceCaptures(#"^:([\w-]+)"#, in: String(remaining)) else {
                    throw SourceError.unsupportedRule("CSS 伪类 \(input)")
                }
                remaining = remaining.dropFirst(match[0].count)
                let group = consumeGroup(remaining, open: "(", close: ")")
                rules.append(try pseudoPredicate(match[1].lowercased(), argument: group?.body ?? ""))
                if let group { remaining = group.tail }
            } else {
                throw SourceError.unsupportedRule("CSS 选择器 \(input)")
            }
        }
        return { node in rules.allSatisfy { $0(node) } }
    }

    private static func attributePredicate(_ input: String) throws -> Predicate {
        guard let match = sourceCaptures(#"^\s*([\w:-]+)\s*(?:([~|^$*!]?=)\s*(.*?)\s*(?:\s+([iIsS]))?)?\s*$"#, in: input) else {
            throw SourceError.unsupportedRule("CSS 属性选择器 \(input)")
        }
        let key = match[1].lowercased()
        let comparison = match[2]
        let insensitive = match[4].lowercased() == "i"
        let expected = insensitive ? unquote(match[3]).lowercased() : unquote(match[3])
        return { node in
            if comparison == "!=" { return node.attributes[key] != expected }
            guard let raw = node.attributes[key] else { return false }
            let actual = insensitive ? raw.lowercased() : raw
            switch comparison {
            case "": return true
            case "=": return actual == expected
            case "^=": return actual.hasPrefix(expected)
            case "$=": return actual.hasSuffix(expected)
            case "*=": return actual.contains(expected)
            case "~=": return actual.split(whereSeparator: \.isWhitespace).contains { $0 == expected }
            case "|=": return actual == expected || actual.hasPrefix(expected + "-")
            default: return false
            }
        }
    }

    private static func pseudoPredicate(_ name: String, argument: String) throws -> Predicate {
        switch name {
        case "root": return { $0.parent?.tag == "#document" }
        case "first-child": return { $0.previousSiblings.isEmpty }
        case "last-child": return { $0.parent?.elements.last === $0 }
        case "only-child": return { $0.parent?.elements.count == 1 }
        case "first-of-type": return { node in !node.previousSiblings.contains { $0.tag == node.tag } }
        case "last-of-type": return { node in node.parent?.elements.last(where: { $0.tag == node.tag }) === node }
        case "only-of-type": return { node in node.parent?.elements.filter { $0.tag == node.tag }.count == 1 }
        case "empty": return { $0.children.isEmpty }
        case "contains": return { $0.text.localizedCaseInsensitiveContains(unquote(argument)) }
        case "containsown": return { $0.ownText.localizedCaseInsensitiveContains(unquote(argument)) }
        case "not":
            let predicate = try parseSimple(argument.sourceTrimmed)
            return { !predicate($0) }
        case "has": return { node in (try? select(argument, in: node).contains { $0 !== node }) == true }
        case "eq", "lt", "gt":
            guard let index = Int(argument.sourceTrimmed) else { break }
            if name == "eq" { return { $0.previousSiblings.count == index } }
            if name == "lt" { return { $0.previousSiblings.count < index } }
            return { $0.previousSiblings.count > index }
        case "nth-child", "nth-of-type", "nth-last-child", "nth-last-of-type":
            let rule = argument.lowercased().replacingOccurrences(of: " ", with: "")
            let fromEnd = name.contains("last")
            let sameTagOnly = name.hasSuffix("of-type")
            let position: (SourceHTMLNode) -> Int = { node in
                guard var siblings = node.parent?.elements else { return 1 }
                if sameTagOnly { siblings.removeAll { $0.tag != node.tag } }
                guard let index = siblings.firstIndex(where: { $0 === node }) else { return 1 }
                return fromEnd ? siblings.count - index : index + 1
            }
            if rule == "even" { return { position($0).isMultiple(of: 2) } }
            if rule == "odd" { return { position($0) % 2 == 1 } }
            if let index = Int(rule) { return { position($0) == index } }
            if let match = sourceCaptures(#"^([+-]?\d*)n([+-]\d+)?$"#, in: rule) {
                let step = match[1] == "-" ? -1 : Int(match[1]) ?? 1
                let offset = Int(match[2]) ?? 0
                return {
                    let (index, overflow) = position($0).subtractingReportingOverflow(offset)
                    guard !overflow, index != Int.min || step != -1 else { return false }
                    return step == 0 ? index == 0 : index % step == 0 && index / step >= 0
                }
            }
        default: break
        }
        throw SourceError.unsupportedRule("CSS 伪类 :\(name)")
    }
}

func consumeGroup(_ value: Substring, open: Character, close: Character) -> (body: String, tail: Substring)? {
    guard value.first == open else { return nil }
    var depth = 0
    var quote: Character?
    var escaped = false
    for index in value.indices {
        let character = value[index]
        if escaped {
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if let active = quote {
            if active == character { quote = nil }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == open {
            depth += 1
        } else if character == close {
            depth -= 1
            if depth == 0 {
                return (String(value[value.index(after: value.startIndex)..<index]), value[value.index(after: index)...])
            }
        }
    }
    return nil
}

func unquote(_ value: String) -> String {
    guard let first = value.first, value.count > 1,
          (first == "\"" || first == "'"), value.last == first else { return value }
    return String(value.dropFirst().dropLast())
}

enum SourceXPath {
    static func select(_ expression: String, in node: SourceHTMLNode) throws -> [SourceRuleValue] {
        let unions = splitSourceRule(expression, on: "|")
        if unions.count > 1 {
            return try unions.flatMap { try select($0.sourceTrimmed, in: node) }
        }
        if let group = consumeGroup(expression[...], open: "(", close: ")") {
            return try grouped(group, in: node)
        }
        for wrapper in ["string", "normalize-space"] {
            if expression.hasPrefix(wrapper + "("), expression.hasSuffix(")") {
                let inner = String(expression.dropFirst(wrapper.count + 1).dropLast())
                let result = try select(inner, in: node).first?.string ?? ""
                return [.text(wrapper == "normalize-space" ? normalizedSpace(result) : result)]
            }
        }
        let parts = splitSourceRule(expression, on: "/")
        var nodes = [expression.hasPrefix("/") && !expression.hasPrefix("//") ? node.document : node]
        var descendants = false
        for (index, rawPart) in parts.enumerated() {
            let part = rawPart.sourceTrimmed
            if part.isEmpty {
                descendants = index > 0
                continue
            }
            if part == "." { continue }
            if part == ".." {
                nodes = uniqueSourceNodes(nodes.compactMap(\.parent))
                continue
            }
            if part == "text()" || part == "node()" || part.hasPrefix("@") {
                if descendants { nodes = nodes.flatMap { [$0] + $0.descendants } }
                if part == "node()" {
                    return nodes.flatMap { $0.children.map(SourceRuleValue.node) }
                }
                if part == "text()" {
                    return nodes.flatMap { $0.children.filter { $0.tag == nil }.map { .text($0.value) } }
                }
                let attribute = String(part.dropFirst()).lowercased()
                return nodes.compactMap { $0.attributes[attribute].map(SourceRuleValue.text) }
            }
            let (axis, step) = try parseStep(part)
            let selected = try nodes.flatMap { element -> [SourceHTMLNode] in
                let candidates: [SourceHTMLNode]
                switch axis {
                case "": candidates = descendants ? element.descendants : element.elements
                case "child": candidates = element.elements
                case "descendant": candidates = element.descendants
                case "descendant-or-self": candidates = [element] + element.descendants
                case "self": candidates = [element]
                case "parent": candidates = [element.parent].compactMap { $0 }
                default: throw SourceError.unsupportedRule("XPath 轴 \(axis)")
                }
                var matching = candidates.filter { step.tag == "*" || $0.tag == step.tag }
                for predicate in step.predicates {
                    matching = try apply(predicate, to: matching)
                }
                return matching
            }
            nodes = uniqueSourceNodes(selected)
            descendants = false
        }
        return nodes.map(SourceRuleValue.node)
    }

    private static func grouped(_ group: (body: String, tail: Substring), in node: SourceHTMLNode) throws -> [SourceRuleValue] {
        var values = try select(group.body.sourceTrimmed, in: node)
        var tail = group.tail
        while let test = consumeGroup(tail, open: "[", close: "]") {
            let condition = test.body.sourceTrimmed
            if let index = Int(condition), index > 0 {
                values = Array(values.dropFirst(index - 1).prefix(1))
            } else if condition == "last()" {
                values = Array(values.suffix(1))
            } else {
                let nodes = values.compactMap { value -> SourceHTMLNode? in
                    if case .node(let node) = value { return node }
                    return nil
                }
                values = try apply(condition, to: nodes).map(SourceRuleValue.node)
            }
            tail = test.tail
        }
        if tail.hasPrefix("/") {
            return try values.flatMap { value -> [SourceRuleValue] in
                guard case .node(let node) = value else { return [] }
                return try select("." + tail, in: node)
            }
        }
        guard tail.isEmpty else { throw SourceError.unsupportedRule("XPath 表达式 \(tail)") }
        return values
    }

    private static func parseStep(_ value: String) throws -> (String, (tag: String, predicates: [String])) {
        let parts = splitSourceRule(value, on: "::", limit: 2)
        let axis = parts.count == 2 ? parts[0] : ""
        let step = parts.last ?? ""
        guard let tag = sourceCaptures(#"^(\*|[\w:-]+)"#, in: step)?[1] else {
            throw SourceError.unsupportedRule("XPath 步骤 \(value)")
        }
        var remaining = step.dropFirst(tag.count)
        var predicates: [String] = []
        while let group = consumeGroup(remaining, open: "[", close: "]") {
            predicates.append(group.body.sourceTrimmed)
            remaining = group.tail
        }
        guard remaining.isEmpty else { throw SourceError.unsupportedRule("XPath 步骤 \(value)") }
        return (axis, (tag.lowercased(), predicates))
    }

    private static func apply(_ predicate: String, to nodes: [SourceHTMLNode]) throws -> [SourceHTMLNode] {
        if let position = Int(predicate), position > 0 { return Array(nodes.dropFirst(position - 1).prefix(1)) }
        if predicate == "last()" { return Array(nodes.suffix(1)) }
        if let match = sourceCaptures(#"^position\(\)\s*(=|<=|>=|<|>)\s*(\d+)$"#, in: predicate),
           let position = Int(match[2]) {
            return nodes.enumerated().filter {
                let index = $0.offset + 1
                switch match[1] {
                case "=": return index == position
                case "<=": return index <= position
                case ">=": return index >= position
                case "<": return index < position
                default: return index > position
                }
            }.map(\.element)
        }
        return try nodes.filter { try matches(predicate, node: $0) }
    }

    private static func matches(_ predicate: String, node: SourceHTMLNode) throws -> Bool {
        let alternatives = splitSourceRule(predicate, on: " or ")
        if alternatives.count > 1 { return try alternatives.contains { try matches($0, node: node) } }
        let combined = splitSourceRule(predicate, on: " and ")
        if combined.count > 1 { return try combined.allSatisfy { try matches($0, node: node) } }
        if predicate.hasPrefix("not("), predicate.hasSuffix(")") {
            return try !matches(String(predicate.dropFirst(4).dropLast()), node: node)
        }
        if let attribute = sourceCaptures(#"^@([\w:-]+)$"#, in: predicate)?[1] {
            return node.attributes[attribute.lowercased()] != nil
        }
        if let match = sourceCaptures(#"^(@[\w:-]+|text\(\)|\.)\s*(!?=)\s*(['"])(.*?)\3$"#, in: predicate) {
            let equals = value(of: match[1], node: node) == match[4]
            return match[2] == "=" ? equals : !equals
        }
        if let match = sourceCaptures(#"^(contains|starts-with)\((.*),\s*(['"])(.*?)\3\)$"#, in: predicate) {
            let actual = value(of: match[2].sourceTrimmed, node: node) ?? ""
            return match[1] == "contains" ? actual.contains(match[4]) : actual.hasPrefix(match[4])
        }
        if let tag = sourceCaptures(#"^[\w:-]+$"#, in: predicate)?[0] {
            return node.elements.contains { $0.tag == tag }
        }
        throw SourceError.unsupportedRule("XPath 条件 \(predicate)")
    }

    private static func value(of expression: String, node: SourceHTMLNode) -> String? {
        if expression.hasPrefix("@") { return node.attributes[String(expression.dropFirst()).lowercased()] }
        if expression == "text()" { return node.ownText }
        if expression == "." { return node.text }
        if expression.hasPrefix("normalize-space("), expression.hasSuffix(")") {
            return value(of: String(expression.dropFirst(16).dropLast()), node: node).map(normalizedSpace)
        }
        if expression.hasPrefix("concat("), expression.hasSuffix(")") {
            return splitSourceRule(String(expression.dropFirst(7).dropLast()), on: ",").map {
                let part = $0.sourceTrimmed
                return value(of: part, node: node) ?? unquote(part)
            }.joined()
        }
        return nil
    }
}
