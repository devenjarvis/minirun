import Foundation

/// Simulators that boot without the background services an app under test doesn't need: Siri and
/// Apple Intelligence, Health and Fitness, Watch pairing, Maps, Wallet, widgets, search indexing,
/// iCloud sync, Screen Time and so on. A stock iOS 27 simulator runs about 300 processes and costs
/// the Mac about 5 GB; a slim one runs about 60 and costs about 2 GB, and boots a little faster.
///
/// It works through launchd's own switch: `launchd_sim` reads the services to leave off from
/// `disabled.plist` in a folder named after the simulator's UDID (`disabledPlistURL`), outside the
/// device folder, before it starts anything. minirun writes that file before each boot, so a slim
/// simulator never starts those services at all. Nothing inside the runtime or the device changes,
/// and turning `slimSimulators` off removes minirun's entries before the next boot.
///
/// Every simulator has its own file, so templates and their clones are slimmed independently.
public enum SlimSimulators {
    /// The launchd labels switched off. Found by switching services off and checking that the
    /// simulator still boots, launches, installs and tests apps, and drives them through
    /// Accessibility. Labels a runtime doesn't have are ignored by launchd.
    ///
    /// Two services must stay on, so they're not here: `com.apple.nanoregistryd` (SpringBoard waits
    /// for it at boot, and the boot never finishes) and `com.apple.sleepd` (SpringBoard retries it in
    /// a tight loop).
    public static let services: [String] = [
        "com.apple.accessibility.axassetsd", "com.apple.accessibility.mediaaccessibilityd",
        "com.apple.activityawardsd", "com.apple.activitysharingd", "com.apple.addressbooksyncd", "com.apple.akd",
        "com.apple.amsaccountsd", "com.apple.amsengagementd", "com.apple.amsondevicestoraged",
        "com.apple.ap.adprivacyd", "com.apple.ap.promotedcontentd", "com.apple.appconduitd",
        "com.apple.AppSSODaemon", "com.apple.appstored", "com.apple.assetsubscriptiond",
        "com.apple.assistant_cdmd", "com.apple.assistant_service", "com.apple.assistantd", "com.apple.avatarsd",
        "com.apple.backgroundassets.user", "com.apple.biomed", "com.apple.biomesyncd", "com.apple.bird",
        "com.apple.brook.brookcompaniond", "com.apple.businessservicesd", "com.apple.calaccessd",
        "com.apple.carkitd", "com.apple.cdpd", "com.apple.chronod", "com.apple.cksharingmanagementd",
        "com.apple.ClipServices.clipserviced", "com.apple.cloudd", "com.apple.cmfsyncagent",
        "com.apple.communicationtrustd", "com.apple.companionappd", "com.apple.coreidvd", "com.apple.corespeechd",
        "com.apple.countryd", "com.apple.ctcategories.service", "com.apple.dataaccess.dataaccessd",
        "com.apple.DeviceConfigurationAgent", "com.apple.diagnosticextensionsd", "com.apple.dmd",
        "com.apple.donotdisturbd", "com.apple.email.maild", "com.apple.eventkitsyncd", "com.apple.familycircled",
        "com.apple.FamilyControlsAgent", "com.apple.fileindexerd", "com.apple.FileProvider", "com.apple.financed",
        "com.apple.findmy.findmylocated", "com.apple.finhealthd", "com.apple.fitcore",
        "com.apple.fitnesscoachingd", "com.apple.fitnessintelligenced", "com.apple.followupd",
        "com.apple.GameController.gamecontrollerd", "com.apple.gamed", "com.apple.generativeexperiencesd",
        "com.apple.geoanalyticsd", "com.apple.geod", "com.apple.healthappd", "com.apple.healthcontentd",
        "com.apple.healthd", "com.apple.homed", "com.apple.homeeventsd", "com.apple.hybridsearchd",
        "com.apple.icloudmailagent", "com.apple.identityservicesd", "com.apple.ids_simd",
        "com.apple.intelligencecontextd", "com.apple.intelligenceflowd", "com.apple.intelligenceplatformd",
        "com.apple.itunescloudd", "com.apple.itunesstored", "com.apple.jetpackassetd", "com.apple.linkd",
        "com.apple.liveactivitiesd", "com.apple.localizationswitcherd", "com.apple.managedassetsd",
        "com.apple.managedconfiguration.profiled", "com.apple.ManagedSettingsAgent",
        "com.apple.MapKit.SnapshotService", "com.apple.Maps.mapssyncd", "com.apple.mediaanalysisd",
        "com.apple.medialibraryd", "com.apple.mediaremoted", "com.apple.mobileassetd", "com.apple.mobiletimerd",
        "com.apple.modelcatalogd", "com.apple.modelmanagerd", "com.apple.nanoprefsyncd.2",
        "com.apple.nanoregistrylaunchd", "com.apple.nanotimekitcompaniond", "com.apple.navd", "com.apple.newsd",
        "com.apple.NPKCompanionAgent", "com.apple.parsec-fbf", "com.apple.parsecd", "com.apple.passd",
        "com.apple.peopled", "com.apple.photoanalysisd", "com.apple.PosterBoard", "com.apple.privacyaccountingd",
        "com.apple.protectedcloudstorage.protectedcloudkeysyncing", "com.apple.purplebuddy.budd",
        "com.apple.rapportd", "com.apple.remindd", "com.apple.remotemanagementd", "com.apple.replicatord",
        "com.apple.revisiond", "com.apple.routined", "com.apple.Safari.History",
        "com.apple.Safari.passwordbreachd", "com.apple.Safari.SafeBrowsing.Service",
        "com.apple.SafariBookmarksSyncAgent", "com.apple.ScreenTimeAgent", "com.apple.ScreenTimeSettingsAgent",
        "com.apple.searchd", "com.apple.sharingd", "com.apple.siri.context.service", "com.apple.siriactionsd",
        "com.apple.siriinferenced", "com.apple.siriknowledged", "com.apple.sirittsd", "com.apple.sociallayerd",
        "com.apple.splashboard", "com.apple.spotlightknowledged.updater", "com.apple.storekitd",
        "com.apple.suggestd", "com.apple.synapse.contentlinkingd", "com.apple.syncdefaultsd",
        "com.apple.telephonyutilities.callservicesd", "com.apple.textunderstandingd", "com.apple.translationd",
        "com.apple.triald", "com.apple.tvremoted", "com.apple.UsageTrackingAgent",
        "com.apple.VideoSubscriberAccount.DeveloperService", "com.apple.videosubscriptionsd",
        "com.apple.voicebankingd", "com.apple.wcd", "com.apple.weatherd", "com.apple.WebBookmarks.webbookmarksd",
        "com.apple.webprivacyd",
    ]

