import Foundation
import Testing
@testable import XcodeCloudCompanion

/// Reads the catalog as the build compiles it into the app: every English key needs its French twin.
struct FrenchLocalizationTests {
    private func keys(in language: String) throws -> Set<String> {
        let folder = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        var keys = Set<String>()
        for file in ["Localizable.strings", "Localizable.stringsdict"] {
            let url = URL(filePath: folder).appending(path: file)
            guard let data = try? Data(contentsOf: url) else { continue }
            let table = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            keys.formUnion(table.keys)
        }
        return keys
    }

    private var french: Bundle? {
        Bundle.main.path(forResource: "fr", ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test func everyStringHasAFrenchTranslation() throws {
        let english = try keys(in: "en")
        let french = try keys(in: "fr")

        #expect(!english.isEmpty)
        #expect(english.subtracting(french).sorted() == [])
    }

    @Test func zeroIsSingularInFrench() throws {
        let bundle = try #require(french)
        let format = bundle.localizedString(forKey: "%lld builds", value: nil, table: nil)

        let locale = Locale(identifier: "fr_FR")

        #expect(String(format: format, locale: locale, 0) == "0 build")
        #expect(String(format: format, locale: locale, 1) == "1 build")
        #expect(String(format: format, locale: locale, 2) == "2 builds")
    }

    @Test func frenchTypographyUsesNonBreakingSpacesAndCurlyApostrophes() throws {
        let bundle = try #require(french)

        #expect(bundle.localizedString(forKey: "Remove the account “%@” and all its data?", value: nil, table: nil) == "Supprimer le compte «\u{202f}%@\u{202f}» et toutes ses données\u{202f}?")
        #expect(bundle.localizedString(forKey: "Shortcut: ⌘%lld", value: nil, table: nil) == "Raccourci\u{202f}: ⌘%lld")
        #expect(bundle.localizedString(forKey: "Settings…", value: nil, table: nil) == "Réglages…")
        #expect(bundle.localizedString(forKey: "Accounts", value: nil, table: nil) == "Comptes")
        #expect(bundle.localizedString(forKey: "Overview", value: nil, table: nil) == "Vue d\u{2019}ensemble")
        #expect(bundle.localizedString(forKey: "No Xcode Cloud app yet.", value: nil, table: nil).contains("\u{2019}"))
    }
}
