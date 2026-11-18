import Foundation
import Testing
import zlib
@testable import Englishwords

@Test("StarDict 导入普通和压缩正文，按启用的来源顺序查询", arguments: [false, true])
@MainActor
func starDictImportAndSourceOrder(compressed: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = folder.appendingPathComponent("demo.ifo")
    var index = Data()
    var definitions = Data()
    for (word, meaning) in [("apple", "导入的苹果"), ("banana", "香蕉"), ("pear", "梨")] {
        let body = Data(meaning.utf8)
        index.append(contentsOf: word.utf8)
        index.append(0)
        for value in [definitions.count, body.count] {
            var bigEndian = UInt32(value).bigEndian
            withUnsafeBytes(of: &bigEndian) { index.append(contentsOf: $0) }
        }
        definitions.append(body)
    }
    try index.write(to: folder.appendingPathComponent("demo.idx"))
    if compressed {
        let handle = try #require(gzopen(folder.appendingPathComponent("demo.dict.dz").path, "wb"))
        let count = definitions.withUnsafeBytes { gzwrite(handle, $0.baseAddress, UInt32($0.count)) }
        #expect(Int(count) == definitions.count)
        #expect(gzclose(handle) == Z_OK)
    } else {
        try definitions.write(to: folder.appendingPathComponent("demo.dict"))
    }
    try """
    StarDict's dict ifo file
    version=2.4.2
    bookname=三词测试字典
    wordcount=3
    idxfilesize=\(index.count)
    sametypesequence=m
    """.write(to: fixture, atomically: true, encoding: .utf8)

    let library = StarDictLibrary(directory: folder.appendingPathComponent("imports", isDirectory: true))
    let imported = try await library.importDictionary(from: fixture)
    #expect(try await library.lookup("Apple", source: imported)?.translation == "导入的苹果")
    #expect(try await library.lookup("banana", source: imported)?.translation == "香蕉")
    #expect(try await library.lookup("pear", source: imported)?.translation == "梨")
    #expect(try await library.lookup("orange", source: imported) == nil)

    let defaultsName = "notchword.test.stardict.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let preferences = Preferences(defaults: defaults)
    preferences.dictionarySources = [imported] + DictionarySource.defaults
    let builtin = folder.appendingPathComponent("builtin.sqlite")
    try writeSQLite(builtin, """
        CREATE TABLE words (word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, pos TEXT, tag TEXT);
        CREATE TABLE forms (form TEXT PRIMARY KEY, lemma TEXT);
        INSERT INTO words VALUES ('apple', '', '内置的苹果', '', '');
        """)
    let coordinator = LookupCoordinator(
        store: DictionaryStore(dictionaryURL: builtin, wordpartsURL: nil),
        systemDictionary: NoSystemGloss(),
        translator: UnexpectedTranslation(),
        preferences: preferences,
        starDictionaries: library
    )
    let request = LookupRequest(text: "apple", trigger: .hotkey, screen: nil)
    let (states, feed) = AsyncStream<LookupState>.makeStream()
    defer { feed.finish() }
    coordinator.onState = { feed.yield($0) }
    coordinator.submit(request)
    let importedName = try await firstResult(in: states)
    #expect(importedName == imported.name)

    preferences.dictionarySources[0].enabled = false
    coordinator.submit(request)
    let builtinName = try await firstResult(in: states)
    #expect(builtinName == "内置词库")
    try await library.remove(imported)
}

@MainActor
private func firstResult(in states: AsyncStream<LookupState>) async throws -> String {
    try await withTimeout(2) {
        for await state in states {
            if case .result(_, let result) = state { return result.source }
            if case .failure(_, let message) = state { throw StarDictError.invalid(message) }
        }
        return ""
    }
}

private struct NoSystemGloss: SystemDictionaryLooking {
    func lookup(_ word: String) -> Entry? { nil }
}

@MainActor
private struct UnexpectedTranslation: Translating {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        throw TranslationError.service("测试应直接查到词典")
    }
}
