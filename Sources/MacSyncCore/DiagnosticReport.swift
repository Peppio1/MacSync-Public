import Foundation

public enum DiagnosticReport {
    private struct Report: Encodable {
        let schemaVersion = 4
        let database:DatabaseDiagnosticSnapshot
        let resourceSamples:[ResourceRecord]
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
    private struct ResourceRecord:Encodable {
        let timestamp:Date
        let sample:DiagnosticResourceSample
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

    private static func collect(databasePath:String,since:Date,appVersion:String) throws -> Report {
        let reader = try SyncActivityLog(path: databasePath, readOnly: true)
        var roots: [String: Int] = [:]
        var items: [String: Int] = [:]
        var cycles: [String: Int] = [:]
        var jobs: [Int64: Int] = [:]
        var events: [Event] = []
        var timingDistributions:[TimingRecord]=[]
        var resourceSamples:[ResourceRecord]=[]
        var before: Int64?
        repeat {
            let page = try reader.technicalPage(limit: 500, beforeID: before, since: since)
            for row in page {
                let entry = row.entry
                let root = alias(entry.rootID, in: &roots)
                let item = entry.relativePath.isEmpty ? nil : alias(String(root) + "/" + entry.relativePath, in: &items)
                if entry.action==DiagnosticResourceSample.action,
                   let sample=try? JSONDecoder().decode(DiagnosticResourceSample.self,from:Data(entry.message.utf8)),sample.isValid {
                    resourceSamples.append(.init(timestamp:entry.timestamp,sample:sample))
                }
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
        return Report(database:DatabaseDiagnosticSnapshot.collect(databasePath:databasePath),resourceSamples:resourceSamples,environment:Environment(),timingDistributions:timingDistributions,appVersion:appVersion,exportedAt:Date(),since:since,events:events)
    }

    private static func encoder()->JSONEncoder {
        let encoder=JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return encoder
    }

    public static func make(databasePath:String,since:Date,appVersion:String)throws->Data {
        try encoder().encode(collect(databasePath:databasePath,since:since,appVersion:appVersion))
    }

    private struct ExportSummary:Encodable {
        let schemaVersion:Int
        let appVersion:String
        let exportedAt:Date
        let requestedSince:Date
        let earliestRetainedEvent:Date?
        let latestRetainedEvent:Date?
        let eventCount:Int
        let timingDistributionCount:Int
        let resourceSampleCount:Int
        let actionCounts:[String:Int]
        let notes:[String]
    }
    private struct Section:Encodable {
        let timings:[TimingRecord]
        let events:[Event]
    }

    /// User-initiated export only. All sections use a single anonymized
    /// collection, so aliases stay consistent across the ZIP.
    public static func exportZIP(databasePath:String,since:Date,appVersion:String,to destination:URL)throws {
        let report=try collect(databasePath:databasePath,since:since,appVersion:appVersion)
        let fm=FileManager.default
        let temporary=fm.temporaryDirectory.appendingPathComponent("macsync-report-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? fm.removeItem(at:temporary) }
        let contents=temporary.appendingPathComponent("report",isDirectory:true)
        try fm.createDirectory(at:contents,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let json=encoder()
        func write<T:Encodable>(_ value:T,_ name:String)throws {
            try json.encode(value).write(to:contents.appendingPathComponent(name),options:.atomic)
        }
        let summary=ExportSummary(schemaVersion:report.schemaVersion,appVersion:report.appVersion,
            exportedAt:report.exportedAt,requestedSince:report.since,
            earliestRetainedEvent:report.events.map(\.timestamp).min(),latestRetainedEvent:report.events.map(\.timestamp).max(),
            eventCount:report.events.count,timingDistributionCount:report.timingDistributions.count,
            resourceSampleCount:report.resourceSamples.count,
            actionCounts:Dictionary(grouping:report.events,by:\.action).mapValues(\.count),
            notes:["Periodo richiesto, limitato agli eventi effettivamente conservati.",
                   "I percentili delle distribuzioni sono limiti superiori stimati.",
                   "I tempi delle fasi possono sovrapporsi e non devono essere sommati automaticamente.",
                   "Le chiamate filesystem non misurano i pacchetti SMB.",
                   "La CPU dei processi figli è contabilizzata al termine; RSS indica il picco.",
                   "Le misure UI riguardano consegna e risposta dei risultati, non fotogrammi.",
                   "Database: campione in sola lettura al momento dell’esportazione; conteggi parziali se il limite di tempo è raggiunto."])
        try write(summary,"riepilogo.json")
        try write(report.environment,"ambiente.json")
        try write(report.resourceSamples,"risorse.json")
        try write(report.database,"database.json")
        func section(_ filename:String,where includes:(String)->Bool)throws {
            try write(Section(timings:report.timingDistributions.filter{includes($0.action)},
                events:report.events.filter{includes($0.action)}),filename)
        }
        try section("sincronizzazioni.json") {
            $0=="cycle" || $0=="copy" || $0.hasPrefix("rclone") || $0.hasPrefix("metric_rclone") ||
            $0.hasPrefix("metric_copy") || $0.hasPrefix("metric_job") || $0.hasPrefix("mirror")
        }
        try section("verifiche_archivio.json") { $0.hasPrefix("audit") || $0.hasPrefix("metric_audit") }
        try section("filesystem.json") {
            $0=="metric_audit_destination_lstat" || $0.hasPrefix("smb") || $0.hasPrefix("connection")
        }
        try section("interfaccia.json") {
            $0.hasPrefix("metric_ui") || $0=="metric_progress_delivery_delay"
        }
        try section("coda.json") {
            $0.hasPrefix("queue") || $0.hasPrefix("metric_queue") || $0.hasPrefix("retry") ||
            $0.hasPrefix("monitor") || $0.hasPrefix("fsevent") || $0=="reconciled"
        }
        let iso=ISO8601DateFormatter()
        iso.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var lines=["timestamp\tlevel\taction\troot\titem\tcycle\tjob\tbytes\tseconds"]
        for event in report.events.reversed() {
            let fields=[iso.string(from:event.timestamp),event.level,event.action,String(event.root),
                event.item.map{String($0)} ?? "",event.cycle.map{String($0)} ?? "",event.job.map{String($0)} ?? "",
                String(event.bytes),String(event.seconds)]
            lines.append(fields.map{$0.replacingOccurrences(of:"\t",with:" ").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")}.joined(separator:"\t"))
        }
        try Data((lines.joined(separator:"\n")+"\n").utf8).write(to:contents.appendingPathComponent("eventi.tsv"),options:.atomic)
        let archive=temporary.appendingPathComponent("report.zip")
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-c","-k","--norsrc",contents.path,archive.path]
        process.standardInput=FileHandle.nullDevice
        process.standardOutput=FileHandle.nullDevice
        process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        guard process.terminationReason == .exit,process.terminationStatus==0 else {
            throw JournalError.database("Creazione archivio diagnostico non riuscita")
        }
        try Data(contentsOf:archive,options:.mappedIfSafe).write(to:destination,options:.atomic)
    }
}
