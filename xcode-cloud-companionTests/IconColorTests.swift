import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private typealias RGBA = (UInt8, UInt8, UInt8, UInt8)

private let cumulusBlue: RGBA = (81, 115, 247, 255)
private let white: RGBA = (255, 255, 255, 255)
private let black: RGBA = (0, 0, 0, 255)
private let red: RGBA = (230, 40, 40, 255)
private let orange: RGBA = (255, 149, 0, 255)
private let green: RGBA = (52, 199, 89, 255)
private let magenta: RGBA = (175, 82, 222, 255)

/// 100 pixels shared between colours, by how many each takes.
private func pixels(_ shares: [(RGBA, Int)]) -> [UInt8] {
    shares.flatMap { color, count in
        (0..<count).flatMap { _ in [color.0, color.1, color.2, color.3] }
    }
}

private func swatch(_ color: RGBA) -> SwatchColor {
    SwatchColor(red: Double(color.0) / 255, green: Double(color.1) / 255, blue: Double(color.2) / 255)
}

/// How far apart two hues are, in radians.
private func hueGap(_ first: SwatchColor, _ second: SwatchColor) -> Double {
    let gap = abs(OKLab(first).hue - OKLab(second).hue)
    return min(gap, 2 * .pi - gap)
}

/// A square PNG: `background` everywhere, and `mark` in a centred square covering `markShare` of the side.
private func png(background: RGBA, mark: RGBA? = nil, markShare: Double = 0.5, side: Int = 64) -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return Data() }
    func fill(_ color: RGBA, _ rect: CGRect) {
        context.setFillColor(CGColor(
            srgbRed: Double(color.0) / 255, green: Double(color.1) / 255, blue: Double(color.2) / 255, alpha: Double(color.3) / 255
        ))
        context.fill(rect)
    }
    let full = CGRect(x: 0, y: 0, width: side, height: side)
    fill(background, full)
    if let mark {
        let inset = Double(side) * (1 - markShare) / 2
        fill(mark, full.insetBy(dx: inset, dy: inset))
    }
    let data = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

struct IconColorExtractorTests {
    @Test func theColourThatCoversTheIconIsItsColour() throws {
        let color = try #require(IconColorExtractor.dominantColor(rgba: pixels([(cumulusBlue, 70), (white, 30)])))

        #expect(hueGap(color, swatch(cumulusBlue)) < 0.05)
        #expect(abs(color.blue - swatch(cumulusBlue).blue) < 0.02)
    }

    @Test func whiteGreyAndBlackSayNothingOfTheColour() throws {
        let color = try #require(IconColorExtractor.dominantColor(rgba: pixels([(white, 65), (black, 20), ((128, 128, 128, 255), 5), (red, 10)])))

        #expect(hueGap(color, swatch(red)) < 0.05)
    }

    @Test func anIconWithoutColourHasNone() {
        #expect(IconColorExtractor.dominantColor(rgba: pixels([(white, 50), (black, 30), ((90, 90, 92, 255), 20)])) == nil)
        #expect(IconColorExtractor.dominantColor(rgba: pixels([(white, 98), (red, 2)])) == nil)
        #expect(IconColorExtractor.dominantColor(rgba: []) == nil)
    }

    @Test func transparentPixelsAreNotPartOfTheIcon() throws {
        let color = try #require(IconColorExtractor.dominantColor(rgba: pixels([((52, 199, 89, 0), 80), (orange, 20)])))

        #expect(hueGap(color, swatch(orange)) < 0.05)
        #expect(IconColorExtractor.dominantColor(rgba: pixels([((52, 199, 89, 0), 100)])) == nil)
    }

    @Test func ofTwoHuesTheOneThatTakesMoreRoomWins() throws {
        let mostlyGreen = try #require(IconColorExtractor.dominantColor(rgba: pixels([(green, 70), (magenta, 30)])))
        let mostlyMagenta = try #require(IconColorExtractor.dominantColor(rgba: pixels([(green, 30), (magenta, 70)])))

        #expect(hueGap(mostlyGreen, swatch(green)) < 0.05)
        #expect(hueGap(mostlyMagenta, swatch(magenta)) < 0.05)
    }

    @Test func anIconFileGivesTheColourOfItsBackgroundNotOfItsWhiteGlyph() async throws {
        let color = try #require(await IconColorReader.color(ofImage: png(background: cumulusBlue, mark: white)))

        #expect(hueGap(color, swatch(cumulusBlue)) < 0.05)
        #expect(await IconColorReader.color(ofImage: png(background: white, mark: black)) == nil)
        #expect(await IconColorReader.color(ofImage: Data("not an image".utf8)) == nil)
    }

