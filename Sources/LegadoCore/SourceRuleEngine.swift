import Foundation

enum SourceRuleValue {
    case node(SourceHTMLNode)
    case json(SourceJSON)
    case text(String)
    case captures([String])

    var string: String {
        switch self {
        case .node(let node): node.text
        case .json(let json): json.text ?? ""
        case .text(let text): text
        case .captures(let values): values.first ?? ""
        }
    }

    var markup: String {
        switch self {
        case .node(let node): node.tag == "#document" ? node.value : node.outerHTML
        default: string
        }
    }
}

struct SourceRuleEngine {
    static func root(_ text: String) -> SourceRuleValue {
        if let json = try? JSONDecoder().decode(SourceJSON.self, from: Data(text.utf8)),
           json.fields != nil || json.items != nil {
            return .json(json)
        }
        return .node(SourceHTML.parse(text))
    }

    func list(_ rule: String, from value: SourceRuleValue) throws -> [SourceRuleValue] {
        try evaluate(rule, from: value, elements: true)
    }

    func texts(_ rule: String?, from value: SourceRuleValue, paragraphs: Bool = false) throws -> [String] {
        guard let rule = rule?.sourceNonempty else { return [] }
        return try evaluate(rule, from: value, elements: false, paragraphs: paragraphs)
            .compactMap { $0.string.sourceNonempty }
    }

    func text(_ rule: String?, from value: SourceRuleValue, paragraphs: Bool = false) throws -> String? {
        try texts(rule, from: value, paragraphs: paragraphs).joined(separator: "\n").sourceNonempty
    }

    private func evaluate(
        _ rule: String,
        from value: SourceRuleValue,
        elements: Bool,
        paragraphs: Bool = false
    ) throws -> [SourceRuleValue] {
        let rule = rule.sourceTrimmed
        guard !rule.isEmpty else { return [] }
        let firstMatchOnly = rule.hasSuffix("###")
        let matchRule = firstMatchOnly ? String(rule.dropLast(3)) : rule
        let components = matchRule.components(separatedBy: "##")
        let expression = components[0].sourceTrimmed
        let result = expression.isEmpty ? [value] : try compose(expression, from: value, elements: elements, paragraphs: paragraphs)
        guard components.count > 1 else { return result }
        let replacement = components.count > 2 ? components[2] : ""
        return result.map { item in
            .text(Self.replace(in: item.string, pattern: components[1], replacement: replacement, firstMatchOnly: firstMatchOnly))
        }
    }

    private func compose(
        _ rule: String,
        from value: SourceRuleValue,
        elements: Bool,
        paragraphs: Bool
    ) throws -> [SourceRuleValue] {
        for operation in ["||", "&&", "%%"] {
            let rules = splitSourceRule(rule, on: operation)
            guard rules.count > 1 else { continue }
            if operation == "||" {
                var failures: [Error] = []
                for part in rules {
                    do {
                        let matches = try evaluate(part, from: value, elements: elements, paragraphs: paragraphs)
                        if matches.contains(where: { isNonempty($0) }) { return matches }
                    } catch {
                        failures.append(error)
                    }
                }
                if failures.count == rules.count, let first = failures.first { throw first }
                return []
            }
            let groups = try rules.map { try evaluate($0, from: value, elements: elements, paragraphs: paragraphs) }
            if operation == "&&" { return groups.flatMap { $0 } }
            let largest = groups.map(\.count).max() ?? 0
            return (0..<largest).flatMap { index in
                groups.compactMap { group in group.indices.contains(index) ? group[index] : nil }
            }
        }
        return try single(rule, from: value, elements: elements, paragraphs: paragraphs)
    }

    private func isNonempty(_ value: SourceRuleValue) -> Bool {
        switch value {
        case .node, .captures: true
        case .json(let value): value != .null
        case .text(let text): text.sourceNonempty != nil
        }
    }

