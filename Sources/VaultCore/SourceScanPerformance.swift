import Foundation
import os

/// Static payload-free intervals for Instruments; never logs titles, paths or content.
enum SourceScanPerformance {
    private static let log = OSLog(subsystem: "app.noema", category: .pointsOfInterest)
    static func measure<T>(_ name: StaticString, operation: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try operation()
    }
    static func event(_ name: StaticString) { os_signpost(.event, log: log, name: name) }
}
