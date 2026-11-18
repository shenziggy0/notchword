import Foundation
import zlib

struct DictionarySource: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case builtin, system, stardict }

    let id: String
    let kind: Kind
    let name: String
    var enabled: Bool

    static let defaults = [
        DictionarySource(id: "builtin", kind: .builtin, name: "内置词库", enabled: true),
        DictionarySource(id: "system", kind: .system, name: "系统词典", enabled: true)
    ]
}

enum StarDictError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return "StarDict：\(message)"
        }
    }
}

private struct StarDictStore {
    private struct IndexEntry {
        let word: String
        let folded: String
        let bytes: Range<Int>
    }

    let name: String
    let files: [URL]
    private let types: [Character]
    private let data: Data
    private let index: [IndexEntry]

    init(ifo: URL) throws {
        let fields = try Self.metadata(ifo)
        guard let name = fields["bookname"], !name.isEmpty,
              let words = fields["wordcount"].flatMap(Int.init), words > 0,
              let size = fields["idxfilesize"].flatMap(Int.init), size > 0
        else { throw StarDictError.invalid("缺少词典名称、词条数或索引大小") }
        guard let version = fields["version"], ["2.4.2", "3.0.0"].contains(version) else {
            throw StarDictError.invalid("只支持 2.4.2 或 3.0.0")
        }
        let offsetBits = fields["idxoffsetbits"] ?? "32"
        guard offsetBits == "32" || (version == "3.0.0" && offsetBits == "64") else {
            throw StarDictError.invalid("不支持的索引偏移格式")
        }
        guard let sequence = fields["sametypesequence"], !sequence.isEmpty,
              sequence.allSatisfy({ "mthx".contains($0) })
        else { throw StarDictError.invalid("只支持声明了 m、t、h 或 x 文本类型的词典") }

        let base = ifo.deletingPathExtension()
        let idx = try Self.resource(base, extensions: ["idx", "idx.gz"])
        let dict = try Self.resource(base, extensions: ["dict", "dict.dz"])
        let indexData = try Self.read(idx, compressed: idx.pathExtension == "gz", limit: 32 * 1024 * 1024)
        guard indexData.count == size else { throw StarDictError.invalid("索引大小与 .ifo 不一致") }
        let data = try Self.read(dict, compressed: dict.pathExtension == "dz", limit: 128 * 1024 * 1024)

        var index: [IndexEntry] = []
        var position = 0
        let offsetBytes = offsetBits == "64" ? 8 : 4
        while position < indexData.count {
            guard let delimiter = indexData[position...].firstIndex(of: 0), delimiter > position,
                  let word = String(data: indexData[position..<delimiter], encoding: .utf8),
                  indexData.count - delimiter - 1 >= offsetBytes + 4
            else { throw StarDictError.invalid("词头或索引记录损坏") }
            position = delimiter + 1
            let offset = Self.number(indexData, from: &position, bytes: offsetBytes)
            let length = Self.number(indexData, from: &position, bytes: 4)
            guard offset <= UInt64(data.count), length <= UInt64(data.count) - offset else {
                throw StarDictError.invalid("释义偏移超出正文")
            }
            index.append(IndexEntry(word: word, folded: word.lowercased(),
                                    bytes: Int(offset)..<Int(offset + length)))
        }
        guard index.count == words else { throw StarDictError.invalid("词条数与 .ifo 不一致") }
        self.name = name
        self.files = [ifo, idx, dict]
        self.types = Array(sequence)
        self.data = data
        self.index = index.sorted { $0.folded != $1.folded ? $0.folded < $1.folded : $0.word < $1.word }
    }

    func lookup(_ word: String) throws -> Entry? {
        let query = word.lowercased()
        var low = 0
        var high = index.count
        while low < high {
            let middle = (low + high) / 2
            if index[middle].folded < query { low = middle + 1 } else { high = middle }
        }
        guard low < index.count, index[low].folded == query else { return nil }

        let first = index[low]
        var translations: [String] = []
        var phonetic = ""
        for hit in index[low...].prefix(while: { $0.folded == query }) {
            var start = hit.bytes.lowerBound
            for (index, type) in types.enumerated() {
                let end: Int
                if index == types.count - 1 {
                    end = hit.bytes.upperBound
                } else if let delimiter = data[start..<hit.bytes.upperBound].firstIndex(of: 0) {
                    end = delimiter
                } else {
                    throw StarDictError.invalid("释义字段缺少分隔符")
                }
                let raw = data[start..<end]
                guard let text = String(data: raw.last == 0 ? raw.dropLast() : raw, encoding: .utf8) else {
                    throw StarDictError.invalid("释义不是 UTF-8")
                }
                start = end + 1
                if type == "t" {
                    if phonetic.isEmpty { phonetic = text }
                } else {
                    let value = type == "m" ? text : Self.stripMarkup(text)
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !translations.contains(trimmed) { translations.append(trimmed) }
                }
            }
        }
        guard !translations.isEmpty else { return nil }
        return Entry(word: first.word, phonetic: phonetic, translation: translations.joined(separator: "\n"),
                     dictionary: name)
    }

