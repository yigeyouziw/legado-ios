import SwiftUI
import UIKit

struct ReaderChapter: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct ReaderProgress: Codable, Equatable, Sendable {
    let chapterID: String
    let paragraphIndex: Int
    var characterOffset: Int? = nil
}

@MainActor
struct ReaderView: View {
    let title: String
    let chapters: [ReaderChapter]
    let loadContent: @Sendable (Int) async throws -> String
    let onProgress: (ReaderProgress) -> Void
    let onBookmark: ((ReaderProgress) throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var fontScale: Double = 1

    @AppStorage("reader.theme") private var theme = ReaderTheme.paper
    @AppStorage("reader.flow") private var flow = ReaderFlow.scroll
    @AppStorage("reader.script") private var script = ReaderScript.original
    @AppStorage("reader.typeface") private var typeface = ReaderTypeface.serif
    @AppStorage("reader.fontSize") private var fontSize = 21.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 7.0
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = 12.0
    @AppStorage("reader.bold") private var bold = false
    @AppStorage("reader.indent") private var indent = true

    @State private var cursor: Cursor
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var retryCount = 0
    @State private var content = ContentState.loading
    @State private var display = [String]()
    @State private var chromeVisible = true
    @State private var sheet: ReaderSheet?
    @State private var bookmarkFeedback = 0
    @State private var lastBookmark: ReaderProgress?
    @State private var bookmarkFailure: String?
    @State private var speech = ReaderSpeech()

    init(
        title: String,
        chapters: [ReaderChapter],
        initialProgress: ReaderProgress? = nil,
        loadContent: @escaping @Sendable (Int) async throws -> String,
        onProgress: @escaping (ReaderProgress) -> Void,
        onBookmark: ((ReaderProgress) throws -> Void)? = nil
    ) {
        self.title = title
        self.chapters = chapters
        self.loadContent = loadContent
        self.onProgress = onProgress
        self.onBookmark = onBookmark
        let index = chapters.firstIndex { $0.id == initialProgress?.chapterID }
        self.cursor = Cursor(index: index ?? 0, progress: index == nil ? nil : initialProgress)
    }

    private var chapterIndex: Int { cursor.index }
    private var progress: ReaderProgress? { cursor.progress }
    private var chapter: ReaderChapter? { chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil }
    private var palette: ReaderColors { theme.palette(for: colorScheme) }
    private var positionLabel: String { "第 \(chapterIndex + 1) 章 · 共 \(chapters.count) 章" }
    private var hasText: Bool { !display.isEmpty }

    private var typography: ReaderTypography {
        .init(
            pointSize: fontSize * fontScale, lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing, typeface: typeface, bold: bold, indent: indent
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            readingArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(palette.background.ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .navigationBar, .tabBar)
        .preferredColorScheme(theme == .system ? nil : theme == .dark ? .dark : .light)
        .task(id: RequestKey(index: chapterIndex, retry: retryCount)) {
            await openChapter(at: chapterIndex)
        }
        .onChange(of: script) { _, mode in
            if case .loaded(let original) = content { display = original.map(mode.render) }
        }
        .onChange(of: flow) { _, mode in
            if mode == .scroll, let progress { scrollPosition.scrollTo(id: progress.paragraphIndex, anchor: .top) }
        }
        .onDisappear { speech.stop() }
        .sheet(item: $sheet) { presentedSheet($0) }
        .sensoryFeedback(.success, trigger: bookmarkFeedback)
        .alert("无法保存书签", isPresented: Binding(
            get: { bookmarkFailure != nil },
            set: { if !$0 { bookmarkFailure = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(bookmarkFailure ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if chromeVisible {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                Text(script.render(title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                if onBookmark != nil {
                    Button(action: saveBookmark) {
                        Image(systemName: lastBookmark == progress && lastBookmark != nil ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText)
                    .opacity(hasText ? 1 : 0.35)
                    .accessibilityLabel(lastBookmark == progress && lastBookmark != nil ? "书签已保存" : "添加书签")
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            } else {
                Text(script.render(chapter?.title ?? title))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 48)
        .foregroundStyle(palette.ink)
        .overlay(alignment: .bottom) {
            if chromeVisible { Divider().overlay(palette.ink.opacity(0.08)) }
        }
    }

    private var footer: some View {
        Group {
            if chromeVisible {
                HStack(spacing: 0) {
                    tool("上一章", icon: "chevron.left", enabled: chapterIndex > 0) {
                        selectChapter(chapterIndex - 1)
                    }
                    tool("目录", icon: "list.bullet", enabled: !chapters.isEmpty) { sheet = .contents }
                    tool(speech.actionTitle, icon: speech.icon, enabled: hasText) { toggleSpeech() }
                        .contextMenu {
                            if speech.state != .stopped {
                                Button("停止朗读", systemImage: "stop.fill") { speech.stop() }
                            }
                        }
                    tool("设置", icon: "textformat.size") { sheet = .settings }
                    tool("下一章", icon: "chevron.right", enabled: chapterIndex + 1 < chapters.count) {
                        selectChapter(chapterIndex + 1)
                    }
                }
                .padding(.horizontal, 12)
            } else {
                Button(action: toggleChrome) {
                    HStack {
                        if chapter != nil {
                            Text(positionLabel).font(.caption2).monospacedDigit()
                        }
                        Spacer()
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 19))
                    }
                    .padding(.horizontal, 25)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("显示阅读工具")
                .accessibilityValue(chapter == nil ? "" : positionLabel)
                .foregroundStyle(palette.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .overlay(alignment: .top) {
            if chromeVisible { Divider().overlay(palette.ink.opacity(0.08)) }
        }
    }

    private func tool(_ title: String, icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? palette.ink : palette.secondaryInk.opacity(0.45))
    }

    @ViewBuilder
    private var readingArea: some View {
        switch content {
        case .loading:
            ProgressView("正在载入章节")
                .tint(palette.accent)
                .foregroundStyle(palette.secondaryInk)
        case .failed(let reason):
            ContentUnavailableView {
                Label("章节载入失败", systemImage: "exclamationmark.circle")
            } description: {
                Text(reason)
            } actions: {
                Button("重试") {
                    content = .loading
                    retryCount += 1
                }
                .buttonStyle(.bordered)
                .tint(palette.accent)
            }
            .foregroundStyle(palette.ink)
        case .loaded:
            if let chapter, hasText {
                textBody(for: chapter)
            } else {
                ContentUnavailableView("暂无正文", systemImage: "book.closed")
                    .foregroundStyle(palette.secondaryInk)
            }
        }
    }

    @ViewBuilder
    private func textBody(for chapter: ReaderChapter) -> some View {
        if flow == .pages {
            GeometryReader { proxy in
                let size = CGSize(width: min(max(proxy.size.width - 48, 0), 660), height: max(proxy.size.height - 48, 0))
                if size.height >= typography.uiFont().lineHeight * 2, size.width >= typography.pointSize * 3 {
                    ReaderPager(
                        chapterID: chapter.id, title: script.render(chapter.title), paragraphs: display,
                        typography: typography, theme: theme, colorScheme: colorScheme, size: size,
                        location: progress, toggleChrome: toggleChrome, onProgress: updateProgress
                    ) { scrollingText(for: chapter) }
                    .id(chapter.id)
                } else {
                    scrollingText(for: chapter)
                }
            }
        } else {
            scrollingText(for: chapter)
        }
    }

    private func scrollingText(for chapter: ReaderChapter) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: typography.paragraphSpacing) {
                Text(script.render(chapter.title))
                    .font(typography.titleFont)
                    .lineSpacing(5)
                    .foregroundStyle(palette.ink)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleChrome)
                    .accessibilityAddTraits(.isHeader)
                    .id(-1)

                ForEach(display.indices, id: \.self) { index in
                    Text(typography.indented(display[index]))
                        .font(typography.bodyFont)
                        .lineSpacing(typography.lineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggleChrome)
                        .id(index)
                }

                if chapterIndex + 1 < chapters.count {
                    Button("下一章", systemImage: "arrow.right") { selectChapter(chapterIndex + 1) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(palette.accent)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollTargetLayout()
            .foregroundStyle(palette.ink)
            .frame(maxWidth: 660)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition, anchor: .top)
        .onChange(of: scrollPosition.viewID(type: Int.self)) { _, id in
            guard scrollPosition.isPositionedByUser, let id else { return }
            updateProgress(ReaderProgress(chapterID: chapter.id, paragraphIndex: max(0, id)))
        }
    }

    @ViewBuilder
    private func presentedSheet(_ selection: ReaderSheet) -> some View {
        switch selection {
        case .contents:
            ReaderContentsView(chapters: chapters, selection: chapterIndex, script: script) { index in
                sheet = nil
                selectChapter(index)
            }
        case .settings:
            ReaderSettingsView(
                theme: $theme, flow: $flow, script: $script, typeface: $typeface,
                fontSize: $fontSize, lineSpacing: $lineSpacing, paragraphSpacing: $paragraphSpacing,
                bold: $bold, indent: $indent
            )
        }
    }

    private func openChapter(at index: Int) async {
        guard chapters.indices.contains(index) else {
            content = .loaded([])
            return
        }
        let requestedChapter = chapters[index]
        let retry = retryCount
        do {
            let raw = try await loadContent(index)
            try Task.checkCancellation()
            guard chapterIndex == index, retryCount == retry else { return }

            let original = paragraphs(from: raw, heading: requestedChapter.title)
            display = original.map(script.render)
            content = .loaded(original)
            guard !original.isEmpty else { return }

            let saved = progress?.chapterID == requestedChapter.id ? progress : nil
            let paragraph = min(max(0, saved?.paragraphIndex ?? 0), original.count - 1)
            let offset = min(max(0, saved?.characterOffset ?? 0), display[paragraph].utf16.count)
            scrollPosition.scrollTo(id: paragraph == 0 ? -1 : paragraph, anchor: .top)
            let startingPosition = ReaderProgress(
                chapterID: requestedChapter.id, paragraphIndex: paragraph, characterOffset: offset > 0 ? offset : nil
            )
            cursor.progress = startingPosition
            onProgress(startingPosition)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, chapterIndex == index, retryCount == retry else { return }
            content = .failed(error.localizedDescription)
        }
    }

    private func paragraphs(from text: String, heading: String) -> [String] {
        var result = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if result.count > 1, result.first == heading.trimmingCharacters(in: .whitespacesAndNewlines) {
            result.removeFirst()
        }
        return result
    }

    private func selectChapter(_ index: Int) {
        guard chapters.indices.contains(index), index != chapterIndex else { return }
        speech.stop()
        scrollPosition = ScrollPosition(idType: Int.self)
        display = []
        content = .loading
        cursor = Cursor(index: index, progress: nil)
    }

    private func updateProgress(_ location: ReaderProgress) {
        guard location.chapterID == chapter?.id, progress != location else { return }
        cursor.progress = location
        onProgress(location)
    }

    private func toggleChrome() {
        if reduceMotion {
            chromeVisible.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
        }
    }

    private func saveBookmark() {
        guard let progress, let onBookmark else { return }
        do {
            try onBookmark(progress)
            lastBookmark = progress
            bookmarkFeedback += 1
        } catch {
            bookmarkFailure = error.localizedDescription
        }
    }

    private func toggleSpeech() {
        guard let progress, display.indices.contains(progress.paragraphIndex) else { return }
        var remaining = Array(display.dropFirst(progress.paragraphIndex))
        if let offset = progress.characterOffset, offset > 0 {
            let first = remaining[0] as NSString
            if offset < first.length {
                remaining[0] = first.substring(from: first.rangeOfComposedCharacterSequence(at: offset).location)
            } else {
                remaining.removeFirst()
            }
        }
        speech.toggle(paragraphs: remaining)
    }

    private enum ContentState {
        case loading
        case loaded([String])
        case failed(String)
    }

    private enum ReaderSheet: String, Identifiable {
        case contents, settings
        var id: Self { self }
    }

    private struct RequestKey: Equatable {
        let index: Int
        let retry: Int
    }

    private struct Cursor {
        let index: Int
        var progress: ReaderProgress?
    }
}

private struct ReaderContentsView: View {
    let chapters: [ReaderChapter]
    let selection: Int
    let script: ReaderScript
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matchingIndices: [Int] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return chapters.indices.filter {
            phrase.isEmpty || chapters[$0].title.localizedStandardContains(phrase)
                || script.render(chapters[$0].title).localizedStandardContains(phrase)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(matchingIndices, id: \.self) { index in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack(spacing: 12) {
                            Text(script.render(chapters[index].title))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            if index == selection {
                                Image(systemName: "circle.inset.filled")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == selection ? .isSelected : [])
                    .id(index)
                }
                .overlay {
                    if matchingIndices.isEmpty { ContentUnavailableView.search(text: query) }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索章节")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
