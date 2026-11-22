import AppKit
import SwiftUI

@MainActor
final class NotebookModel: ObservableObject {
    @Published private(set) var favorites: [String] = []
    @Published private(set) var history: [NotebookLookup] = []
    @Published private(set) var stats: NotebookStats?
    @Published private(set) var updating: Set<String> = []
    @Published private(set) var error: String?
    @Published private(set) var didLoad = false
    @Published var search = ""

    private let store: NotebookStore

    init(store: NotebookStore) {
        self.store = store
    }

    func loadFavorites() async {
        do {
            favorites = try await store.favorites()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        do {
            favorites = try await store.favorites()
            history = try await store.history()
            stats = try await store.stats()
            error = nil
            didLoad = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setFavorite(_ word: String, on: Bool) async {
        guard updating.insert(word).inserted else { return }
        defer { updating.remove(word) }
        do {
            try await store.setFavorite(word: word, on: on)
            favorites = try await store.favorites()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class NotebookWindow: NSObject, NSWindowDelegate {
    private let model: NotebookModel
    private let lookup: (String) -> Void
    private var window: NSWindow?

    init(model: NotebookModel, lookup: @escaping (String) -> Void) {
        self.model = model
        self.lookup = lookup
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let view = NotebookView(model: model, lookup: lookup)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "笔记本"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 640, height: 460))
            window.minSize = NSSize(width: 480, height: 350)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshIfVisible()
    }

    func refreshIfVisible() {
        guard isVisible else { return }
        Task { await model.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if !NSApp.windows.contains(where: {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
        }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct NotebookView: View {
    @ObservedObject var model: NotebookModel
    let lookup: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack {
                    Text(error)
                    Spacer()
                    Button("重试") { Task { await model.refresh() } }
                }
                .padding(12)
            }
            TabView {
                favoriteList.tabItem { Label("收藏", systemImage: "star") }
                historyList.tabItem { Label("历史", systemImage: "clock") }
                statistics.tabItem { Label("统计", systemImage: "chart.bar") }
            }
            .padding(12)
        }
    }

    private var favoriteList: some View {
        let search = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = model.favorites.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("搜索收藏", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索收藏")
            if words.isEmpty {
                empty(search.isEmpty ? "点击查词面板的星标收藏单词。" : "没有匹配的收藏。")
            } else {
                List(words, id: \.self) { word in
                    HStack {
                        Button(word) { lookup(word) }
                            .buttonStyle(.link)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.setFavorite(word, on: false) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("移除收藏")
                        .accessibilityLabel("移除 \(word) 的收藏")
                        .disabled(model.updating.contains(word))
                    }
                }
            }
        }
        .padding(12)
    }

    private var historyList: some View {
        Group {
            if model.history.isEmpty {
                empty("查过的单词会显示在这里。")
            } else {
                List(model.history) { row in
                    HStack {
                        Button(row.word) { lookup(row.word) }
                            .buttonStyle(.link)
                        Text(row.source).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statistics: some View {
        Group {
            if let stats = model.stats {
                List {
                    LabeledContent("累计查词", value: stats.total.formatted())
                    Section("最近七天") {
                        ForEach(stats.daily, id: \.date) { day in
                            LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted),
                                           value: day.count.formatted())
                        }
                    }
                    Section("常查单词") {
                        if stats.frequent.isEmpty {
                            Text("查词后会显示常查单词。").foregroundStyle(.secondary)
                        }
                        ForEach(stats.frequent, id: \.word) { item in
                            LabeledContent {
                                Text(item.count.formatted())
                            } label: {
                                Button(item.word) { lookup(item.word) }.buttonStyle(.link)
                            }
                        }
                    }
                }
            } else {
                empty("暂时无法读取统计。")
            }
        }
    }

    private func empty(_ message: String) -> some View {
        Group {
            if !model.didLoad && model.error == nil {
                ProgressView()
            } else {
                Text(model.error == nil ? message : "笔记本数据读取失败。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NotebookStar: View {
    @ObservedObject var model: NotebookModel
    let word: String

    var body: some View {
        let isFavorite = model.favorites.contains(word)
        Button {
            Task { await model.setFavorite(word, on: !isFavorite) }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .white.opacity(0.7))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏单词")
        .help(model.error ?? (isFavorite ? "取消收藏" : "收藏单词"))
        .disabled(model.updating.contains(word))
    }
}
