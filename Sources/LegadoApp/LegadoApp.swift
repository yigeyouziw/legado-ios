import SwiftUI
import UniformTypeIdentifiers

@main
struct LegadoApp: App {
    @State private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(library)
                .tint(ReaderPalette.accent)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task {
                        do {
                            switch url.pathExtension.lowercased() {
                            case "txt", "epub": try await library.importLocalFile(url)
                            case "json": _ = try await library.importSourceFile(url)
                            default: return
                            }
                        } catch { library.report("导入失败", error: error) }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.flushProgress() }
        }
    }
}

private struct MainView: View {
    @Environment(LibraryStore.self) private var library
    @State private var selection = AppTab.shelf

    var body: some View {
        @Bindable var library = library
        TabView(selection: $selection) {
            Tab("书架", systemImage: "books.vertical", value: AppTab.shelf) {
                NavigationStack { ShelfView() }
            }
            Tab("发现", systemImage: "safari", value: AppTab.discover) {
                NavigationStack { DiscoverView() }
            }
            Tab("管理", systemImage: "slider.horizontal.3", value: AppTab.manage) {
                NavigationStack { ManageView() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { BookSearchView() }
            } label: {
                Label("搜书", systemImage: "magnifyingglass")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .alert(item: $library.message) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("好")))
        }
    }
}

private enum AppTab: Hashable { case shelf, discover, manage, search }

enum ReaderPalette {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.49, green: 0.78, blue: 0.68, alpha: 1)
            : UIColor(red: 0.14, green: 0.39, blue: 0.32, alpha: 1)
    })
    static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemBackground
            : UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
    })
}

extension UTType {
    static var readerEPUB: Self { UTType(filenameExtension: "epub") ?? UTType("org.idpf.epub-container") ?? .data }
}
