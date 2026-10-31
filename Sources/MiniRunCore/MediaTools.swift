import Foundation
import MiniRunKit
import MiniRunMac
import MiniRunSim

/// Screenshots and recordings shared for PR descriptions: committed to the repo's media branch
/// when it has one (docs/github-media-plan.md), else through the Worker (docs/pr-media-plan.md).
extension ToolRegistry {
    func registerMediaTools() {
        let device = Self.deviceProperty

        register(ToolDefinition(
            name: "start_recording",
            description: "Start recording the simulator's screen, to show a flow in a PR. Then tap, swipe and type as usual, and call stop_recording, " +
                "which returns markdown for the PR description: an inline GIF (on the repo's pr-media branch if it has one, else on the Worker with a link to the video). " +
                "The recording stops by itself after max_seconds. One recording per simulator. " +
                "Set configure_simulator {status_bar: \"demo\"} first for a clean status bar, and never record credentials or personal data.",
            properties: device.merging([
                "max_seconds": Schema.integer("Stop by itself after this many seconds (default and limit: the Mac's Longest recording setting, 60 unless changed).", minimum: 5, maximum: 300),
            ]) { a, _ in a }
        )) { [self] args in
            if MacAppID.isMacDevice(args.string("device")) { throw ToolError(MacToolSupport.unsupported("start_recording")) }
            let sim = try await self.device(args)
            let limit = config.recordingSecondsLimit
            let seconds = min(limit, max(MiniRunConfig.recordingSecondsRange.lowerBound, args.int("max_seconds") ?? limit))
            let points = await geometry.pointSize(udid: sim.udid)
            try await recordings.start(udid: sim.udid, maxSeconds: seconds, pointWidth: points?.width)
            await claims.touch(sim.udid)
            var text = "Recording \(sim.name). It stops by itself after \(seconds) s. Do what you want to show, then call stop_recording with device \"\(sim.udid)\"."
            if !config.shareMedia { text += "\nSharing is turned off on this Mac, so stop_recording will only return still frames." }
            return .text(text)
        }

        register(ToolDefinition(
            name: "stop_recording",
            description: "Stop the simulator's recording. With share (the default) it makes a GIF and uploads it, and returns markdown for the PR description: " +
                "a github.com embed when the repo has a pr-media branch (the GIF is committed there), else a Worker link to the GIF and video, which the GitHub tools turn into a plain link. " +
                "Either way it returns a few still frames so you can check what was recorded. " +
                "Making the GIF can take a while: if it's still going after wait_seconds you get a job_id for get_job.",
            properties: device.merging(Self.waitProperty) { a, _ in a }.merging([
                "share": Schema.boolean("Upload it for the PR (default true): to the repo's pr-media branch if it has one, else to the Worker."),
                "caption": Schema.string("Short description, used as the image's alt text, e.g. \"Onboarding flow\"."),
            ]) { a, _ in a }.merging(MediaShareOptions.properties) { a, _ in a }
        )) { [self] args in
            if MacAppID.isMacDevice(args.string("device")) { throw ToolError(MacToolSupport.unsupported("stop_recording")) }
            let sim = try await self.device(args, boot: false)
            let share = args.bool("share") ?? true
            let options = MediaShareOptions(args)
            return await runAsJob(args, title: "stop recording on \(sim.name)", log: nil) { [self] in
                try await finishRecording(sim, share: share, options: options)
            }
        }

        register(ToolDefinition(
            name: "delete_media",
            description: "Take back something you shared with screenshot {share} or stop_recording. A Worker link stops working (GitHub may keep showing a cached copy for a while). " +
                "A file on the repo's pr-media branch is removed from the branch, but links pinned to the earlier commit keep working. " +
                "Only media shared for your simulator's (or Mac app's) repo + ref can be deleted.",
            properties: device.merging([
                "id": Schema.string("The id from the share result."),
            ]) { a, _ in a },
            required: ["id"]
        )) { [self] args in
            let id = try args.requireString("id")
            guard MediaItem.isValidID(id), let item = await media.item(id) else {
                throw ToolError("No shared media with id \(id). It may have expired already.")
            }
            // A Mac app's shares carry its workspace label, as a simulator's carry its reservation's.
            let name: String
            let label: String?
            if MacAppID.isMacDevice(args.string("device")) {
                let session = try await macApp(args, running: false)
                name = session.name
                label = session.label
            } else {
                let sim = try await self.device(args, boot: false)
                name = sim.name
                label = await claims.claim(sim.udid)?.label
            }
            guard item.label == label else {
                throw ToolError("\(id) was shared for \(item.label ?? "no repo"), but \(name) is reserved for \(label ?? "nothing"), " +
                    "so it isn't yours to delete. The user can delete it from the menu bar app.")
            }
            return .text(try await MediaSharing.delete(item, config: config, ledger: media))
        }
    }

