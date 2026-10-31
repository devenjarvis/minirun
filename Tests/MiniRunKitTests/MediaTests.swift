import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MiniRunKit

/// Records requests and answers them with a canned status and body.
final class FakeMediaWorker: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    var answer: @Sendable (URLRequest) -> (Int, String) = { request in
        request.httpMethod == "PUT" ? (201, #"{"url":"https://w.example/m/\#(request.url!.lastPathComponent)"}"#) : (204, "")
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { sent.append(request) }
        let (status, body) = answer(request)
        return (status, Data(body.utf8))
    }
}

final class MediaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func item(_ id: String, bytes: Int, age: TimeInterval, expiresIn: TimeInterval = 86400, label: String? = "you/app@main") -> MediaItem {
        let tag = MediaItem.tag(label: label)
        return MediaItem(id: id, kind: .screenshot, files: [.init(ext: "jpg", bytes: bytes)],
                         createdAt: now.addingTimeInterval(-age), expiresAt: now.addingTimeInterval(expiresIn - age),
                         repo: tag.repo, ref: tag.ref, url: "https://w.example/m/\(id).jpg")
    }

    func testIDsAreRandomBase64URL() {
        let ids = (0..<200).map { _ in MediaItem.newID() }
        XCTAssertEqual(Set(ids).count, 200)
        for id in ids {
            XCTAssertEqual(id.count, 22)
            XCTAssertTrue(MediaItem.isValidID(id), id)
            XCTAssertNil(id.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        }
        XCTAssertFalse(MediaItem.isValidID("../../etc/passwd/aaaaaa"))
        XCTAssertFalse(MediaItem.isValidID("short"))
    }

    func testTagsComeFromReservationLabels() {
        XCTAssertTrue(MediaItem.tag(label: "you/app@feature/x") == ("you/app", "feature/x"))
        XCTAssertTrue(MediaItem.tag(label: "you/app") == ("you/app", nil))
        XCTAssertTrue(MediaItem.tag(label: nil) == (nil, nil))
        XCTAssertEqual(item("a", bytes: 1, age: 0, label: "you/app@feature/x").label, "you/app@feature/x")
        XCTAssertNil(item("a", bytes: 1, age: 0, label: nil).label)
    }

    func testLedgerPersistsAndPrunesExpired() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-media-\(UUID().uuidString)/media.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = MediaLedger(url: url)
        await ledger.add(item("old", bytes: 100, age: 3600))
        await ledger.add(item("new", bytes: 50, age: 60))
        await ledger.add(item("gone", bytes: 999, age: 7200, expiresIn: 3600))

        // A second ledger on the same file sees the same items: the file is the record.
        let reopened = MediaLedger(url: url)
        let listed = await reopened.list(now: now)
        XCTAssertEqual(listed.map(\.id), ["new", "old"], "newest first, expired dropped")
        let total = await reopened.totalBytes(now: now)
        XCTAssertEqual(total, 150)
        let summary = await reopened.summary(now: now)
        XCTAssertEqual(summary, MediaSummary(count: 2, bytes: 150))
        let raw = try JSONValue.parse(Data(contentsOf: url)).arrayValue ?? []
        XCTAssertEqual(raw.count, 2, "pruning rewrote the file")
        XCTAssertEqual(raw.first?.objectValue?["kind"]?.stringValue, "screenshot")

        let removed = await reopened.remove("old")
        XCTAssertEqual(removed?.id, "old")
        let missing = await reopened.remove("old")
        XCTAssertNil(missing)
        let found = await ledger.item("new", now: now)
        XCTAssertEqual(found?.id, "new")
    }

    func testCapPlanDeletesOldestFirst() {
        let items = [item("b", bytes: 300, age: 100), item("a", bytes: 300, age: 200), item("c", bytes: 300, age: 50)]
        XCTAssertEqual(MediaLedger.planCap(items, incoming: 100, limit: 1000).delete, [], "fits already")
        let plan = MediaLedger.planCap(items, incoming: 200, limit: 1000)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.delete.map(\.id), ["a"])
        XCTAssertEqual(MediaLedger.planCap(items, incoming: 700, limit: 1000).delete.map(\.id), ["a", "b"])
        XCTAssertEqual(MediaLedger.planCap(items, incoming: 800, limit: 1000).delete.map(\.id), ["a", "b", "c"])
        let tooBig = MediaLedger.planCap(items, incoming: 1001, limit: 1000)
        XCTAssertFalse(tooBig.fits)
        XCTAssertEqual(tooBig.delete, [])
    }

    func testMarkdown() {
        XCTAssertEqual(MediaMarkdown.screenshot(caption: "Settings, dark mode", url: "https://w/m/x.jpg"), "![Settings, dark mode](https://w/m/x.jpg)")
        XCTAssertEqual(MediaMarkdown.screenshot(caption: nil, url: "https://w/m/x.jpg"), "![Screenshot](https://w/m/x.jpg)")
        XCTAssertEqual(MediaMarkdown.screenshot(caption: "a [b]\nc", url: "u"), #"![a \[b\] c](u)"#)
        XCTAssertEqual(MediaMarkdown.recording(caption: "Onboarding flow", gifURL: "https://w/m/x.gif", pageURL: "https://w/m/x"),
                       "[![Onboarding flow](https://w/m/x.gif)](https://w/m/x)")
        XCTAssertEqual(MediaMarkdown.recording(caption: "  ", gifURL: "g", pageURL: "p"), "[![Recording](g)](p)")
    }

    func testUploaderSendsTheContractHeaders() async throws {
        let worker = FakeMediaWorker()
        let uploader = MediaUploader(base: URL(string: "https://w.example")!, token: "secret", transport: worker)
        let url = try await uploader.upload(id: "AAAAAAAAAAAAAAAAAAAAAA", ext: "jpg", data: Data([1, 2, 3]), expiresIn: 604_800, caption: "Café & dark/mode")
        XCTAssertEqual(url, "https://w.example/m/AAAAAAAAAAAAAAAAAAAAAA.jpg")
        try await uploader.delete(id: "AAAAAAAAAAAAAAAAAAAAAA")

        let put = worker.requests[0]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.absoluteString, "https://w.example/media/AAAAAAAAAAAAAAAAAAAAAA.jpg")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(put.value(forHTTPHeaderField: "X-Minirun-Expires-In"), "604800")
        XCTAssertEqual(put.value(forHTTPHeaderField: "X-Minirun-Caption"), "Caf%C3%A9%20%26%20dark%2Fmode")
        XCTAssertEqual(put.httpBody, Data([1, 2, 3]))

        let delete = worker.requests[1]
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(delete.url?.absoluteString, "https://w.example/media/AAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(delete.value(forHTTPHeaderField: "Authorization"), "Bearer secret")

        _ = try await uploader.upload(id: "BBBBBBBBBBBBBBBBBBBBBB", ext: "mp4", data: Data([0]), expiresIn: 60, caption: nil)
        XCTAssertNil(worker.requests[2].value(forHTTPHeaderField: "X-Minirun-Caption"))
        XCTAssertEqual(worker.requests[2].value(forHTTPHeaderField: "Content-Type"), "video/mp4")
    }

    func testCaptionsAreCutToTwoHundredEncodedCharacters() {
        XCTAssertEqual(MediaUploader.encodeCaption(String(repeating: "a", count: 300)).count, 200)
        let accented = MediaUploader.encodeCaption(String(repeating: "é", count: 100))
        XCTAssertLessThanOrEqual(accented.count, 200)
        XCTAssertEqual(accented.removingPercentEncoding, String(repeating: "é", count: 33))
    }

    func testUploaderExplainsWorkerErrors() async {
        let worker = FakeMediaWorker()
        let uploader = MediaUploader(base: URL(string: "https://w.example")!, token: "t", transport: worker)
        worker.answer = { _ in (404, "Not found") }
        do {
            _ = try await uploader.upload(id: "AAAAAAAAAAAAAAAAAAAAAA", ext: "jpg", data: Data([1]), expiresIn: 60, caption: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Redeploy the Worker"), error.localizedDescription)
        }
        // Deleting something the Worker no longer has is fine.
        do { try await uploader.delete(id: "AAAAAAAAAAAAAAAAAAAAAA") } catch { XCTFail("\(error)") }

        worker.answer = { _ in (401, "") }
        do {
            _ = try await uploader.upload(id: "AAAAAAAAAAAAAAAAAAAAAA", ext: "jpg", data: Data([1]), expiresIn: 60, caption: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("agent token"), error.localizedDescription)
        }
        XCTAssertThrowsError(try MediaUploader(config: MiniRunConfig()))
    }

    func testShareDeletesOldestUploadsAndRecords() async throws {
        let worker = FakeMediaWorker()
        let uploader = MediaUploader(base: URL(string: "https://w.example")!, token: "t", transport: worker)
        let ledger = MediaLedger(url: nil)
        let mb = 1_048_576
        await ledger.add(item("AAAAAAAAAAAAAAAAAAAAA1", bytes: 6 * mb, age: 500))
        await ledger.add(item("AAAAAAAAAAAAAAAAAAAAA2", bytes: 3 * mb, age: 100))
        await ledger.add(item("AAAAAAAAAAAAAAAAAAAAA3", bytes: 1, age: 9000, expiresIn: 3600))
        var config = MiniRunConfig(relayURL: "wss://w.example/agent", agentToken: "t")
        config.mediaStorageLimitMB = 10
        config.mediaRetentionDays = 30

        let files = [MediaSharing.Upload(ext: "mp4", data: Data(count: 2 * mb)), MediaSharing.Upload(ext: "gif", data: Data(count: 100))]
        let (shared, deleted) = try await MediaSharing.share(kind: .recording, files: files, caption: "Flow", label: "you/app@feature",
                                                             config: config, ledger: ledger, uploader: uploader, now: now)
        XCTAssertEqual(deleted.map(\.id), ["AAAAAAAAAAAAAAAAAAAAA1"])
        XCTAssertEqual(worker.requests.map { "\($0.httpMethod!) \($0.url!.path)" }, [
            "DELETE /media/AAAAAAAAAAAAAAAAAAAAA1",
            "PUT /media/\(shared.id).mp4",
            "PUT /media/\(shared.id).gif",
        ])
        XCTAssertEqual(worker.requests[1].value(forHTTPHeaderField: "X-Minirun-Expires-In"), "2592000")
        XCTAssertEqual(shared.url, "https://w.example/m/\(shared.id)")
        XCTAssertEqual(shared.repo, "you/app")
        XCTAssertEqual(shared.ref, "feature")
        XCTAssertEqual(shared.bytes, 2 * mb + 100)
        XCTAssertEqual(shared.expiresAt, now.addingTimeInterval(30 * 86400))
        let listed = await ledger.list(now: now)
        XCTAssertEqual(listed.map(\.id), [shared.id, "AAAAAAAAAAAAAAAAAAAAA2"])

        let report = MediaSharing.report(shared, deleted: deleted)
        XCTAssertTrue(report.contains("Shared: https://w.example/m/\(shared.id) (expires 2033-06-17)"), report)
        XCTAssertTrue(report.contains("Markdown: [![Flow](https://w.example/m/\(shared.id).gif)](https://w.example/m/\(shared.id))"), report)
        XCTAssertTrue(report.contains("delete_media"))
    }

    func testShareRespectsTheSwitchAndCleansUpAFailedUpload() async throws {
        let worker = FakeMediaWorker()
        let uploader = MediaUploader(base: URL(string: "https://w.example")!, token: "t", transport: worker)
        let ledger = MediaLedger(url: nil)
        var config = MiniRunConfig(relayURL: "wss://w.example/agent", agentToken: "t")
        config.shareMedia = false
        do {
            _ = try await MediaSharing.share(kind: .screenshot, files: [.init(ext: "jpg", data: Data([1]))], caption: nil, label: nil,
                                             config: config, ledger: ledger, uploader: uploader, now: now)
            XCTFail("sharing is off")
        } catch {
            XCTAssertEqual(error.localizedDescription, MediaSharing.disabledMessage)
        }
        XCTAssertTrue(worker.requests.isEmpty)

        config.shareMedia = true
        worker.answer = { request in
            request.url!.pathExtension == "gif" ? (500, "boom") : (request.httpMethod == "PUT" ? (201, "{}") : (204, ""))
        }
        do {
            _ = try await MediaSharing.share(kind: .recording, files: [.init(ext: "mp4", data: Data([1])), .init(ext: "gif", data: Data([2]))],
                                             caption: nil, label: nil, config: config, ledger: ledger, uploader: uploader, now: now)
            XCTFail("the gif upload fails")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 500: boom"), error.localizedDescription)
        }
        XCTAssertEqual(worker.requests.map(\.httpMethod), ["PUT", "PUT", "DELETE"], "the uploaded mp4 is taken back")
        let left = await ledger.list(now: now)
        XCTAssertEqual(left, [])
    }

    func testConfigDefaultsAndClamping() throws {
        let config = try JSONDecoder().decode(MiniRunConfig.self, from: Data(#"{"relayURL":"wss://minirun.you.workers.dev/agent"}"#.utf8))
        XCTAssertTrue(config.shareMedia)
        XCTAssertEqual(config.mediaRetentionDays, 7)
        XCTAssertEqual(config.mediaStorageLimitMB, 500)
        XCTAssertEqual(config.maxRecordingSeconds, 60)
        XCTAssertEqual(config.mediaInlineLimitMB, 5)
        XCTAssertEqual(config, MiniRunConfig(relayURL: "wss://minirun.you.workers.dev/agent"))
        XCTAssertEqual(config.mediaBaseURL, "https://minirun.you.workers.dev")
        XCTAssertEqual(MiniRunConfig(relayURL: "ws://localhost:8787/agent").mediaBaseURL, "http://localhost:8787")
        XCTAssertNil(MiniRunConfig().mediaBaseURL)
        XCTAssertEqual(config.mediaRetentionSeconds, 7 * 86400)

        var odd = config
        odd.mediaRetentionDays = 365
        odd.maxRecordingSeconds = 1
        odd.mediaInlineLimitMB = 100
        XCTAssertEqual(odd.mediaRetentionSeconds, 90 * 86400)
        XCTAssertEqual(odd.recordingSecondsLimit, 5)
        XCTAssertEqual(odd.mediaInlineLimitBytes, 25 * 1_048_576)
        odd.mediaRetentionDays = 0
        odd.maxRecordingSeconds = 1000
        XCTAssertEqual(odd.mediaRetentionSeconds, 86400)
        XCTAssertEqual(odd.recordingSecondsLimit, 300)

        let saved = try JSONDecoder().decode(MiniRunConfig.self, from: JSONEncoder().encode(odd))
        XCTAssertEqual(saved, odd)
    }

    func testOldStatusDecodesWithoutMediaOrRecording() throws {
        let line = #"{"version":"0.3.0","pid":1,"startedAt":"2033-05-18T03:33:20Z","relay":{"state":"connected","since":"2033-05-18T03:33:20Z"},"#
            + #""simulators":[{"udid":"SIM-A","name":"iPhone 17 Pro","runtime":"iOS 26.0","booting":false,"busy":true}],"jobs":[]}"#
        let status = try ControlProtocol.decode(ServeStatus.self, from: line)
        XCTAssertNil(status.media)
        XCTAssertEqual(status.simulators.first?.recording, false)
        XCTAssertEqual(status.simulators.first?.busy, true)

        var newer = status
        newer.media = MediaSummary(count: 2, bytes: 3_000_000)
        newer.simulators[0].recording = true
        let decoded = try ControlProtocol.decode(ServeStatus.self, from: ControlProtocol.encode(newer))
        XCTAssertEqual(decoded, newer)
        XCTAssertTrue(newer.summary(now: status.startedAt).contains("Shared media: 2 items, 3.0 MB"))
        XCTAssertTrue(newer.summary(now: status.startedAt).contains("busy, recording"))
    }

    func testBackgroundProcessStopsOnInterrupt() async throws {
        let process = try BackgroundProcess.start("/bin/sh", ["-c", "trap 'echo finishing; exit 3' INT; echo started; while true; do sleep 0.1; done"])
        XCTAssertTrue(process.isRunning)
        for _ in 0..<50 where !process.output.contains("started") { try await Task.sleep(nanoseconds: 50_000_000) }
        let early = await process.wait(seconds: 0.2)
        XCTAssertFalse(early)
        process.interrupt()
        let exited = await process.wait(seconds: 5)
        XCTAssertTrue(exited)
        XCTAssertEqual(process.exitCode, 3)
        XCTAssertTrue(process.output.contains("finishing"), process.output)
        let again = await process.wait(seconds: 5)
        XCTAssertTrue(again, "waiting on a finished program returns at once")
    }
}
