import Foundation
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
