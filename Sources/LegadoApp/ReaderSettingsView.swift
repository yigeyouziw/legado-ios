import SwiftUI
import UIKit

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper, system, green, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .paper: "暖纸"
        case .system: "跟随系统"
        case .green: "浅绿"
        case .dark: "夜间"
        }
    }

    func palette(for scheme: ColorScheme) -> ReaderColors {
        switch self {
        case .paper:
            .init(background: 0xF8F3E8, ink: 0x322921, secondaryInk: 0x6C5B4B, accent: 0x93442F)
        case .system:
            scheme == .dark
                ? .init(background: 0x161618, ink: 0xF2F1F6, secondaryInk: 0xB6B5C1, accent: 0xC5BAFE)
                : .init(background: 0xFFFFFF, ink: 0x25252A, secondaryInk: 0x626269, accent: 0x5544A2)
        case .green:
            .init(background: 0xE6EDE0, ink: 0x283A2C, secondaryInk: 0x526453, accent: 0x365C43)
        case .dark:
            .init(background: 0x1D1B1A, ink: 0xF0E7DA, secondaryInk: 0xC2B3A0, accent: 0xF1A68B)
        }
    }
}

struct ReaderColors {
    let background: Color
    let ink: Color
    let inkColor: UIColor
    let secondaryInk: Color
    let accent: Color

    init(background: UInt32, ink: UInt32, secondaryInk: UInt32, accent: UInt32) {
        let foreground = Self.color(ink)
        self.background = Color(uiColor: Self.color(background))
        self.inkColor = foreground
        self.ink = Color(uiColor: foreground)
        self.secondaryInk = Color(uiColor: Self.color(secondaryInk))
        self.accent = Color(uiColor: Self.color(accent))
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ReaderFlow: String, CaseIterable, Identifiable {
    case scroll, pages

    var id: Self { self }
    var title: String { self == .scroll ? "上下滚动" : "左右翻页" }
}

enum ReaderScript: String, CaseIterable, Identifiable {
    case original, simplified, traditional

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "原文"
        case .simplified: "简体"
        case .traditional: "繁體"
        }
    }

    func render(_ content: String) -> String {
        let transform: StringTransform
        switch self {
        case .original: return content
        case .simplified: transform = StringTransform("Traditional-Simplified")
        case .traditional: transform = StringTransform("Simplified-Traditional")
        }
        return content.applyingTransform(transform, reverse: false) ?? content
    }
}

enum ReaderTypeface: String, CaseIterable, Identifiable {
    case system, serif

    var id: Self { self }
    var title: String { self == .system ? "系统" : "衬线" }
    var design: Font.Design { self == .system ? .default : .serif }
}

struct ReaderTypography: Equatable {
    let pointSize: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let typeface: ReaderTypeface
    let bold: Bool
    let indent: Bool

    var bodyFont: Font {
        .system(size: pointSize, weight: bold ? .semibold : .regular, design: typeface.design)
    }

    var titleFont: Font {
        .system(size: titleSize, weight: .semibold, design: typeface.design)
    }

    var titleSize: Double { pointSize * 1.45 }

    @MainActor
    func uiFont(size: Double? = nil, title: Bool = false) -> UIFont {
        let font = UIFont.systemFont(ofSize: size ?? pointSize, weight: title || bold ? .semibold : .regular)
        guard typeface == .serif, let descriptor = font.fontDescriptor.withDesign(.serif) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    func indented(_ paragraph: String) -> String {
        indent ? "　　" + paragraph : paragraph
    }
}

@MainActor
struct ReaderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var fontScale: Double = 1

    @Binding var theme: ReaderTheme
    @Binding var flow: ReaderFlow
    @Binding var script: ReaderScript
    @Binding var typeface: ReaderTypeface
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var paragraphSpacing: Double
    @Binding var bold: Bool
    @Binding var indent: Bool

    private var typography: ReaderTypography {
        .init(
            pointSize: fontSize * fontScale, lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing, typeface: typeface, bold: bold, indent: indent
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .listRowInsets(EdgeInsets())
                }

                Section("外观") {
                    Picker("主题", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { item in Text(item.title).tag(item) }
                    }
                    Picker("字体", selection: $typeface) {
                        ForEach(ReaderTypeface.allCases) { item in Text(item.title).tag(item) }
                    }
                    Toggle("加粗正文", isOn: $bold)
                    metricSlider("字号", value: $fontSize, range: 14...34)
                    metricSlider("行距", value: $lineSpacing, range: 2...18)
                    metricSlider("段距", value: $paragraphSpacing, range: 4...24)
                    Toggle("段首缩进", isOn: $indent)
                }

                Section("阅读") {
                    Picker("翻页方式", selection: $flow) {
                        ForEach(ReaderFlow.allCases) { item in Text(item.title).tag(item) }
                    }
                    Picker("简繁转换", selection: $script) {
                        ForEach(ReaderScript.allCases) { item in Text(item.title).tag(item) }
                    }
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var preview: some View {
        let palette = theme.palette(for: colorScheme)
        return VStack(alignment: .leading, spacing: paragraphSpacing) {
            Text(script.render("山间小径"))
                .font(typography.titleFont)
                .accessibilityAddTraits(.isHeader)
            Text(typography.indented(script.render("雨过之后，山间的松树透出清香。小径沿溪水蜿蜒，一直通向远处的村落。")))
                .font(typography.bodyFont)
                .lineSpacing(lineSpacing)
        }
        .foregroundStyle(palette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(palette.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("阅读预览")
    }

    private func metricSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Slider(value: value, in: range, step: 1) { Text(title) }
                .accessibilityValue(Text(value.wrappedValue, format: .number.precision(.fractionLength(0))))
        }
    }
}
