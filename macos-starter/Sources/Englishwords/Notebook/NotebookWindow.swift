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
    @Published fileprivate var page = NotebookPage.favorites

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
            window.tabbingMode = .disallowed
            window.setContentSize(NSSize(width: 760, height: 540))
            window.contentMinSize = NSSize(width: 460, height: 345)
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

fileprivate enum NotebookPage: String, CaseIterable {
    case favorites = "收藏", history = "历史", statistics = "统计"
    var glyph: LexiconIcon.Glyph {
        switch self {
        case .favorites: .bookmark
        case .history: .history
        case .statistics: .chart
        }
    }
    var title: String {
        switch self {
        case .favorites: "收藏单词"
        case .history: "查词历史"
        case .statistics: "学习统计"
        }
    }
}

struct NotebookView: View {
    @ObservedObject var model: NotebookModel
    let lookup: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searching: Bool
    @Namespace private var tabSelection
    private var page: NotebookPage { model.page }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { heading; Spacer(minLength: 0); navigation }
                VStack(alignment: .leading, spacing: 12) { heading; navigation }
            }
            if let error = model.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(error).frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试") { Task { await model.refresh() } }
                }
                .padding(12)
                .background(Lexicon.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            Group {
                switch page {
                case .favorites: favoriteList
                case .history: historyList
                case .statistics: statistics
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .lexiconPage()
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if model.didLoad {
                Group {
                    switch page {
                    case .favorites: Text("已收藏 \(model.favorites.count) 个单词")
                    case .history: Text("最近 \(model.history.count) 条记录")
                    case .statistics: Text("累计查词 \(model.stats?.total ?? 0) 次")
                    }
                }
                .font(.callout)
                .foregroundStyle(Lexicon.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var navigation: some View {
        HStack(spacing: 2) {
            ForEach(NotebookPage.allCases, id: \.self) { item in
                let selected = page == item
                Button {
                    guard !selected else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                        model.page = item
                    }
                } label: {
                    HStack(spacing: 5) {
                        LexiconIcon(item.glyph, size: 14)
                        Text(item.rawValue)
                    }
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(selected ? Lexicon.accent : .primary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 33)
                    .background {
                        if selected {
                            Capsule().fill(Lexicon.accent.opacity(0.14))
                                .matchedGeometryEffect(id: "selected", in: tabSelection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .padding(4)
        .lexiconGlass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("笔记本分类")
    }

    private var favoriteList: some View {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = model.favorites.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        return VStack(spacing: 12) {
            HStack(spacing: 9) {
                LexiconIcon(.search, size: 16).foregroundStyle(Lexicon.secondary)
                TextField("搜索收藏单词", text: $model.search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索收藏单词")
                    .focused($searching)
                    .focusEffectDisabled()
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                        searching = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Lexicon.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(Lexicon.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(searching ? Lexicon.accent : Lexicon.hairline,
                                            lineWidth: searching ? 2 : 1).allowsHitTesting(false))

            if words.isEmpty {
                empty(title: query.isEmpty ? "还没有收藏单词" : "找不到匹配的收藏",
                      message: query.isEmpty ? "在查词面板点一下书签，单词就会出现在这里。" : "试试更短的拼写，或清除搜索。",
                      icon: query.isEmpty ? "bookmark" : "magnifyingglass")
            } else {
                List(words, id: \.self) { word in
                    HStack(spacing: 12) {
                        wordButton(word)
                        Button(role: .destructive) {
                            Task { await model.setFavorite(word, on: false) }
                        } label: {
                            LexiconIcon(.trash, size: 16).frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .help("移除收藏")
                        .accessibilityLabel("移除 \(word) 的收藏")
                        .disabled(model.updating.contains(word))
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                    .listRowBackground(Lexicon.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .notebookSurface()
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if model.history.isEmpty {
            empty(title: "还没有查词记录", message: "查过的单词会按时间出现在这里。", icon: "clock")
        } else {
            List(model.history) { row in
                HStack(spacing: 12) {
                    Button { lookup(row.word) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: row.word).font(.system(.title3, weight: .semibold))
                            Text(verbatim: row.source).font(.callout).foregroundStyle(Lexicon.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(row.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout.monospacedDigit()).foregroundStyle(Lexicon.secondary)
                }
                .padding(.vertical, 5)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                .listRowBackground(Lexicon.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .notebookSurface()
        }
    }

    private func wordButton(_ word: String) -> some View {
        Button { lookup(word) } label: {
            Text(verbatim: word)
                .font(.system(.title3, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查询 \(word)")
    }

    @ViewBuilder
    private var statistics: some View {
        if let stats = model.stats {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("最近七天").font(.headline)
                            Spacer()
                            Text("合计 \(stats.daily.reduce(0) { $0 + $1.count }) 次").font(.callout.monospacedDigit())
                                .foregroundStyle(Lexicon.secondary)
                        }
                        HStack(alignment: .bottom, spacing: 8) {
                            let highest = max(1, stats.daily.map(\.count).max() ?? 0)
                            ForEach(stats.daily, id: \.date) { day in
                                let today = Calendar.current.isDateInToday(day.date)
                                VStack(spacing: 6) {
                                    Text(day.count.formatted()).font(.callout.monospacedDigit())
                                    ZStack(alignment: .bottom) {
                                        Capsule().fill(Lexicon.accent.opacity(0.08))
                                        if day.count > 0 {
                                            Capsule().fill(Lexicon.accent)
                                                .frame(height: max(2, 66 * CGFloat(day.count) / CGFloat(highest)))
                                        }
                                    }
                                    .frame(width: 15, height: 66)
                                    Text(today ? "今天" : day.date.formatted(.dateTime.day()))
                                        .font(.callout.weight(today ? .semibold : .regular))
                                        .foregroundStyle(today ? Lexicon.accent : Lexicon.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                                .accessibilityValue("\(day.count) 次")
                            }
                        }
                    }
                    .padding(18)
                    .notebookSurface()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("常查单词").font(.headline).padding(.bottom, 8)
                        if stats.frequent.isEmpty {
                            Text("查询后会在这里显示常查单词。").foregroundStyle(Lexicon.secondary)
                        }
                        ForEach(stats.frequent, id: \.word) { item in
                            Divider()
                            HStack(spacing: 12) {
                                wordButton(item.word)
                                Text("\(item.count) 次").font(.callout.monospacedDigit())
                                    .foregroundStyle(Lexicon.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .notebookSurface()
                }
            }
        } else {
            empty(title: "暂时无法读取统计", message: "可以重新加载笔记本。", icon: "chart.bar")
        }
    }

    private func empty(title: String, message: String, icon: String) -> some View {
        Group {
            if !model.didLoad && model.error == nil {
                ProgressView("正在读取笔记本")
            } else {
                ContentUnavailableView {
                    Label(model.error == nil ? title : "笔记本数据读取失败",
                          systemImage: model.error == nil ? icon : "exclamationmark.circle")
                } description: {
                    if model.error == nil { Text(message) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notebookSurface()
    }
}

private extension View {
    func notebookSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return background(Lexicon.surface, in: shape)
            .clipShape(shape).overlay(shape.strokeBorder(Lexicon.hairline).allowsHitTesting(false))
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
            LexiconIcon(isFavorite ? .bookmarked : .bookmark, size: 16)
        }
        .buttonStyle(LexiconIconButtonStyle(active: isFavorite))
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏单词")
        .help(model.error ?? (isFavorite ? "取消收藏" : "收藏单词"))
        .disabled(model.updating.contains(word))
    }
}