    @Test func aMacIconIsReadWithoutItsTransparentMargins() async throws {
        let color = try #require(await IconColorReader.color(ofImage: png(background: (0, 0, 0, 0), mark: orange, markShare: 0.8)))

        #expect(hueGap(color, swatch(orange)) < 0.05)
    }
}

struct LegibleColorTests {
    @Test func aDarkColourIsLightenedWithoutChangingHue() {
        let navy = SwatchColor(red: 0.08, green: 0.12, blue: 0.35)
        let legible = navy.legible

        #expect(OKLab(navy).lightness < 0.3)
        #expect(OKLab(legible).lightness >= SwatchColor.lightnessRange.lowerBound - 0.01)
        #expect(hueGap(legible, navy) < 0.05)
    }

    @Test func aPaleColourIsDarkenedAndKeepsAColourToShow() {
        let pastel = SwatchColor(red: 0.90, green: 0.93, blue: 1)
        let legible = pastel.legible

        #expect(OKLab(legible).lightness <= SwatchColor.lightnessRange.upperBound + 0.01)
        #expect(OKLab(legible).chroma > OKLab(pastel).chroma)
        #expect(hueGap(legible, pastel) < 0.05)
    }

    @Test func aColourThatAlreadyReadsStaysAsItIs() {
        let blue = swatch(cumulusBlue)
        let legible = blue.legible

        #expect(abs(legible.red - blue.red) < 0.005 && abs(legible.green - blue.green) < 0.005 && abs(legible.blue - blue.blue) < 0.005)
    }

