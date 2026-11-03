import Testing
@testable import Englishwords

// M8 之前不锁任何能力。这组测试用来防止"提前开启收费"的误改：
// 到 M8 真正接入许可证时，应连同 0002 设计方案一起改写本文件，
// 而不是直接删掉。

@Suite("商业能力开关（M8 预留）")
struct EntitlementsTests {

    @Test("M8 之前三项能力全部放行")
    func allFeaturesAllowedBeforeM8() {
        for feature in ProFeature.allCases {
            #expect(Entitlements.allows(feature), "\(feature.rawValue) 不应在 M8 之前被锁")
        }
    }

    @Test("M8 之前不启用收费判定")
    func enforcementDisabledBeforeM8() {
        #expect(Entitlements.isEnforced == false)
    }

    @Test("Pro 范围只有三项")
    func proScopeIsThreeFeatures() {
        #expect(ProFeature.allCases.count == 3)
        #expect(Set(ProFeature.allCases) == [.subtitles, .wordParts, .aiTranslation])
    }
}
