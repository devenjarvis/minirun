import Foundation

/// Turns `swift test` output (XCTest and Swift Testing) into a short report: the totals, then
/// each failure or compile error with its file:line.
public enum SwiftTestReport {
    public static func summarize(_ result: ShellResult, stallTimeout: TimeInterval?, timeout: TimeInterval) -> String {
        let output = result.stdout + "\n" + result.stderr
        var lines: [String] = []
        if result.stalled {
            let quiet = stallTimeout.map { " for \(Int($0 / 60)) min" } ?? ""
            lines.append("swift test printed nothing\(quiet), so it was treated as hung and stopped. Pass a larger stall_seconds if it really is that quiet.")
        } else if result.timedOut {
            lines.append("swift test timed out after \(Int(timeout / 60)) min and was stopped.")
        }

        let all = output.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        // XCTest: "Executed 12 tests, with 1 failure (0 unexpected) in 0.5 (0.6) seconds". The
        // last one is the grand total.
        let totals = [
            all.last(where: { $0.hasPrefix("Executed ") && $0.contains(" test") }),
            // Swift Testing: "✔ Test run with 4 tests passed after 0.002 seconds." (the symbol varies).
            all.last(where: { $0.contains("Test run with ") }),
        ].compactMap { $0 }
        if totals.isEmpty, !result.timedOut {
            lines.append(result.succeeded ? "Tests passed." : "swift test failed (exit \(result.exitCode)).")
        } else {
            lines += totals.map { stripSymbol($0) }
        }

        // Compile errors and XCTest failures ("File.swift:12: error: -[Tests testX] : …").
        let issues = XcodeParsing.parseIssues(output, limit: 30)
        // Swift Testing failures: "✘ Test example() recorded an issue at File.swift:12:5: Expectation failed: …".
        let recorded = all.filter { $0.contains(" recorded an issue") }.prefix(30).map { stripSymbol($0) }
        let failures = issues.map(\.line) + recorded
        if !failures.isEmpty {
            lines.append("")
            lines += failures.map { "✗ " + $0 }
        }
        if totals.isEmpty, failures.isEmpty, !result.succeeded {
            lines.append("Last output:\n" + result.tail(3000))
        }
        return lines.joined(separator: "\n")
    }

    /// Drops a leading status symbol (✔, ✘, or an SF Symbols private-use character).
    static func stripSymbol(_ line: String) -> String {
        guard let first = line.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first), first != "/" else { return line }
        return String(line.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}