    /// Uploads a 2x copy of the screen for screenshot {share}. Returns the text for the agent,
    /// which explains what went wrong rather than failing the screenshot.
    func shareScreenshot(udid: String, options: MediaShareOptions) async -> String {
        let config = self.config
        guard config.shareMedia else { return MediaSharing.disabledMessage }
        do {
            // Sharp in a PR: two image pixels per point. The agent's copy stays at one.
            let shot: (data: Data, width: Int, height: Int)
            if let size = await geometry.pointSize(udid: udid) {
                shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, targetWidth: Int((size.width * 2).rounded()), quality: 85)
            } else {
                shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, scale: 2.0 / 3.0, quality: 85) // 3x screens: ≈ 2x points
            }
            let label = await claims.claim(udid)?.label
            return try await uploadScreenshot(shot.data, label: label, options: options)
        } catch {
            return "Not shared: \(error.localizedDescription)"
        }
    }

    /// screenshot {share} for a Mac app: a copy of its window at two pixels per point, shared for
    /// the app's workspace label.
    func shareMacScreenshot(_ session: MacAppSession, window: MacWindowSelector, options: MediaShareOptions) async -> String {
        let config = self.config
        guard config.shareMedia else { return MediaSharing.disabledMessage }
        do {
            guard let pid = session.pid else { throw ToolError(MacToolSupport.notRunning(session)) }
            let shot = try await MacAppDriver.shared.screenshotJPEG(pid: pid, window: window, scale: 2, quality: 85)
            return try await uploadScreenshot(shot.data, label: session.label, options: options)
        } catch {
            return "Not shared: \(error.localizedDescription)"
        }
    }

    private func uploadScreenshot(_ jpeg: Data, label: String?, options: MediaShareOptions) async throws -> String {
        let config = self.config
        return try await MediaSharing.shareAnywhere(
            kind: .screenshot, files: [.init(ext: "jpg", data: jpeg)], caption: options.caption, label: label,
            folder: options.folder, name: options.name, config: config, ledger: media,
            makeUploader: { try MediaUploader(config: config) }
        )
    }

    /// stop_recording's work: stop, make the GIF, upload, and hand back stills.
    func finishRecording(_ sim: XcodeParsing.SimDevice, share: Bool, options: MediaShareOptions) async throws -> ToolResult {
        let config = self.config
        let done = try await recordings.collect(sim.udid)
        defer { try? FileManager.default.removeItem(at: done.file) }
        var lines = ["Recorded \(Int(done.duration.rounded())) s on \(sim.name)."]
        if let early = done.stoppedEarly {
            lines.append("It stopped by itself before stop_recording, because \(early). What was recorded until then is below.")
        }
        let stills = (try? await GIFMaker.stills(video: done.file, pointWidth: done.pointWidth)) ?? []

        if !share {
            lines.append("Not shared (share: false). The still frames below are for checking your work.")
        } else if !config.shareMedia {
            lines.append(MediaSharing.disabledMessage)
        } else {
            do {
                let mp4 = try Data(contentsOf: done.file)
                let gif = try await GIFMaker.make(video: done.file, limitBytes: config.mediaInlineLimitBytes)
                let label = await claims.claim(sim.udid)?.label
                lines.append(try await MediaSharing.shareAnywhere(
                    kind: .recording, files: [.init(ext: "mp4", data: mp4), .init(ext: "gif", data: gif.data)], caption: options.caption, label: label,
                    folder: options.folder, name: options.name, config: config, ledger: media,
                    makeUploader: { try MediaUploader(config: config) }
                ))
                let size = WorkspaceInventory.formatSize(Int64(gif.data.count))
                lines.append("GIF: \(gif.width)x\(gif.height)px, \(gif.fps) fps, \(size).")
                if !gif.fits {
                    lines.append("The GIF is over the \(config.mediaInlineLimitMB) MB inline limit even at its smallest, so GitHub may not show it inline; " +
                        "the link to the video still works. A shorter recording fits better.")
                }
            } catch {
                lines.append("Not shared: \(error.localizedDescription)")
            }
        }
        if !stills.isEmpty { lines.append("Still frames (start, middle, end) at one pixel per point:") }
        return ToolResult([.text(lines.joined(separator: "\n"))] + stills.map { ToolContent.image(data: $0, mimeType: "image/jpeg") })
    }
}
