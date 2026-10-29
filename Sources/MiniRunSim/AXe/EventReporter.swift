import Foundation
import FBControlCore

// MARK: - Event Reporter
@objc final class EmptyEventReporter: NSObject, FBEventReporter {
    @objc static let shared = EmptyEventReporter()
    var metadata: [String: String] = [:]
    func report(_ subject: FBEventReporterSubject) {}
    func addMetadata(_ metadata: [String: String]) {}
} 