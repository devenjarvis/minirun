import Foundation
import MiniRunKit
import MiniRunSim

/// Screenshots and recordings shared through the Worker for PR descriptions (docs/pr-media-plan.md).
extension ToolRegistry {
    func registerMediaTools() {
        let device = Self.deviceProperty

        register(ToolDefinition(
            name: "start_recording",
            description: "Start recording the simulator's screen, to show a flow in a PR. Then tap, swipe and type as usual, and call stop_recording, " +
                "which returns markdown for the PR description: an inline GIF that links to the video. " +
                "The recording stops by itself after max_seconds. One recording per simulator. " +
                "Set configure_simulator {status_bar: \"demo\"} first for a clean status bar, and never record credentials or personal data.",
            properties: device.merging([
                "max_seconds": Schema.integer("Stop by itself after this many seconds (default and limit: the Mac's Longest recording setting, 60 unless changed).", minimum: 5, maximum: 300),
            ]) { a, _ in a }
        )) { [self] args in
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
            description: "Stop the simulator's recording. With share (the default) it makes a GIF, uploads it and the video, and returns a public link " +
                "and ready-to-paste markdown for the PR description. Either way it returns a few still frames so you can check what was recorded. " +
                "Making the GIF can take a while: if it's still going after wait_seconds you get a job_id for get_job.",
            properties: device.merging(Self.waitProperty) { a, _ in a }.merging([
                "share": Schema.boolean("Upload it for the PR (default true). Anyone with the link can see it until it expires."),
                "caption": Schema.string("Short description, used as the image's alt text, e.g. \"Onboarding flow\"."),
            ]) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args, boot: false)
            let share = args.bool("share") ?? true
            let caption = args.string("caption")
            return await runAsJob(args, title: "stop recording on \(sim.name)", log: nil) { [self] in
                try await finishRecording(sim, share: share, caption: caption)
            }
        }

        register(ToolDefinition(
            name: "delete_media",
            description: "Take back something you shared with screenshot {share} or stop_recording: its link stops working. " +
                "Only media shared for your simulator's repo + ref can be deleted. GitHub may keep showing a cached copy for a while.",
            properties: device.merging([
                "id": Schema.string("The id from the share result."),
            ]) { a, _ in a },
            required: ["id"]
        )) { [self] args in
            let id = try args.requireString("id")
            guard MediaItem.isValidID(id), let item = await media.item(id) else {
                throw ToolError("No shared media with id \(id). It may have expired already.")
            }
            let sim = try await self.device(args, boot: false)
            let label = await claims.claim(sim.udid)?.label
            guard item.label == label else {
                throw ToolError("\(id) was shared for \(item.label ?? "no repo"), but \(sim.name) is reserved for \(label ?? "nothing"), " +
                    "so it isn't yours to delete. The user can delete it from the menu bar app.")
            }
            try await MediaUploader(config: config).delete(id: id)
            await media.remove(id)
            return .text("Deleted \(id). Its link no longer works, though GitHub may show a cached copy for a while.")
        }
    }

    /// Uploads a 2x copy of the screen for screenshot {share}. Returns the text for the agent,
    /// which explains what went wrong rather than failing the screenshot.
    func shareScreenshot(udid: String, caption: String?) async -> String {
        let config = self.config
        guard config.shareMedia else { return MediaSharing.disabledMessage }
        do {
            let uploader = try MediaUploader(config: config)
            // Sharp in a PR: two image pixels per point. The agent's copy stays at one.
            let shot: (data: Data, width: Int, height: Int)
            if let size = await geometry.pointSize(udid: udid) {
                shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, targetWidth: Int((size.width * 2).rounded()), quality: 85)
            } else {
                shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, scale: 2.0 / 3.0, quality: 85) // 3x screens: ≈ 2x points
            }
            let label = await claims.claim(udid)?.label
            let (item, deleted) = try await MediaSharing.share(
                kind: .screenshot, files: [.init(ext: "jpg", data: shot.data)], caption: caption, label: label,
                config: config, ledger: media, uploader: uploader
            )
            return MediaSharing.report(item, deleted: deleted)
        } catch {
            return "Not shared: \(error.localizedDescription)"
        }
    }

    /// stop_recording's work: stop, make the GIF, upload, and hand back stills.
    func finishRecording(_ sim: XcodeParsing.SimDevice, share: Bool, caption: String?) async throws -> ToolResult {
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
                let uploader = try MediaUploader(config: config)
                let mp4 = try Data(contentsOf: done.file)
                let gif = try await GIFMaker.make(video: done.file, limitBytes: config.mediaInlineLimitBytes)
                let label = await claims.claim(sim.udid)?.label
                let (item, deleted) = try await MediaSharing.share(
                    kind: .recording, files: [.init(ext: "mp4", data: mp4), .init(ext: "gif", data: gif.data)], caption: caption, label: label,
                    config: config, ledger: media, uploader: uploader
                )
                lines.append(MediaSharing.report(item, deleted: deleted))
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
