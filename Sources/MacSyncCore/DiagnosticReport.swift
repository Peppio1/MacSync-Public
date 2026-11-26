import Foundation

public enum DiagnosticReport {
    private struct Report: Encodable {
        let schemaVersion = 2
        let environment: Environment
        let timingDistributions: [TimingRecord]
        let appVersion: String
        let exportedAt: Date
        let since: Date
        let events: [Event]
    }

    private struct Environment:Encodable {
        let macOS:String
        let logicalProcessors:Int
        let activeProcessors:Int
        let physicalMemoryBytes:UInt64
        init() {
            let process=ProcessInfo.processInfo
            macOS=process.operatingSystemVersionString
            logicalProcessors=process.processorCount
            activeProcessors=process.activeProcessorCount
            physicalMemoryBytes=process.physicalMemory
        }
    }
    private struct TimingRecord:Encodable {
        let timestamp:Date
        let action:String
        let cycle:Int?
        let samples:DiagnosticTiming
        let meanSeconds:Double?
        let p50UpperBoundSeconds:Double?
        let p95UpperBoundSeconds:Double?
        let p99UpperBoundSeconds:Double?
        let bucketUpperBoundsSeconds:[Double] = DiagnosticTiming.bounds
    }

    private struct Event: Encodable {
        let timestamp: Date
        let level: String
        let action: String
        let root: Int
        let item: Int?
        let cycle: Int?
        let job: Int?
        let bytes: Int64
        let seconds: Double
    }

    private static func alias<Key: Hashable>(_ key: Key, in table: inout [Key: Int]) -> Int {
        if let id = table[key] { return id }
        let id = table.count + 1
        table[key] = id
        return id
    }

    public static func make(databasePath: String, since: Date, appVersion: String) throws -> Data {
        let reader = try SyncActivityLog(path: databasePath, readOnly: true)
        var roots: [String: Int] = [:]
        var items: [String: Int] = [:]
        var cycles: [String: Int] = [:]
        var jobs: [Int64: Int] = [:]
        var events: [Event] = []
        var timingDistributions:[TimingRecord]=[]
        var before: Int64?
        repeat {
            let page = try reader.technicalPage(limit: 500, beforeID: before, since: since)
            for row in page {
                let entry = row.entry
                let root = alias(entry.rootID, in: &roots)
                let item = entry.relativePath.isEmpty ? nil : alias(String(root) + "/" + entry.relativePath, in: &items)
                // Decode numeric-only, whitelisted timing distributions.
                if entry.action.hasPrefix(DiagnosticTiming.prefix) {
                    let action=String(entry.action.dropFirst(DiagnosticTiming.prefix.count))
                    if DiagnosticTiming.transferActions.contains(action) || DiagnosticTiming.uiActions.contains(action),
                       let timing=try? JSONDecoder().decode(DiagnosticTiming.self,from:Data(entry.message.utf8)),timing.isValid {
                        timingDistributions.append(.init(timestamp:entry.timestamp,action:action,
                            cycle:row.cycleID.map { alias($0,in:&cycles) },samples:timing,
                            meanSeconds:timing.meanSeconds,p50UpperBoundSeconds:timing.percentileUpperBound(0.5),
                            p95UpperBoundSeconds:timing.percentileUpperBound(0.95),p99UpperBoundSeconds:timing.percentileUpperBound(0.99)))
                    }
                }
                // Free-form messages and raw identifiers can contain paths or hostnames.
                events.append(Event(timestamp: entry.timestamp, level: entry.level, action: entry.action,
                    root: root, item: item, cycle: row.cycleID.map { alias($0, in: &cycles) },
                    job: row.jobID.map { alias($0, in: &jobs) }, bytes: entry.bytes, seconds: entry.durationSeconds))
            }
            before = page.count == 500 ? page.last?.id : nil
        } while before != nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Report(environment:Environment(),timingDistributions:timingDistributions,appVersion: appVersion, exportedAt: Date(), since: since, events: events))
    }
}