    /// Services an app's own frameworks need, left on unless `slimSimulatorKeep` says otherwise:
    /// MapKit (`geod`), CloudKit (`cloudd`), StoreKit testing (`storekitd`), HealthKit (`healthd`)
    /// and EventKit (`calaccessd`).
    public static let defaultKeep = [
        "com.apple.geod", "com.apple.cloudd", "com.apple.storekitd", "com.apple.healthd", "com.apple.calaccessd",
    ]

    /// Must never be switched off: the simulator doesn't finish booting without them.
    public static let required = ["com.apple.nanoregistryd", "com.apple.sleepd"]

    /// Marks a `disabled.plist` minirun wrote. launchd ignores labels no service has.
    public static let marker = "dev.minirun.slim"

    /// Where `launchd_sim` keeps a simulator's switched-off services.
    public static func disabledPlistURL(udid: String, tmp: String = "/private/var/tmp") -> URL {
        URL(fileURLWithPath: tmp, isDirectory: true)
            .appendingPathComponent("com.apple.CoreSimulator.SimDevice.\(udid)", isDirectory: true)
            .appendingPathComponent("disabled.plist")
    }

    /// The services a slim simulator leaves off, given the labels to keep.
    public static func disabled(keep: [String]) -> [String] {
        let kept = Set(keep).union(required)
        return services.filter { !kept.contains($0) }
    }

    public enum Plan: Equatable, Sendable {
        /// Write these entries (label: disabled).
        case write([String: Bool])
        /// Delete the file: minirun wrote it and nothing else is in it.
        case remove
        /// The file is already right, or isn't minirun's to change.
        case leave
    }

    /// What to do with a simulator's `disabled.plist` before it boots. Entries minirun didn't write
    /// (from `launchctl disable` inside the simulator, say) are kept either way.
    public static func plan(existing: [String: Bool]?, enabled: Bool, keep: [String]) -> Plan {
        var base = existing ?? [:]
        let ours = base[marker] == true
        if ours {
            let managed = Set(services).union([marker])
            base = base.filter { !managed.contains($0.key) }
        }
        // A required service is never left off, whoever switched it off.
        for label in required where base[label] == true { base[label] = nil }
        guard enabled else {
            guard ours else { return .leave }
            return base.isEmpty ? .remove : .write(base)
        }
        var wanted = base
        for label in disabled(keep: keep) { wanted[label] = true }
        wanted[marker] = true
        return wanted == existing ? .leave : .write(wanted)
    }

    /// Reads, plans and writes a simulator's `disabled.plist`. Call it before booting the simulator;
    /// a booted one picks the change up at its next boot.
    @discardableResult
    public static func prepare(udid: String, enabled: Bool, keep: [String], tmp: String = "/private/var/tmp") throws -> Plan {
        let url = disabledPlistURL(udid: udid, tmp: tmp)
        let existing = read(url)
        let plan = plan(existing: existing, enabled: enabled, keep: keep)
        switch plan {
        case .leave:
            break
        case .remove:
            try FileManager.default.removeItem(at: url)
        case .write(let entries):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        }
        return plan
    }

    /// The file's entries, or nil if there's no file. Entries that aren't booleans are dropped.
    static func read(_ url: URL) -> [String: Bool]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist.compactMapValues { value in
            if let flag = value as? Bool { return flag }
            return (value as? NSNumber)?.boolValue
        }
    }
}
