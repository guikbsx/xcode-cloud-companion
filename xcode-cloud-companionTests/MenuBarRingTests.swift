import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct MenuBarRingTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)
    private let english = Locale(identifier: "en_US")

    private func action(_ run: String, _ name: String, start: Double, seconds: Double?, completion: CICompletionStatus? = .succeeded) -> CIBuildAction {
        let started = now.addingTimeInterval(start)
        return CIBuildAction(
            id: "\(run)-\(name)", buildRunID: run, name: name, actionType: .build, startedDate: started,
            finishedDate: seconds.map { started.addingTimeInterval($0) }, executionProgress: seconds == nil ? .running : .complete,
            completionStatus: seconds == nil ? nil : completion, isRequiredToPass: nil
        )
    }

    private func run(_ id: String, workflow: String, startedAgo: Double?, progress: CIExecutionProgress = .running) -> CIBuildRun {
        CIBuildRun(
            id: id, productID: "p", number: 7, createdDate: now.addingTimeInterval(-(startedAgo ?? 30)),
            startedDate: startedAgo.map { now.addingTimeInterval(-$0) }, finishedDate: nil, executionProgress: progress, completionStatus: nil,
            startReason: nil, workflowID: workflow, workflowName: workflow, sourceBranchOrTag: "main"
        )
    }

    /// Three succeeded builds of the workflow (Build 120 s, Test 300 s), then `current` with the actions given.
    private func snapshot(workflow: String, current: CIBuildRun, actions: [CIBuildAction]) -> BuildSnapshot {
        var runs: [CIBuildRun] = []
        var byRun: [String: [CIBuildAction]] = [:]
        for index in 1...3 {
            let id = "\(workflow)-h\(index)"
            let begin = -86_400.0 * Double(index)
            runs.append(CIBuildRun(
                id: id, productID: "p", number: index, createdDate: now.addingTimeInterval(begin), startedDate: now.addingTimeInterval(begin),
                finishedDate: now.addingTimeInterval(begin + 420), executionProgress: .complete, completionStatus: .succeeded, startReason: nil,
                workflowID: workflow, workflowName: workflow, sourceBranchOrTag: "main"
            ))
            byRun[id] = [action(id, "Build", start: begin, seconds: 120), action(id, "Test", start: begin + 120, seconds: 300)]
        }
        byRun[current.id] = actions
        return BuildSnapshot(products: [CIProduct(id: "p", name: "Sextant", productType: "APP", appID: "1", appName: nil, bundleID: nil)], runs: runs + [current], actionsByRunID: byRun)
    }

    /// Ends in about 5 minutes when `testElapsed` is 120 s, the test usually taking 300 s.
    private func running(_ id: String, workflow: String, testElapsed: Double) -> BuildSnapshot {
        let current = run(id, workflow: workflow, startedAgo: 120 + testElapsed)
        return snapshot(workflow: workflow, current: current, actions: [
            action(id, "Build", start: -(120 + testElapsed), seconds: 120), action(id, "Test", start: -testElapsed, seconds: nil),
        ])
    }

    // MARK: Which build

    @Test func theRingIsTheOneOfTheBuildThatEndsFirstOnAnyAccount() throws {
        let late = running("late", workflow: "a", testElapsed: 60)
        let early = running("early", workflow: "b", testElapsed: 240)

        let ring = try #require(MenuBarRing.leader(in: [late, early], now: now, locale: english))
        let expected = BuildRing(run: try #require(early.runs.last), in: early, now: now, locale: english)

        #expect(ring == expected)
    }

    @Test func aQueuedBuildComesAfterOneThatRunsAndGetsTheQueuedRing() throws {
        let queued = run("q", workflow: "c", startedAgo: nil, progress: .pending)
        let alone = BuildSnapshot(runs: [queued])

        #expect(try #require(MenuBarRing.leader(in: [alone], now: now, locale: english)).state == .queued)
        let both = try #require(MenuBarRing.leader(in: [alone, running("r", workflow: "a", testElapsed: 60)], now: now, locale: english))
        #expect(both.state == .running)
    }

    @Test func noRunningBuildMeansNoRing() {
        #expect(MenuBarRing.leader(in: [], now: now, locale: english) == nil)
        #expect(MenuBarRing.leader(in: [BuildSnapshot.empty], now: now, locale: english) == nil)
    }

    // MARK: Drawing

    private struct Count {
        var blue = 0
        var red = 0
        var light = 0
        var dark = 0
        var opaque = 0
    }

    /// Counts the pixels of the image drawn in a menu bar of the given look.
    private func count(_ image: NSImage, dark: Bool) throws -> Count {
        let scale = 4
        let side = Int(image.size.width) * scale
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            (dark ? NSColor.black : NSColor.white).setFill()
            NSRect(x: 0, y: 0, width: side, height: side).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        }
        NSGraphicsContext.restoreGraphicsState()
        var result = Count()
        for y in 0..<side {
            for x in 0..<side {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                let background: CGFloat = dark ? 0 : 1
                if abs(r - background) > 0.15 || abs(g - background) > 0.15 || abs(b - background) > 0.15 { result.opaque += 1 }
                if b > r + 0.3, b > 0.7 { result.blue += 1 }
                if r > g + 0.3, r > 0.7 { result.red += 1 }
                if min(r, g, b) > 0.8 { result.light += 1 }
                if max(r, g, b) < 0.3 { result.dark += 1 }
            }
        }
        return result
    }

    @Test func theImageIsAnUntemplatedSquareWithRoomForTheGlow() {
        let image = MenuBarIcon.image(ring: BuildRing(run: run("r", workflow: "a", startedAgo: 100), in: .empty, now: now, locale: english))

        #expect(!image.isTemplate)
        #expect(image.size == NSSize(width: MenuBarRing.canvas, height: MenuBarRing.canvas))
        #expect(MenuBarRing.size == 16)
    }

    @Test func finishedActionsTakeTheLabelColourOfTheBarTheyAreDrawnIn() throws {
        let snapshot = running("r", workflow: "a", testElapsed: 100)
        let image = MenuBarIcon.image(ring: try #require(MenuBarRing.leader(in: [snapshot], now: now, locale: english)))

        let inLightBar = try count(image, dark: false)
        let inDarkBar = try count(image, dark: true)

        #expect(inLightBar.dark > inLightBar.opaque / 10)
        #expect(inDarkBar.light > inDarkBar.opaque / 10)
        #expect(inLightBar.blue > 0 && inDarkBar.blue > 0)
    }

    @Test func aFailedActionIsRedAndRunningOneIsBlue() throws {
        let current = run("f", workflow: "a", startedAgo: 260)
        let snapshot = snapshot(workflow: "a", current: current, actions: [
            action("f", "Build", start: -260, seconds: 120, completion: .failed), action("f", "Test", start: -140, seconds: nil),
        ])
        let image = MenuBarIcon.image(ring: try #require(MenuBarRing.leader(in: [snapshot], now: now, locale: english)))

        let drawn = try count(image, dark: false)

        #expect(drawn.red > 0)
        #expect(drawn.blue > 0)
    }

    @Test func aQueuedBuildIsDottedAndHasNoBlue() throws {
        let queued = BuildSnapshot(runs: [run("q", workflow: "a", startedAgo: nil, progress: .pending)])
        let image = MenuBarIcon.image(ring: try #require(MenuBarRing.leader(in: [queued], now: now, locale: english)))

        let drawn = try count(image, dark: true)

        #expect(drawn.blue == 0)
        #expect(drawn.opaque > 0)
    }

    // MARK: The block of the menu

    @Test func theBlockOfTheMenuCarriesTheRingAndTheInitialOfTheApp() throws {
        let snapshot = running("r", workflow: "a", testElapsed: 100)

        let line = try #require(RunningBuildLine.lines(in: snapshot, now: now, locale: english).first)

        #expect(line.ring == BuildRing(run: try #require(snapshot.runs.last), in: snapshot, now: now, locale: english))
        #expect(line.initial == "S")
        #expect(line.paletteKey == "Sextant")
    }

    @Test func aQueuedBlockHasTheDottedRing() throws {
        let queued = run("q", workflow: "a", startedAgo: nil, progress: .pending)
        let snapshot = BuildSnapshot(products: [CIProduct(id: "p", name: "Sextant", productType: "APP", appID: "1", appName: nil, bundleID: nil)], runs: [queued])

        #expect(RunningBuildLine.lines(in: snapshot, now: now, locale: english).first?.ring.state == .queued)
    }
}
