import XCTest
@testable import MiniRunKit

final class MediaMenuTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func shared(_ id: String, kind: MediaItem.Kind = .screenshot, age: TimeInterval, label: String? = "you/app@main") -> MediaItem {
        let tag = MediaItem.tag(label: label)
        return MediaItem(id: id, kind: kind, files: [.init(ext: "jpg", bytes: 1000)], createdAt: now.addingTimeInterval(-age),
                         expiresAt: now.addingTimeInterval(86400 - age), repo: tag.repo, ref: tag.ref, url: "https://w/m/\(id)")
    }

    func testRowsAndSummary() {
        XCTAssertEqual(MenuSnapshot.summarize(MediaSummary(count: 14, bytes: 38_000_000)), "14 items · 38 MB")
        XCTAssertEqual(MenuSnapshot.summarize(MediaSummary(count: 1, bytes: 250_000)), "1 item · 250 KB")
        XCTAssertEqual(MenuSnapshot.summarize(MediaSummary(count: 0, bytes: 0)), "Nothing shared")

        let items = (0..<12).map { shared("id\($0)", age: Double($0) * 600) } + [
            shared("rec", kind: .recording, age: 7200 + 1, label: nil),
            shared("expired", age: 90000),
        ]
        let rows = MenuSnapshot.mediaRows(items, now: now)
        XCTAssertEqual(rows.count, MenuSnapshot.maxMedia)
        XCTAssertEqual(rows.first?.id, "id0", "newest first")
        XCTAssertEqual(rows.first?.title, "you/app@main · screenshot · just now")
        XCTAssertEqual(rows[2].title, "you/app@main · screenshot · 20 min ago")
        XCTAssertFalse(rows.contains { $0.id == "expired" })
        XCTAssertEqual(MenuSnapshot.MediaRow(items[12], now: now).title, "untagged · recording · 2 h ago")
    }

    func testStatusShowsRecordingAndMedia() {
        let status = ServeStatus(
            version: "0.4.0", pid: 1, startedAt: now, relay: .init(state: .connected, host: "h", since: now),
            simulators: [.init(udid: "SIM-A", name: "iPhone 17 Pro", runtime: "iOS 26.0", recording: true), .init(udid: "SIM-B", name: "iPhone 17", runtime: "iOS 26.0")],
            media: MediaSummary(count: 2, bytes: 2_000_000)
        )
        let snapshot = MenuSnapshot.make(.answered(ControlProtocol.Response(ok: true, status: status)), connectorURL: nil, logTail: nil, canStart: true, now: now)
        XCTAssertTrue(snapshot.recording)
        XCTAssertEqual(snapshot.simulators.map(\.recording), [true, false])
        XCTAssertEqual(snapshot.mediaSummary, "2 items · 2.0 MB")

        var old = status
        old.media = nil
        old.simulators[0].recording = false
        let before = MenuSnapshot.make(.answered(ControlProtocol.Response(ok: true, status: old)), connectorURL: nil, logTail: nil, canStart: true, now: now)
        XCTAssertFalse(before.recording)
        XCTAssertNil(before.mediaSummary, "a daemon from before sharing has no Shared media row")
    }

    func testMenuLoadsMediaWhenOpenedAndAfterDeleting() async throws {
        let daemon = MenuModelTests.FakeDaemon()
        let left = Locked([shared("one", age: 60), shared("two", age: 120)])
        daemon.respond = { request in
            switch request.command {
            case "status":
                return ControlProtocol.Response(ok: true, status: ServeStatus(
                    version: "0.4.0", pid: 1, startedAt: Date(timeIntervalSince1970: 2_000_000_000),
                    relay: .init(state: .connected, host: "h", since: Date(timeIntervalSince1970: 2_000_000_000))
                ))
            case "list_media": return ControlProtocol.Response(ok: true, media: left.value)
            case "delete_media":
                left.mutate { $0.removeAll { $0.id == request.id } }
                return ControlProtocol.Response(ok: true, message: "Deleted \(request.id ?? "").")
            default: return ControlProtocol.Response(ok: true, message: "Did \(request.command).")
            }
        }
        let model = MenuModel(environment: daemon.environment())
        await model.refresh()
        await model.loadMedia()
        var snapshot = await model.snapshot
        XCTAssertEqual(snapshot.media.map(\.id), ["one", "two"])

        await model.perform(.deleteMedia("one"))
        snapshot = await model.snapshot
        XCTAssertEqual(snapshot.media.map(\.id), ["two"])
        XCTAssertEqual(snapshot.notice, .init("Deleted one."))
        XCTAssertEqual(daemon.sent.suffix(3), ["delete_media", "list_media", "status"])

        await model.perform(.stopRecording("SIM-A"))
        XCTAssertEqual(daemon.sent.suffix(2), ["stop_recording", "status"])
    }

    func testSettingsFormSharing() {
        var form = SettingsForm(MiniRunConfig())
        XCTAssertTrue(form.shareMedia)
        XCTAssertEqual(form.mediaRetentionDays, 7)
        XCTAssertEqual(form.retentionChoices, [1, 7, 30, 90])
        XCTAssertTrue(form.problems.isEmpty)

        form.shareMedia = false
        form.mediaRetentionDays = 30
        form.mediaStorageLimitMB = 200
        form.maxRecordingSeconds = 120
        form.mediaInlineLimitMB = 10
        let config = form.applied(to: MiniRunConfig())
        XCTAssertFalse(config.shareMedia)
        XCTAssertEqual(config.mediaRetentionDays, 30)
        XCTAssertEqual(config.mediaStorageLimitMB, 200)
        XCTAssertEqual(config.maxRecordingSeconds, 120)
        XCTAssertEqual(config.mediaInlineLimitMB, 10)

        form.mediaRetentionDays = 14
        XCTAssertEqual(form.retentionChoices, [1, 7, 14, 30, 90], "a hand-edited value stays choosable")
        form.mediaStorageLimitMB = 5000
        form.maxRecordingSeconds = 2
        form.mediaInlineLimitMB = 0
        XCTAssertEqual(form.problems.count, 3)
    }
}