    @Test func everyColourStaysWithinWhatAScreenShows() {
        for color in [SwatchColor(red: 1, green: 1, blue: 0), SwatchColor(red: 0, green: 0, blue: 1), SwatchColor(red: 0, green: 1, blue: 0), SwatchColor(red: 0.01, green: 0, blue: 0.02)] {
            let legible = color.legible
            #expect((0...1).contains(legible.red) && (0...1).contains(legible.green) && (0...1).contains(legible.blue))
            #expect(SwatchColor.lightnessRange.contains(OKLab(legible).lightness.rounded(toPlaces: 2)))
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}

struct IconPaletteTests {
    private let blue = swatch(cumulusBlue)

    @Test func anAppTakesTheColourOfItsIconAndAnotherKeepsItsSwatch() {
        var palette = AppPalette()
        palette.update(ranking: ["withIcon", "greyIcon", "noIcon"])
        palette.setIconReading(AppPalette.IconReading(icon: "abc", color: blue), for: "withIcon")
        palette.setIconReading(AppPalette.IconReading(icon: "def", color: nil), for: "greyIcon")

        #expect(palette.swatch(for: "withIcon") == .icon(blue.legible))
        #expect(palette.swatch(for: "greyIcon") == .cyan)
        #expect(palette.swatch(for: "noIcon") == .yellow)
    }

    @Test func anIconIsReadOnceAndAgainWhenItChanges() {
        var palette = AppPalette()
        palette.update(ranking: ["app"])
        #expect(palette.needsReading(ofIcon: "abc", for: "app"))

        palette.setIconReading(AppPalette.IconReading(icon: "abc", color: nil), for: "app")

        #expect(!palette.needsReading(ofIcon: "abc", for: "app"))
        #expect(palette.needsReading(ofIcon: "changed", for: "app"))
    }

    @Test func anAppThatIsGoneLeavesNoColourBehind() {
        var palette = AppPalette()
        palette.update(ranking: ["app", "other"])
        palette.setIconReading(AppPalette.IconReading(icon: "abc", color: blue), for: "app")

        let changedWhileTheAppExists = palette.update(ranking: ["app", "other"])
        let changedOnceItIsGone = palette.update(ranking: ["other"])

        #expect(!changedWhileTheAppExists && changedOnceItIsGone)
        #expect(palette.needsReading(ofIcon: "abc", for: "app"))
    }

    @Test func aPaletteSavedBeforeIconsGaveColoursIsReadAsItWas() throws {
        let saved = Data(#"{"swatchIndexByApp":{"big":0,"small":2}}"#.utf8)
        let palette = try JSONDecoder().decode(AppPalette.self, from: saved)

        #expect(palette.swatch(for: "big") == .blue)
        #expect(palette.swatch(for: "small") == .yellow)
        #expect(palette.needsReading(ofIcon: "abc", for: "big"))
    }

    @Test func coloursSurviveARelaunch() throws {
        let suite = "IconPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var palette = AppPalette()
        palette.update(ranking: ["app"])
        palette.setIconReading(AppPalette.IconReading(icon: "abc", color: blue), for: "app")

        AppPaletteStore().save(palette, to: defaults)

        #expect(AppPaletteStore().load(from: defaults) == palette)
    }
}

private final class Downloads: Sendable {
    let count = Mutex(0)
}

@MainActor
struct IconColorReadingTests {
    private let accounts = TestAccounts()
    private let now = Date(timeIntervalSince1970: 1_791_892_800)
    private let app = CIProduct(id: "p1", name: "realmotivation", productType: "APP", appID: "app-1", appName: "Élan", bundleID: nil)
    private let framework = CIProduct(id: "p2", name: "Toolkit", productType: "FRAMEWORK", appID: nil, appName: nil, bundleID: nil)
    private let icon = CIAppIcon(templateURL: "https://is1-ssl.mzstatic.com/image/thumb/a/logo.png/{w}x{h}bb.{f}")

    private var snapshot: BuildSnapshot {
        BuildSnapshot(products: [app, framework], appIcons: ["app-1": icon])
    }

    private func session(_ downloads: Downloads, image: Data?) -> AccountSession {
        let paths = accounts.paths("work")
        let store = InMemoryCredentialsStore()
        return AccountSession(
            account: Account(id: "work", name: "Work"), paths: paths,
            settings: SettingsModel(accountID: "work", store: store, defaults: accounts.defaults),
            buildStore: BuildStore(credentialsStore: store, cacheStore: BuildCacheStore(fileURL: paths.buildCache)),
            usageStore: UsageStore(ledgerStore: UsageLedgerStore(fileURL: paths.usageLedger), watchedDirectory: nil),
            extrasStore: BuildExtrasStore(client: { nil }),
            iconCache: AppIconCache(directory: paths.appIcons) { _ in
                downloads.count.withLock { $0 += 1 }
                return image
            },
            defaults: accounts.defaults
        )
    }

    @Test func anAppGetsTheColourOfItsIconAndTheIconIsReadOnce() async throws {
        let downloads = Downloads()
        let session = session(downloads, image: png(background: cumulusBlue, mark: white))

        await session.readIconColors(in: snapshot, now: now)
        await session.readIconColors(in: snapshot, now: now.addingTimeInterval(7200))

        let palette = session.palette(for: snapshot, summary: nil)
        guard case .icon(let color) = palette.swatch(for: "realmotivation") else {
            Issue.record("The app kept a system swatch")
            return
        }
        #expect(hueGap(color, swatch(cumulusBlue)) < 0.05)
        #expect(palette.swatch(for: "Toolkit") != palette.swatch(for: "realmotivation"))
        #expect(AppSwatch.system.contains(palette.swatch(for: "Toolkit")))
        #expect(session.iconColorReadings == 1)
        #expect(downloads.count.withLock { $0 } == 1)
    }

    @Test func anIconWithoutColourLeavesTheAppItsSwatchAndIsNotReadAgain() async {
        let downloads = Downloads()
        let session = session(downloads, image: png(background: white, mark: black))

        await session.readIconColors(in: snapshot, now: now)
        await session.readIconColors(in: snapshot, now: now.addingTimeInterval(7200))

        #expect(AppSwatch.system.contains(session.palette(for: snapshot, summary: nil).swatch(for: "realmotivation")))
        #expect(session.iconColorReadings == 1)
    }

    @Test func anIconThatCannotBeFetchedIsTriedAgainAnHourLaterAtTheEarliest() async {
        let downloads = Downloads()
        let session = session(downloads, image: nil)

        await session.readIconColors(in: snapshot, now: now)
        await session.readIconColors(in: snapshot, now: now.addingTimeInterval(60))
        #expect(downloads.count.withLock { $0 } == 1)

        await session.readIconColors(in: snapshot, now: now.addingTimeInterval(3600))
        #expect(downloads.count.withLock { $0 } == 2)
        #expect(session.iconColorReadings == 0)
    }

    @Test func aSessionWithoutIconCacheReadsNothing() async {
        let paths = accounts.paths("bare")
        let store = InMemoryCredentialsStore()
        let session = AccountSession(
            account: Account(id: "bare", name: "Bare"), paths: paths,
            settings: SettingsModel(accountID: "bare", store: store, defaults: accounts.defaults),
            buildStore: BuildStore(credentialsStore: store, cacheStore: BuildCacheStore(fileURL: paths.buildCache)),
            usageStore: UsageStore(ledgerStore: UsageLedgerStore(fileURL: paths.usageLedger), watchedDirectory: nil),
            extrasStore: BuildExtrasStore(client: { nil }), defaults: accounts.defaults
        )

        await session.readIconColors(in: snapshot, now: now)

        #expect(session.iconColorReadings == 0)
    }
}

struct ChosenColorTests {
    private let blue = swatch(cumulusBlue)
    private let teal = SwatchColor(red: 0, green: 0.65, blue: 0.63)

    private var palette: AppPalette {
        var palette = AppPalette()
        palette.update(ranking: ["withIcon", "noIcon"])
        palette.setIconReading(AppPalette.IconReading(icon: "abc", color: blue), for: "withIcon")
        return palette
    }

    @Test func aChosenColourGoesBeforeTheIconsAndNilGivesTheIconBack() {
        var palette = palette

        palette.choose(.system(4), for: "withIcon")
        #expect(palette.swatch(for: "withIcon") == .orange)
        #expect(palette.defaultSwatch(for: "withIcon") == .icon(blue.legible))

        palette.choose(.custom(teal), for: "withIcon")
        #expect(palette.swatch(for: "withIcon") == .icon(teal.legible))

        palette.choose(nil, for: "withIcon")
        #expect(palette.swatch(for: "withIcon") == .icon(blue.legible))
        #expect(palette.choice(for: "withIcon") == nil)
    }

    @Test func anAppWithoutIconTakesAColourToo() {
        var palette = palette
        #expect(!palette.hasIconColor("noIcon") && palette.hasIconColor("withIcon"))

        palette.choose(.custom(teal), for: "noIcon")
        #expect(palette.swatch(for: "noIcon") == .icon(teal.legible))

        palette.choose(nil, for: "noIcon")
        #expect(palette.swatch(for: "noIcon") == .cyan)
    }

    @Test func aChangeOfIconLeavesAChosenColourAlone() {
        var palette = palette
        palette.choose(.system(5), for: "withIcon")

        palette.setIconReading(AppPalette.IconReading(icon: "changed", color: SwatchColor(red: 0.9, green: 0.2, blue: 0.2)), for: "withIcon")

        #expect(palette.swatch(for: "withIcon") == .mint)
    }

    @Test func aChoiceSurvivesARelaunchAndGoesWithItsApp() throws {
        let suite = "ChosenColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var palette = palette
        palette.choose(.custom(teal), for: "withIcon")
        palette.choose(.system(0), for: "noIcon")

        AppPaletteStore().save(palette, to: defaults)
        var loaded = AppPaletteStore().load(from: defaults)

        #expect(loaded == palette)
        let changed = loaded.update(ranking: ["withIcon"])
        #expect(changed)
        #expect(loaded.choice(for: "noIcon") == nil && loaded.choice(for: "withIcon") == .custom(teal))
    }

    @Test func aStoredHueThatDoesNotExistFallsBackToTheDefault() {
        var palette = palette
        palette.choose(.system(42), for: "withIcon")

        #expect(palette.swatch(for: "withIcon") == .icon(blue.legible))
    }

    @Test func aPaletteSavedBeforeColoursCouldBeChosenIsReadAsItWas() throws {
        let saved = Data(#"{"swatchIndexByApp":{"big":0},"iconReadingByApp":{"big":{"icon":"abc"}}}"#.utf8)
        let palette = try JSONDecoder().decode(AppPalette.self, from: saved)

        #expect(palette.choice(for: "big") == nil && palette.swatch(for: "big") == .blue)
    }

    @Test func everyChoosableHueHasANameAndTheMenuNamesTheColourInUse() {
        #expect(AppSwatch.choosable == [.blue, .cyan, .yellow, .purple, .orange, .mint])
        #expect(Set(AppSwatch.choosable.map(\.colorName)).count == 6)
        #expect(AppColorText.name(of: nil, hasIconColor: true) == "Icon Color")
        #expect(AppColorText.name(of: nil, hasIconColor: false) == "Default Color")
        #expect(AppColorText.name(of: .system(3), hasIconColor: true) == "Purple")
        #expect(AppColorText.name(of: .custom(teal), hasIconColor: true) == "Custom Color")
    }
}

@MainActor
struct ColorChoiceSessionTests {
    private let accounts = TestAccounts()
    private let app = CIProduct(id: "p1", name: "realmotivation", productType: "APP", appID: "app-1", appName: "Élan", bundleID: nil)

    @Test func choosingAColourShowsAtOnceAndIsKeptForTheAccount() async throws {
        let session = try await accounts.add("Work")
        let snapshot = BuildSnapshot(products: [app])
        let before = session.colorChoices

        session.chooseColor(.system(4), forApp: "realmotivation")
        session.chooseColor(.system(4), forApp: "realmotivation")

        #expect(session.colorChoices == before + 1)
        #expect(session.palette(for: snapshot, summary: nil).swatch(for: "realmotivation") == .orange)
        let sidebar = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: session.palette(for: snapshot, summary: nil))
        let product = try #require(sidebar.products.first)
        #expect(product.paletteKey == "realmotivation" && product.colorChoice == .system(4) && product.swatch == .orange)
        #expect(product.defaultSwatch == .blue && !product.hasIconColor)

        session.chooseColor(nil, forApp: "realmotivation")
        #expect(session.palette(for: snapshot, summary: nil).swatch(for: "realmotivation") == .blue)
    }
}
