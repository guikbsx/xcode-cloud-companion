import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct MenuBarIconTests {
    @Test func withoutABadgeTheCloudIsATemplateTheMenuBarTints() throws {
        let image = try #require(MenuBarIcon.image(badge: nil, measuring: false))

        #expect(image.isTemplate)
    }

    @Test func aBadgeKeepsTheCloudInPlace() throws {
        let resting = try #require(MenuBarIcon.image(badge: nil, measuring: false))
        let badged = try #require(MenuBarIcon.image(badge: .failed, measuring: false))

        #expect(resting.size == badged.size)
        #expect(!badged.isTemplate)
    }

    @Test func everyStateHasItsImage() {
        for badge in [MenuBarBadge.running, .failed, .succeeded, .stopped] {
            #expect(MenuBarIcon.image(badge: badge, measuring: false) != nil)
            #expect(MenuBarIcon.image(badge: badge, measuring: true) != nil)
        }
        #expect(MenuBarIcon.image(badge: nil, measuring: true)?.isTemplate == true)
    }
}
