import Foundation

public struct TextReplacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String = "", pattern: String = "", replacement: String = "",
                isRegex: Bool = true, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.isEnabled = isEnabled
    }

    public func validate() throws {
        if isRegex && !pattern.isEmpty { _ = try NSRegularExpression(pattern: pattern) }
    }

    public static func apply(_ rules: [Self], to text: String) -> String {
        rules.reduce(text) { result, rule in
            guard rule.isEnabled, !rule.pattern.isEmpty else { return result }
            guard rule.isRegex else {
                return result.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: .literal)
            }
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return result }
            return regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                   withTemplate: rule.replacement)
        }
    }
}
