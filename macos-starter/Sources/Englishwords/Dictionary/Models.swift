import Foundation

/// 词根词缀的一段。
///
/// `label` 是**该词里的实际拼写**（如 `believ`），不是语素的词典形态（`believe`）。
/// 两者常常不同，渲染与拼回都必须用前者。
struct Segment: Hashable {
    let role: String      // prefix / root / suffix
    let label: String     // un / believ / able
    var partID: Int32? = nil
    let gloss: String     // 不 / 相信 / 能……的
}

/// 一条词典释义。
struct Entry {
    let word: String
    var phonetic: String = ""
    var pos: String = ""
    var translation: String = ""
    var tags: [String] = []
    var dictionary: String = ""
}

/// 词素补充信息：与释义来源无关，命中其一也可以展示。
struct Morphology {
    var segments: [Segment] = []
    var origin: String = ""
}

enum DictionaryError: LocalizedError, Equatable {
    case unavailable(String)
    case schema(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "词库不可用：\(detail)"
        case .schema(let detail):      return "词库结构不符合约定：\(detail)"
        case .query(let detail):       return "词库查询失败：\(detail)"
        }
    }
}
