import CoreText
import SwiftUI
import UIKit

@MainActor
struct ReaderPager<Fallback: View>: View {
    let chapterID: String
    let title: String
    let paragraphs: [String]
    let typography: ReaderTypography
    let theme: ReaderTheme
    let colorScheme: ColorScheme
    let size: CGSize
    let location: ReaderProgress?
    let toggleChrome: () -> Void
    let onProgress: (ReaderProgress) -> Void
    let fallback: () -> Fallback

    @State private var pages = [Page]()
    @State private var selectedPage = 0
    @State private var completedLayout: LayoutRequest?

    init(
        chapterID: String, title: String, paragraphs: [String], typography: ReaderTypography, theme: ReaderTheme,
        colorScheme: ColorScheme, size: CGSize, location: ReaderProgress?, toggleChrome: @escaping () -> Void,
        onProgress: @escaping (ReaderProgress) -> Void, fallback: @escaping () -> Fallback
    ) {
        self.chapterID = chapterID
        self.title = title
        self.paragraphs = paragraphs
        self.typography = typography
        self.theme = theme
        self.colorScheme = colorScheme
        self.size = size
        self.location = location
        self.toggleChrome = toggleChrome
        self.onProgress = onProgress
        self.fallback = fallback
    }

    private var request: LayoutRequest {
        LayoutRequest(
            title: title, paragraphs: paragraphs, typography: typography, theme: theme, colorScheme: colorScheme,
            size: CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
        )
    }

    var body: some View {
        let layout = request
        Group {
            if completedLayout != layout {
                ProgressView().accessibilityLabel("正在分页")
            } else if pages.isEmpty {
                fallback()
            } else {
                VStack(spacing: 6) {
                    TabView(selection: Binding(get: { selectedPage }, set: select)) {
                        ForEach(pages.indices, id: \.self) { index in
                            pageView(pages[index], size: layout.size)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: layout.size.height)

                    Text("\(selectedPage + 1) / \(pages.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.palette(for: colorScheme).secondaryInk)
                        .accessibilityLabel("第 \(selectedPage + 1) 页，共 \(pages.count) 页")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: layout, initial: true) { _, newLayout in paginate(newLayout) }
    }

    private func pageView(_ page: Page, size: CGSize) -> some View {
        PageCanvas(frame: page.frame)
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleChrome)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: page.text))
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityAction(named: Text("切换阅读工具"), toggleChrome)
            .contextMenu {
                Button("复制本页", systemImage: "doc.on.doc") { UIPasteboard.general.string = page.text }
            }
    }

    private func select(_ index: Int) {
        guard pages.indices.contains(index), index != selectedPage else { return }
        selectedPage = index
        onProgress(pages[index].location)
    }

    private func paginate(_ layout: LayoutRequest) {
        let palette = layout.theme.palette(for: layout.colorScheme)
        let text = NSMutableAttributedString(string: "")
        let inkKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
        text.append(NSAttributedString(string: layout.title + "\n", attributes: [
            fontKey: coreTextFont(layout.typography.uiFont(size: layout.typography.titleSize, title: true)),
            paragraphKey: paragraphStyle(lineSpacing: 5, paragraphSpacing: 24),
            inkKey: palette.inkColor.cgColor,
        ]))

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            fontKey: coreTextFont(layout.typography.uiFont()),
            paragraphKey: paragraphStyle(lineSpacing: layout.typography.lineSpacing, paragraphSpacing: layout.typography.paragraphSpacing),
            inkKey: palette.inkColor.cgColor,
        ]
        var paragraphStarts = [Int]()
        for (index, paragraph) in layout.paragraphs.enumerated() {
            paragraphStarts.append(text.length)
            text.append(NSAttributedString(string: layout.typography.indented(paragraph), attributes: bodyAttributes))
            if index + 1 < layout.paragraphs.count {
                text.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            }
        }

        let newPages = makePages(text, paragraphStarts: paragraphStarts, layout: layout)
        pages = newPages
        selectedPage = newPages.lastIndex { page in
            guard let location = self.location else { return false }
            if page.location.paragraphIndex != location.paragraphIndex {
                return page.location.paragraphIndex < location.paragraphIndex
            }
            return (page.location.characterOffset ?? 0) <= (location.characterOffset ?? 0)
        } ?? 0
        completedLayout = layout
    }

    private func coreTextFont(_ font: UIFont) -> CTFont {
        CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
    }

    private func paragraphStyle(lineSpacing: CGFloat, paragraphSpacing: CGFloat) -> CTParagraphStyle {
        withUnsafePointer(to: lineSpacing) { line in
            withUnsafePointer(to: paragraphSpacing) { paragraph in
                let size = MemoryLayout<CGFloat>.size
                let values = [
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: size, value: UnsafeRawPointer(line)),
                    CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: UnsafeRawPointer(paragraph)),
                ]
                return CTParagraphStyleCreate(values, values.count)
            }
        }
    }

    private func makePages(_ text: NSAttributedString, paragraphStarts: [Int], layout: LayoutRequest) -> [Page] {
        guard !paragraphStarts.isEmpty else { return [] }
        let string = text.string as NSString
        let path = CGPath(rect: CGRect(origin: .zero, size: layout.size), transform: nil)
        let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let indentLength = layout.typography.indented("").utf16.count
        var newPages = [Page]()
        var start = 0
        var paragraph = 0

        while start < text.length {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            let end = visible.location + visible.length
            guard visible.location == start, start < end, end <= text.length else { return [] }

            while paragraph + 1 < paragraphStarts.count, paragraphStarts[paragraph + 1] <= start {
                paragraph += 1
            }
            let offset = min(max(0, start - paragraphStarts[paragraph] - indentLength), layout.paragraphs[paragraph].utf16.count)
            let progress = ReaderProgress(chapterID: chapterID, paragraphIndex: paragraph, characterOffset: offset > 0 ? offset : nil)
            let fragment = string.substring(with: NSRange(location: start, length: end - start))
            newPages.append(Page(frame: frame, location: progress, text: fragment))
            start = end
        }
        return newPages
    }

    private struct LayoutRequest: Equatable {
        let title: String
        let paragraphs: [String]
        let typography: ReaderTypography
        let theme: ReaderTheme
        let colorScheme: ColorScheme
        let size: CGSize
    }

    private struct Page {
        let frame: CTFrame
        let location: ReaderProgress
        let text: String
    }
}

private struct PageCanvas: UIViewRepresentable {
    let frame: CTFrame

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        view.textFrame = frame
        view.setNeedsDisplay()
    }

    final class CanvasView: UIView {
        var textFrame: CTFrame?

        override func draw(_ rect: CGRect) {
            guard let textFrame, let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            CTFrameDraw(textFrame, context)
            context.restoreGState()
        }
    }
}
