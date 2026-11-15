import Testing
@testable import LegadoCore

@Test func replacementUsesRuleOrderAndSkipsDisabledRules() throws {
    let rules = [
        TextReplacement(pattern: "[广告]", isRegex: false),
        TextReplacement(pattern: "第(\\d+)章", replacement: "章节 $1"),
        TextReplacement(pattern: "章节", replacement: "禁用", isRegex: false, isEnabled: false),
        TextReplacement(pattern: "章节 3", replacement: "正文", isRegex: false)
    ]
    for rule in rules { try rule.validate() }
    #expect(TextReplacement.apply(rules, to: "[广告]第3章\n你好") == "正文\n你好")
    #expect(throws: (any Error).self) { try TextReplacement(pattern: "[").validate() }
}
