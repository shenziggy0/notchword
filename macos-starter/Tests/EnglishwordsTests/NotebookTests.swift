import Foundation
import SQLite3
import Testing
@testable import Englishwords

@Test("笔记本持久化收藏、历史与本地日期统计")
func notebookPersistsUserData() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("user.sqlite")
    let store = NotebookStore(url: url)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 10)))
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))

    try await store.recordLookup(word: "believe", source: "内置词库", trigger: .hotkey, date: yesterday)
    try await store.recordLookup(word: "run", source: "系统词典", trigger: .selection, date: now)
    try await store.recordLookup(word: "believe", source: "内置词库", trigger: .notebook, date: now)
    try await store.setFavorite(word: "believe", on: true)
    try await store.setFavorite(word: "believe", on: true)

    let reopened = NotebookStore(url: url)
    #expect(try await reopened.favorites() == ["believe"])
    #expect(try await reopened.history(limit: 2).map(\.word) == ["believe", "run"])
    let stats = try await reopened.stats(now: now, calendar: calendar)
    #expect(stats.total == 3)
    #expect(stats.daily.map(\.count) == [0, 0, 0, 0, 0, 1, 2])
    #expect(stats.frequent.first?.word == "believe")
    #expect(stats.frequent.first?.count == 2)
    try await reopened.setFavorite(word: "believe", on: false)
    #expect(try await store.favorites().isEmpty)
}

@Test("正式词库保留 foiled 的两个读法，词组按点击位置匹配")
func contextualLookup() async throws {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Englishwords/Resources")
    let dictionary = DictionaryStore(dictionaryURL: resources.appendingPathComponent("dictionary.sqlite"),
                                     wordpartsURL: resources.appendingPathComponent("wordparts.sqlite"))
    #expect(try dictionary.lookup("foiled").get()?.translation.contains("有叶形装饰") == true)
    #expect(dictionary.readingHints(for: "foiled", excluding: "foiled") == ["foil 的过去式／过去分词 · 挫败、阻止"])
    let context = LookupContext(sentence: "Let me walk you through what actually happened.", range: NSRange(location: 16, length: 7))
    #expect(dictionary.phrase(in: context) == "walk you through · 带某人逐步了解")
    let punctuation = LookupContext(sentence: "I will walk you through.", range: NSRange(location: 16, length: 8))
    #expect(punctuation.selected == "through")
    #expect(dictionary.phrase(in: punctuation) == "walk you through · 带某人逐步了解")
    let ordinary = LookupContext(sentence: "I walk to school.", range: NSRange(location: 2, length: 4))
    #expect(dictionary.phrase(in: ordinary) == nil)
    let root = try #require(dictionary.morphology("abduct")?.segments.last?.partID)
    #expect(await dictionary.relatedWords(partID: root, excluding: "abduct").count == 3)
}

@Test("主动保存例句可重开，跨日复习不计自动取词")
func contextualNotebook() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("user.sqlite")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var legacy: OpaquePointer?
    #expect(sqlite3_open(url.path, &legacy) == SQLITE_OK)
    #expect(sqlite3_exec(legacy, """
        CREATE TABLE lookups(id INTEGER PRIMARY KEY, word TEXT NOT NULL, source TEXT NOT NULL,
          trigger TEXT NOT NULL, created_at INTEGER NOT NULL);
        CREATE INDEX lookups_created_at ON lookups(created_at);
        CREATE INDEX lookups_word ON lookups(word);
        CREATE TABLE favorites(word TEXT PRIMARY KEY, created_at INTEGER NOT NULL) WITHOUT ROWID;
        INSERT INTO favorites VALUES ('abduct', 1);
        INSERT INTO lookups VALUES (1, 'abduct', '内置词库', 'hotkey', 1);
        PRAGMA user_version = 1;
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(legacy)
    let store = NotebookStore(url: url)
    #expect(try await store.favorites() == ["abduct"])
    #expect(try await store.history().count == 1)
    let text = "They foiled it, then foiled it again."
    let context = LookupContext(sentence: text, range: NSRange(location: 21, length: 6))
    try await store.saveExample(word: "foil", context: context, meaning: "挫败")
    try await store.saveExample(word: "foil", context: context, meaning: "挫败")
    let reopened = NotebookStore(url: url)
    let examples = try await reopened.examples(word: "foil")
    #expect(examples.count == 1)
    #expect(examples.first?.context.selected == "foiled")
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
    for date in [today, yesterday] {
        try await store.recordLookup(word: "foil", source: "内置词库", trigger: .hotkey, date: date)
        try await store.recordLookup(word: "noise", source: "内置词库", trigger: .hover, date: date)
    }
    #expect(try await store.reviewWords() == ["foil"])
    #expect(try await store.stats().total == 5)
    try await store.setFavorite(word: "foil", on: false)
    #expect(try await reopened.examples(word: "foil").isEmpty)
}
