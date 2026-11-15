import Foundation
import LegadoCore
import SwiftUI

private struct FeedSubscription: Identifiable, Codable {
    let id: UUID
    let url: URL
    let title: String

    init(url: URL, title: String) {
        id = UUID()
        self.url = url
        self.title = title
    }
}

struct FeedSubscriptionsView: View {
    @AppStorage("readerFeedSubscriptions") private var storedSubscriptions = Data()
    @State private var isAdding = false

    private var subscriptions: [FeedSubscription] {
        let decoded = (try? JSONDecoder().decode([FeedSubscription].self, from: storedSubscriptions)) ?? []
        var identifiers = Set<UUID>()
        var urls = Set<URL>()
        return decoded.filter { subscription in
            SyndicationReader.webURL(subscription.url.absoluteString) != nil
                && identifiers.insert(subscription.id).inserted && urls.insert(subscription.url).inserted
        }
    }

    var body: some View {
        List {
            ForEach(subscriptions) { subscription in
                NavigationLink {
                    FeedArticlesView(subscription: subscription)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subscription.title).font(.headline)
                        Text(subscription.url.host ?? subscription.url.absoluteString)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .onDelete { offsets in
                var remaining = subscriptions
                remaining.remove(atOffsets: offsets)
                save(remaining)
            }
        }
        .overlay {
            if subscriptions.isEmpty {
                ContentUnavailableView {
                    Label("暂无订阅", systemImage: "dot.radiowaves.left.and.right")
                } actions: {
                    Button("添加订阅") { isAdding = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("订阅")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加订阅", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddFeedView(existingURLs: Set(subscriptions.map(\.url))) { subscription in
                let current = subscriptions
                if !current.contains(where: { $0.url == subscription.url }) { save(current + [subscription]) }
            }
        }
    }

    private func save(_ subscriptions: [FeedSubscription]) {
        if let data = try? JSONEncoder().encode(subscriptions) { storedSubscriptions = data }
    }
}

private struct AddFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var validation: Task<Void, Never>?
    @State private var failure: String?
    let existingURLs: Set<URL>
    let onAdd: (FeedSubscription) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("RSS 或 Atom 地址", text: $address, prompt: Text("https://"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .disabled(validation != nil)
                    .onSubmit(add)
                if validation != nil { ProgressView("正在读取订阅") }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: add)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validation != nil)
                }
            }
            .onDisappear { validation?.cancel() }
        }
    }

    private func add() {
        guard validation == nil else { return }
        guard let input = SyndicationReader.webURL(address), var components = URLComponents(url: input, resolvingAgainstBaseURL: true) else {
            failure = SyndicationError.invalidURL.localizedDescription
            return
        }
        components.fragment = nil
        guard let url = components.url else { return }
        guard !existingURLs.contains(url) else {
            failure = "此地址已订阅。"
            return
        }
        failure = nil
        validation = Task {
            defer { validation = nil }
            do {
                let feed = try await SyndicationReader.fetch(url)
                guard !Task.isCancelled else { return }
                onAdd(FeedSubscription(url: url, title: feed.title))
                dismiss()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

private struct FeedArticlesView: View {
    @State private var feed: SyndicationFeed?
    @State private var failure: String?
    @State private var loading = false
    let subscription: FeedSubscription

    var body: some View {
        Group {
            if let feed, !feed.articles.isEmpty {
                List {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(feed.articles) { article in
                        NavigationLink {
                            FeedArticleView(article: article)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(article.title).font(.headline)
                                if let date = article.date {
                                    Text(date, format: .dateTime.year().month().day())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if !article.summary.isEmpty {
                                    Text(article.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .refreshable { await refresh() }
            } else if loading {
                ProgressView("正在读取订阅")
            } else if let failure {
                ContentUnavailableView {
                    Label("无法加载订阅", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { Task { await refresh() } }.buttonStyle(.bordered)
                }
            } else if feed != nil {
                ContentUnavailableView("暂无文章", systemImage: "doc.text")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(feed?.title ?? subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新订阅", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
            }
        }
        .task {
            if feed == nil { await refresh() }
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            feed = try await SyndicationReader.fetch(subscription.url)
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}

private struct FeedArticleView: View {
    let article: SyndicatedArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.title).font(.title.bold())
                if let date = article.date {
                    Text(date, format: .dateTime.year().month().day()).font(.subheadline).foregroundStyle(.secondary)
                }
                if !article.summary.isEmpty {
                    Text(article.summary).lineSpacing(5).textSelection(.enabled)
                }
                if let url = article.url {
                    Link(destination: url) { Label("打开原文", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("文章")
        .navigationBarTitleDisplayMode(.inline)
    }
}
