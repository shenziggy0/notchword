import AppKit
import SwiftUI

private typealias NotebookViewState<Value> = State<Value>

@MainActor
final class NotebookModel: ObservableObject {
    @Published private(set) var favorites: [String] = []
    @Published private(set) var history: [NotebookLookup] = []
    @Published private(set) var stats: NotebookStats?
    @Published private(set) var updating: Set<String> = []
    @Published private(set) var error: String?
    @Published private(set) var didLoad = false
    @Published private(set) var favoriteMeanings: [String: String] = [:]
    @Published private(set) var examples: [String: [FavoriteExample]] = [:]
    @Published private(set) var review: [ReviewCard] = []
    @Published private(set) var reviewStarted = false
    var dictionary: DictionaryStore?
    var launchVideo: ((VideoBookmark) -> Void)?
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

    func loadExamples(_ word: String) async {
        do {
            let saved = try await store.examples(word: word)
            examples[word] = saved
            if saved.isEmpty, let dictionary, let entry = try? await dictionary.lookupAsync(word).get() {
                favoriteMeanings[word] = String(entry.translation.split(separator: "\n").first ?? "")
            }
        } catch { self.error = error.localizedDescription }
    }

    func saveExample(word: String, context: LookupContext, meaning: String) async -> Bool {
        guard updating.insert(word).inserted else { return false }
        defer { updating.remove(word) }
        do {
            try await store.saveExample(word: word, context: context, meaning: meaning)
            favorites = try await store.favorites()
            examples[word] = try await store.examples(word: word)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func startReview() async {
        do {
            var cards: [ReviewCard] = []
            for word in try await store.reviewWords() {
                if let example = try await store.examples(word: word).first {
                    cards.append(ReviewCard(word: word, prompt: example.prompt, meaning: example.meaning))
                } else if let dictionary, let entry = try? await dictionary.lookupAsync(word).get() {
                    cards.append(ReviewCard(word: word, prompt: entry.translation, meaning: entry.translation))
                } else {
                    cards.append(ReviewCard(word: word, prompt: word, meaning: "回想这个词的意思"))
                }
            }
            review = cards
            reviewStarted = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func setFavorite(_ word: String, on: Bool) async {
        guard updating.insert(word).inserted else { return }
        defer { updating.remove(word) }
        do {
            try await store.setFavorite(word: word, on: on)
            if !on {
                examples[word] = nil
                favoriteMeanings[word] = nil
            }
            favorites = try await store.favorites()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReviewCard: Identifiable {
    var id: String { word }
    let word: String
    let prompt: String
    let meaning: String
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
    @NotebookViewState private var reviewing = false
    @NotebookViewState private var revealed: Set<String> = []
    @NotebookViewState private var pendingRemoval: String?
    @NotebookViewState private var confirmsRemoval = false
    @NotebookViewState private var loadingReview = false
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
            HStack {
                Button("复习 3 个词") {
                    loadingReview = true
                    Task {
                        defer { loadingReview = false }
                        await model.startReview()
                        revealed = []
                        reviewing = model.reviewStarted
                    }
                }.disabled(loadingReview)
                if reviewing { Button("返回笔记本") { reviewing = false } }
            }
            Group {
                if reviewing { reviewList }
                else {
                    switch page {
                    case .favorites: favoriteList
                    case .history: historyList
                    case .statistics: statistics
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .lexiconPage()
        .confirmationDialog("移除收藏及该词的例句？", isPresented: $confirmsRemoval) {
            Button("移除收藏", role: .destructive) {
                if let word = pendingRemoval { Task { await model.setFavorite(word, on: false) } }
            }
        }
    }

    private var reviewList: some View {
        Group {
            if model.review.isEmpty {
                empty(title: "暂时没有需要复习的词", message: "最近七天在不同日期主动查过的词会出现在这里。", icon: "book")
            } else {
                List(model.review) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.prompt)
                        if revealed.contains(card.word) {
                            Text("\(card.word) · \(card.meaning)").font(.callout.weight(.semibold))
                        } else {
                            Button("显示答案") { _ = revealed.insert(card.word) }
                        }
                    }
                }
            }
        }
    }

    private func highlightedSentence(_ example: FavoriteExample) -> Text {
        let context = example.context
        guard let range = Range(context.range, in: context.sentence) else { return Text(context.sentence) }
        return Text(String(context.sentence[..<range.lowerBound])) +
            Text(String(context.sentence[range])).bold().foregroundColor(Lexicon.accent) +
            Text(String(context.sentence[range.upperBound...]))
    }

    private func exampleRows(_ examples: [FavoriteExample]) -> some View {
        ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
            VStack(alignment: .leading, spacing: 3) {
                Text(example.meaning).font(.callout)
                highlightedSentence(example).font(.callout)
                if let video = example.context.video, let launchVideo = model.launchVideo {
                    Button("返回视频时间点") { launchVideo(video) }
                }
            }
        }
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
                        VStack(alignment: .leading, spacing: 5) {
                            wordButton(word)
                            if let examples = model.examples[word], !examples.isEmpty {
                                exampleRows(Array(examples.prefix(1)))
                                if examples.count > 1 {
                                    DisclosureGroup("更多原句") { exampleRows(Array(examples.dropFirst())) }
                                }
                            } else if let meaning = model.favoriteMeanings[word] {
                                Text(meaning).font(.callout).foregroundStyle(Lexicon.secondary)
                            }
                        }.task(id: word) { await model.loadExamples(word) }
                        Button(role: .destructive) {
                            Task {
                                await model.loadExamples(word)
                                if model.examples[word]?.isEmpty == false {
                                    pendingRemoval = word
                                    confirmsRemoval = true
                                } else if model.examples[word] != nil {
                                    await model.setFavorite(word, on: false)
                                }
                            }
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
            Task {
                if isFavorite {
                    await model.loadExamples(word)
                    guard let saved = model.examples[word] else { return }
                    if !saved.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = "移除收藏及该词的例句？"
                        alert.addButton(withTitle: "移除")
                        alert.addButton(withTitle: "取消")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                }
                await model.setFavorite(word, on: !isFavorite)
            }
        } label: {
            LexiconIcon(isFavorite ? .bookmarked : .bookmark, size: 16)
        }
        .buttonStyle(LexiconIconButtonStyle(active: isFavorite))
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏单词")
        .help(model.error ?? (isFavorite ? "取消收藏" : "收藏单词"))
        .disabled(model.updating.contains(word))
    }
}