    private static func stripMarkup(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#,
                                              with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)<br\b[^>]*>|</(?:p|div|li)\s*>"#,
                                             with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&gt;", ">"), ("&lt;", "<"),
                                      ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private static func metadata(_ url: URL) throws -> [String: String] {
        let data = try read(url, compressed: false, limit: 1024 * 1024)
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.first == "StarDict's dict ifo file" else { throw StarDictError.invalid(".ifo 文件头无效") }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                result[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    private static func resource(_ base: URL, extensions: [String]) throws -> URL {
        for suffix in extensions {
            let url = base.appendingPathExtension(suffix)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw StarDictError.invalid("缺少 \(extensions.joined(separator: " / ")) 文件")
    }

    private static func number(_ data: Data, from position: inout Int, bytes: Int) -> UInt64 {
        let result = data[position..<position + bytes].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        position += bytes
        return result
    }

    private static func read(_ url: URL, compressed: Bool, limit: Int) throws -> Data {
        if !compressed {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else {
                throw StarDictError.invalid("\(url.lastPathComponent) 无法读取或超出大小限制")
            }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw StarDictError.invalid("压缩文件必须为普通文件")
        }
        guard let handle = gzopen(url.path, "rb") else { throw StarDictError.invalid("无法打开压缩文件") }
        defer { gzclose(handle) }
        guard gzdirect(handle) == 0 else { throw StarDictError.invalid("压缩文件头无效") }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var result = Data()
        while true {
            let length = bytes.withUnsafeMutableBytes { gzread(handle, $0.baseAddress, UInt32($0.count)) }
            guard length >= 0 else { throw StarDictError.invalid("压缩文件已损坏") }
            if length == 0 {
                var code: Int32 = Z_OK
                gzerror(handle, &code)
                guard code == Z_OK || code == Z_STREAM_END else { throw StarDictError.invalid("压缩文件不完整") }
                return result
            }
            guard result.count + Int(length) <= limit else { throw StarDictError.invalid("解压后超出大小限制") }
            result.append(contentsOf: bytes.prefix(Int(length)))
        }
    }
}

actor StarDictLibrary {
    static let shared = StarDictLibrary()

    private let directory: URL
    private var loaded: [String: StarDictStore] = [:]

    init(directory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Englishwords/Dictionaries", isDirectory: true)) {
        self.directory = directory
    }

    func importDictionary(from selection: URL) throws -> DictionarySource {
        let ifo = try infoFile(selection)
        let store = try StarDictStore(ifo: ifo)
        let id = UUID().uuidString
        let destination = directory.appendingPathComponent(id, isDirectory: true)
        let staging = directory.appendingPathComponent(".\(id)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for source in store.files {
            try fm.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
        }
        // Re-open the copied files before publishing the import.
        let copied = try StarDictStore(ifo: staging.appendingPathComponent(ifo.lastPathComponent))
        try fm.moveItem(at: staging, to: destination)
        loaded[id] = copied
        return DictionarySource(id: id, kind: .stardict, name: store.name, enabled: true)
    }

    func lookup(_ word: String, source: DictionarySource) throws -> Entry? {
        if let cached = loaded[source.id] { return try cached.lookup(word) }
        let url = try sourceDirectory(source)
        let store = try StarDictStore(ifo: infoFile(url))
        loaded[source.id] = store
        return try store.lookup(word)
    }

    func remove(_ source: DictionarySource) throws {
        let url = try sourceDirectory(source)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        loaded.removeValue(forKey: source.id)
    }

    private func sourceDirectory(_ source: DictionarySource) throws -> URL {
        guard source.kind == .stardict, UUID(uuidString: source.id) != nil else {
            throw StarDictError.invalid("导入词典编号无效")
        }
        return directory.appendingPathComponent(source.id, isDirectory: true)
    }

    private func infoFile(_ selection: URL) throws -> URL {
        let attributes = try selection.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if attributes.isRegularFile == true, selection.pathExtension.lowercased() == "ifo" { return selection }
        if attributes.isDirectory == true {
            let files = try FileManager.default.contentsOfDirectory(at: selection, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])
            let matches = files.filter { $0.pathExtension.lowercased() == "ifo" }
            if matches.count == 1, let only = matches.first { return only }
        }
        throw StarDictError.invalid("请选择 .ifo 文件或仅包含一套字典的目录")
    }
}
