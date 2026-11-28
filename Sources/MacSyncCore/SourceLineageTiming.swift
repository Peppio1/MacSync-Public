import Foundation

/// Laboratory-only aggregate profiling. No paths, fingerprints or content
/// are emitted. No wall-clock reads or dictionary updates when disabled.
/// Nested measurements (e.g. record_write and store_write) overlap.
final class SourceLineageTiming {
    private struct Sample {
        var count = 0
        var nanoseconds: UInt64 = 0
    }
    private let enabled: Bool
    private let scope: String
    private let started: UInt64
    private var samples: [String:Sample] = [:]
    init(_ scope:String) {
        enabled = ProcessInfo.processInfo.environment["MACSYNC_LINEAGE_PROFILE"] == "1"
        self.scope = scope
        started = enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }
    func measure<T>(_ name:String,_ body:() throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start=DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed=DispatchTime.now().uptimeNanoseconds-start
            samples[name,default:Sample()].count += 1
            samples[name,default:Sample()].nanoseconds += elapsed
        }
        return try body()
    }
    func finish(items:Int,committed:Bool) {
        guard enabled else { return }
        let elapsed=DispatchTime.now().uptimeNanoseconds-started
        let details=samples.keys.sorted().compactMap { key -> String? in
            guard let s=samples[key] else { return nil }
            return "\(key)_n=\(s.count) \(key)_ns=\(s.nanoseconds)"
        }.joined(separator:" ")
        print("LINEAGE_PROFILE scope=\(scope) items=\(items) committed=\(committed) total_ns=\(elapsed) \(details)")
    }
}
