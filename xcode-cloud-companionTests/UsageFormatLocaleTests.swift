import Foundation
import Testing
@testable import XcodeCloudCompanion

/// The same figures in English and in French: units, spaces and word order come from the locale, never from the code.
struct UsageFormatLocaleTests {
    private let english = Locale(identifier: "en_US")
    private let french = Locale(identifier: "fr_FR")
    /// Noon UTC: the same calendar day in every time zone the tests may run in.
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    @Test func minutes() {
        #expect(UsageFormat.minutes(42, locale: english) == "42 min")
        #expect(UsageFormat.minutes(499, locale: english) == "8 hr, 19 min")
        #expect(UsageFormat.minutes(42, locale: french) == "42\u{a0}min")
        #expect(UsageFormat.minutes(499, locale: french) == "8\u{202f}h et 19\u{a0}min")
    }

    @Test func compactMinutes() {
        #expect(UsageFormat.compactMinutes(499, locale: english) == "8h 19m")
        #expect(UsageFormat.compactMinutes(499, locale: french) == "8h 19min")
    }

    @Test func age() {
        #expect(UsageFormat.age(since: now.addingTimeInterval(-7_199), now: now, locale: english) == "1h")
        #expect(UsageFormat.age(since: now.addingTimeInterval(-3 * 86_400), now: now, locale: english) == "3d")
        #expect(UsageFormat.age(since: now.addingTimeInterval(-3 * 86_400), now: now, locale: french) == "3j")
    }

    @Test func percent() {
        #expect(UsageFormat.percent(0.42, locale: english) == "42%")
        #expect(UsageFormat.percent(0.42, locale: french) == "42\u{a0}%")
    }

    @Test func dayAndMoment() {
        #expect(UsageFormat.day(now, locale: english) == "Oct 9")
        #expect(UsageFormat.day(now, locale: french) == "9 oct.")
        #expect(UsageFormat.moment(now, locale: english).hasPrefix("Oct 9 at "))
        #expect(UsageFormat.moment(now, locale: french).hasPrefix("9 oct. à "))
    }

    @Test func timeLeft() {
        #expect(UsageFormat.timeLeft(3 * 86_400 + 5 * 3_600, locale: english) == "3 days, 5 hr")
        #expect(UsageFormat.timeLeft(3 * 86_400 + 5 * 3_600, locale: french) == "3\u{202f}j et 5\u{202f}h")
        #expect(UsageFormat.timeLeft(2 * 3_600 + 15 * 60, locale: french) == "2\u{202f}h et 15\u{a0}min")
    }

    @Test func relative() {
        #expect(UsageFormat.relative(now.addingTimeInterval(-3_600), now: now, locale: english) == "1 hour ago")
        #expect(UsageFormat.relative(now.addingTimeInterval(-3_600), now: now, locale: french) == "il y a 1 heure")
    }

    @Test func partsAreJoinedByTheCatalogSeparator() {
        #expect(UsageFormat.dotted(["Failed", "6 min", "develop"], locale: english) == "Failed · 6 min · develop")
        #expect(UsageFormat.dotted([], locale: english) == "")
    }

    @Test func aCountIsOneCatalogEntryWithItsPluralForms() {
        #expect(String(localized: "\(1) Xcode Cloud apps found") == "1 Xcode Cloud app found")
        #expect(String(localized: "\(3) Xcode Cloud apps found") == "3 Xcode Cloud apps found")
        #expect(String(localized: "\(1) builds") == "1 build")
    }
}