    private func single(
        _ expression: String,
        from value: SourceRuleValue,
        elements: Bool,
        paragraphs: Bool
    ) throws -> [SourceRuleValue] {
        let lower = expression.lowercased()
        if lower.contains("@js:") || lower.contains("<js>") || lower.contains("<webjs>") || lower.contains("@webjs:") {
            throw SourceError.unsupportedRule("JavaScript")
        }
        if lower.contains("@put:") || lower.contains("@get:") {
            throw SourceError.unsupportedRule("状态变量")
        }
        if expression.contains("{{") {
            let regex = try NSRegularExpression(pattern: #"(?s)\{\{(.*?)\}\}"#)
            let original = expression as NSString
            let rendered = NSMutableString(string: expression)
            let matches = regex.matches(in: expression, range: NSRange(location: 0, length: original.length))
            for match in matches.reversed() {
                let inner = original.substring(with: match.range(at: 1)).sourceTrimmed
                guard inner.hasPrefix("@") || inner.hasPrefix("$") || inner.hasPrefix("/") else {
                    throw SourceError.unsupportedRule("内嵌表达式 \(inner)")
                }
                let replacement = try text(inner, from: value) ?? ""
                rendered.replaceCharacters(in: match.range, with: replacement)
            }
            return [.text(rendered as String)]
        }
        if case .captures(let captures) = value,
           expression.hasPrefix("$"), let index = Int(expression.dropFirst()), captures.indices.contains(index) {
            return [.text(captures[index])]
        }
        if elements && expression.hasPrefix(":") {
            return try regexMatches(String(expression.dropFirst()), in: value.markup)
        }
        if lower.hasPrefix("@json:") || expression.hasPrefix("$.") || expression.hasPrefix("$[") || expression == "$" {
            let rule = lower.hasPrefix("@json:") ? String(expression.dropFirst(6)) : expression
            let json: SourceJSON
            if case .json(let root) = value {
                json = root
            } else if let root = try? JSONDecoder().decode(SourceJSON.self, from: Data(value.string.utf8)) {
                json = root
            } else {
                return []
            }
            return try jsonValues(rule, in: json, elements: elements)
        }
        if case .json(let json) = value {
            return try jsonValues(expression, in: json, elements: elements)
        }
        let node: SourceHTMLNode
        if case .node(let existing) = value {
            node = existing
        } else {
            node = SourceHTML.parse(value.string)
        }
        if lower.hasPrefix("@xpath:") || expression.hasPrefix("/") || expression.hasPrefix("./") ||
            expression.hasPrefix("(//") || expression.hasPrefix("(.//") ||
            lower.hasPrefix("string(") || lower.hasPrefix("normalize-space(") {
            let rule = lower.hasPrefix("@xpath:") ? String(expression.dropFirst(7)) : expression
            let values = try SourceXPath.select(rule, in: node)
            if paragraphs, !elements {
                return values.map {
                    if case .node(let node) = $0 { return .text(node.renderedText) }
                    return $0
                }
            }
            return values
        }
        return try htmlValues(expression, in: node, elements: elements, paragraphs: paragraphs)
    }

    private func jsonValues(_ expression: String, in value: SourceJSON, elements: Bool) throws -> [SourceRuleValue] {
        let selected = try SourceJSONPath.select(expression, in: value)
        if elements || selected.count == 1 {
            return selected.flatMap { $0.items ?? [$0] }.map(SourceRuleValue.json)
        }
        return selected.map(SourceRuleValue.json)
    }

    private func htmlValues(
        _ expression: String,
        in node: SourceHTMLNode,
        elements: Bool,
        paragraphs: Bool
    ) throws -> [SourceRuleValue] {
        let explicitCSS = expression.lowercased().hasPrefix("@css:")
        let rule = explicitCSS ? String(expression.dropFirst(5)) : String(expression.drop(while: { $0 == "@" }))
        var parts = splitSourceRule(rule, on: "@").map(\.sourceTrimmed).filter { !$0.isEmpty }
        guard let last = parts.last else { return [] }
        let output = !elements && (parts.count > 1 || isOutput(last, on: node)) ? parts.removeLast() : nil
        var nodes = [node]
        for selector in parts {
            nodes = try uniqueSourceNodes(nodes.flatMap { node in
                if explicitCSS { return try SourceCSS.select(selector, in: node) }
                return try nativeSelect(selector, in: node)
            })
        }
        if elements { return nodes.map(SourceRuleValue.node) }
        return nodes.compactMap { node in
            let result: String?
            switch output?.lowercased() {
            case nil, "text": result = paragraphs ? node.renderedText : node.text
            case "owntext": result = node.ownText
            case "textnodes":
                result = node.children.filter { $0.tag == nil }.compactMap { $0.value.sourceNonempty }.joined(separator: "\n")
            case "html", "all", "outerhtml": result = node.outerHTML
            case "innerhtml": result = node.innerHTML
            default: result = output.flatMap { node.attributes[$0.lowercased()] }
            }
            return result.map(SourceRuleValue.text)
        }
    }

    private func isOutput(_ value: String, on node: SourceHTMLNode) -> Bool {
        let field = value.lowercased()
        return node.attributes[field] != nil || [
            "text", "owntext", "textnodes", "html", "all", "innerhtml", "outerhtml", "href", "src", "content", "value"
        ].contains(field) || field.hasPrefix("data-") || field.hasPrefix("aria-")
    }

    private func nativeSelect(_ value: String, in node: SourceHTMLNode) throws -> [SourceHTMLNode] {
        let suffix = sourceCaptures(#"^(.*?)(?:([.!])(-?\d+(?::-?\d+)*))$"#, in: value)
        let indexed = sourceCaptures(#"^((?:tag\.|class\.|id\.|text\.|children).*?|)\[(!?[-\d:,\s]+)\]$"#, in: value)
        let rule = suffix?[1] ?? indexed?[1] ?? value
        let available: [SourceHTMLNode]
        if rule == "children" || rule.isEmpty {
            available = node.elements
        } else if rule.hasPrefix("class.") {
            let expected = rule.dropFirst(6)
            available = ([node] + node.descendants).filter {
                $0.attributes["class"]?.split(whereSeparator: \.isWhitespace).contains(expected) == true
            }
        } else if rule.hasPrefix("id.") {
            available = ([node] + node.descendants).filter { $0.attributes["id"] == String(rule.dropFirst(3)) }
        } else if rule.hasPrefix("tag.") {
            available = ([node] + node.descendants).filter { $0.tag == rule.dropFirst(4).lowercased() }
        } else if rule.hasPrefix("text.") {
            let search = String(rule.dropFirst(5))
            available = ([node] + node.descendants).filter { $0.ownText.localizedCaseInsensitiveContains(search) }
        } else {
            available = try SourceCSS.select(rule, in: node)
        }
        guard !available.isEmpty else { return [] }
        if let suffix {
            let matches = suffix[3].split(separator: ":").compactMap { Int($0) }
            return applyIndices(matches, to: available, excluding: suffix[2] == "!")
        }
        if let indexed {
            let excludes = indexed[2].hasPrefix("!")
            let list = excludes ? String(indexed[2].dropFirst()) : indexed[2]
            let indices = list.split(separator: ",").flatMap { range -> [Int] in
                let parts = range.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 1 { return Int(String(parts[0]).sourceTrimmed).map { [$0] } ?? [] }
                let start = clampedIndex(Int(String(parts[0]).sourceTrimmed) ?? 0, count: available.count)
                let end = clampedIndex(Int(String(parts[1]).sourceTrimmed) ?? available.count - 1, count: available.count)
                let parsedStep = parts.count > 2 ? Int(String(parts[2]).sourceTrimmed) ?? 1 : 1
                let step = max(1, min(available.count, parsedStep > 0 ? parsedStep : parsedStep + available.count))
                return start <= end
                    ? Array(stride(from: start, through: end, by: step))
                    : Array(stride(from: start, through: end, by: -step))
            }
            return applyIndices(indices, to: available, excluding: excludes)
        }
        return available
    }

    private func applyIndices(_ indices: [Int], to values: [SourceHTMLNode], excluding: Bool) -> [SourceHTMLNode] {
        var seen = Set<Int>()
        let valid = indices.map { $0 >= 0 ? $0 : $0 + values.count }
            .filter { values.indices.contains($0) && seen.insert($0).inserted }
        return excluding ? values.enumerated().filter { !seen.contains($0.offset) }.map(\.element) : valid.map { values[$0] }
    }

    private func clampedIndex(_ index: Int, count: Int) -> Int {
        max(0, min(count - 1, index >= 0 ? index : index + count))
    }

    private func regexMatches(_ expression: String, in text: String) throws -> [SourceRuleValue] {
        guard let regex = try? NSRegularExpression(pattern: expression) else {
            throw SourceError.unsupportedRule("正则表达式 \(expression)")
        }
        let original = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: original.length)).map { match in
            .captures((0..<match.numberOfRanges).map {
                let range = match.range(at: $0)
                return range.location == NSNotFound ? "" : original.substring(with: range)
            })
        }
    }

    static func replace(in text: String, pattern: String, replacement: String, firstMatchOnly: Bool = false) -> String {
        guard !pattern.isEmpty else { return text }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.replacingOccurrences(of: pattern, with: replacement)
        }
        let range = NSRange(text.startIndex..., in: text)
        if firstMatchOnly {
            guard let match = regex.firstMatch(in: text, range: range) else { return "" }
            return regex.replacementString(for: match, in: text, offset: 0, template: replacement)
        }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
