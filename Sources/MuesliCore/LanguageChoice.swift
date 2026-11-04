import Foundation

/// One entry in the language picker: a language, not a regional variant.
///
/// The speech engine lists each variant separately (en-AU, en-CA, en-GB…), which is too long a
/// list to choose from. Variants are grouped by language and script, so Simplified and Traditional
/// Chinese stay separate. Each group has a default variant, and the rest are one menu further away.
public struct LanguageChoice: Hashable, Sendable {
    /// BCP-47 tag of the variant to transcribe with, e.g. "de-AT".
    public let tag: String
    /// What to show, e.g. "German".
    public let name: String
    /// Every variant of this language, including the one in `tag`.
    public let variants: [Variant]

    public struct Variant: Hashable, Sendable {
        /// BCP-47 tag, e.g. "de-AT".
        public let tag: String
        /// What to show, e.g. "Austria".
        public let name: String
    }

    /// Each group's variant is the first that exists of: the `selected` one (so an earlier choice
    /// of a specific variant survives), the one for `region`, the language's main one.
    public static func choices(
        from locales: [Locale],
        selected: String? = nil,
        region: Locale.Region? = Locale.current.region,
        displayLocale: Locale = .current
    ) -> [LanguageChoice] {
        let groups = Dictionary(grouping: locales, by: Group.init)
        let scriptsPerLanguage = Dictionary(grouping: groups.keys, by: \.language).mapValues(\.count)

        return groups.map { group, variants in
            let tags = variants.map { $0.identifier(.bcp47) }
            let inRegion = variants.first { $0.region == region }?.identifier(.bcp47)
            let tag = selected.flatMap { tags.contains($0) ? $0 : nil }
                ?? inRegion
                ?? group.mainVariant(among: variants)
                ?? tags.min()!
            let nameID = scriptsPerLanguage[group.language] == 1 ? group.language : group.identifier
            return LanguageChoice(
                tag: tag,
                name: displayLocale.localizedString(forIdentifier: nameID) ?? tag,
                variants: variants.map { variant in
                    let variantTag = variant.identifier(.bcp47)
                    let regionName = variant.region.flatMap { displayLocale.localizedString(forRegionCode: $0.identifier) }
                    return Variant(tag: variantTag, name: regionName ?? variantTag)
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct Group: Hashable {
        let language: String
        let script: String

        init(_ locale: Locale) {
            // "zh-TW" only reveals its script in the maximal form, "zh-Hant-TW".
            let maximal = Locale.Language(identifier: locale.language.maximalIdentifier)
            language = maximal.languageCode?.identifier ?? locale.identifier
            script = maximal.script?.identifier ?? ""
        }

        var identifier: String { "\(language)-\(script)" }

        /// The variant Unicode's likely-subtags data gives for the bare language: de → de-DE, zh-Hant → zh-TW.
        func mainVariant(among variants: [Locale]) -> String? {
            let region = Locale.Language(identifier: Locale.Language(identifier: identifier).maximalIdentifier).region
            return variants.first { $0.region == region }?.identifier(.bcp47)
        }
    }
}
