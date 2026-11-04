import Foundation
import Testing
@testable import MuesliCore

@Suite struct LanguageChoiceTests {
    /// What `muesli languages` reports on macOS 26.
    private let locales = [
        "de-AT", "de-CH", "de-DE",
        "en-AU", "en-CA", "en-GB", "en-IE", "en-IN", "en-NZ", "en-SG", "en-US", "en-ZA",
        "es-CL", "es-ES", "es-MX", "es-US",
        "fr-BE", "fr-CA", "fr-CH", "fr-FR",
        "it-CH", "it-IT",
        "pt-BR", "pt-PT",
        "zh-CN", "zh-HK", "zh-TW",
    ].map(Locale.init(identifier:))

    private func choices(selected: String? = nil, region: String? = nil) -> [LanguageChoice] {
        LanguageChoice.choices(
            from: locales,
            selected: selected,
            region: region.map { Locale.Region($0) },
            displayLocale: Locale(identifier: "en-US")
        )
    }

    private func tag(_ name: String, in choices: [LanguageChoice]) -> String? {
        choices.first { $0.name == name }?.tag
    }

    @Test func oneEntryPerLanguageWithChineseSplitByScript() {
        #expect(choices().map(\.name) == [
            "Chinese, Simplified", "Chinese, Traditional", "English", "French",
            "German", "Italian", "Portuguese", "Spanish",
        ])
    }

    @Test func usesEachLanguagesMainVariantByDefault() {
        #expect(choices().map(\.tag) == ["zh-CN", "zh-TW", "en-US", "fr-FR", "de-DE", "it-IT", "pt-BR", "es-ES"])
    }

    @Test func prefersTheVariantForTheUsersRegion() {
        let austria = choices(region: "AT")
        #expect(tag("German", in: austria) == "de-AT")
        #expect(tag("English", in: austria) == "en-US")  // no en-AT: the main variant

        #expect(tag("English", in: choices(region: "GB")) == "en-GB")
        #expect(tag("Chinese, Traditional", in: choices(region: "HK")) == "zh-HK")
    }

    @Test func keepsAnAlreadySelectedVariant() {
        let picked = choices(selected: "en-IE", region: "GB")
        #expect(tag("English", in: picked) == "en-IE")
        #expect(tag("German", in: picked) == "de-DE")
    }

    @Test func listsEveryVariantByRegionName() {
        let german = choices().first { $0.name == "German" }
        #expect(german?.variants.map(\.name) == ["Austria", "Germany", "Switzerland"])
        #expect(german?.variants.map(\.tag) == ["de-AT", "de-DE", "de-CH"])

        let simplified = choices().first { $0.name == "Chinese, Simplified" }
        #expect(simplified?.variants.map(\.tag) == ["zh-CN"])
    }

    @Test func noLocalesNoChoices() {
        #expect(LanguageChoice.choices(from: []).isEmpty)
    }
}
