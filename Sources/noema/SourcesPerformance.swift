import Foundation
import os

/// Points of Interest for the Sources presentation pipeline. Payloads deliberately
/// contain no titles, paths, source contents, or other vault data.
enum SourcesPerformance {
    private static let log = OSLog(subsystem: "app.noema", category: .pointsOfInterest)

    static func measure<Result>(_ name: StaticString, operation: () -> Result) -> Result {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return operation()
    }

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
