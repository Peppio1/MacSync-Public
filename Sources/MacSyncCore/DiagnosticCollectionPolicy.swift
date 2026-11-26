import Foundation

public enum DiagnosticCollectionLevel:String,CaseIterable,Sendable {
    case standard,advanced,profiling
    public static let preferenceKey="MacSync.diagnosticCollectionLevel"
    public static let profilingUntilKey="MacSync.diagnosticProfilingUntil"
    public static let retentionKey="MacSync.diagnosticRetentionDays"
    public static let retentionOptions=[1,7,15,30,90]
    public static let defaultRetention=30
    public static let maxRetainedSamples=100_000
    public static func effective(raw:String?,until:Double,now:Date)->Self {
        let selected=Self(rawValue:raw ?? "") ?? .advanced
        if selected == .profiling {
            let remaining=until-now.timeIntervalSince1970
            if !remaining.isFinite || remaining<=0 || remaining>900 { return .advanced }
        }
        return selected
    }
    public static var current:Self {
        let d=UserDefaults.standard
        return effective(raw:d.string(forKey:preferenceKey),until:d.double(forKey:profilingUntilKey),now:Date())
    }
    public static var retentionDays:Int {
        let days=UserDefaults.standard.integer(forKey:retentionKey)
        return retentionOptions.contains(days) ? days : defaultRetention
    }
    public var heartbeatInterval:Double { self == .standard ? 5 : 1 }
    public var flushInterval:Double {
        switch self { case .standard:return 300;case .advanced:return 60;case .profiling:return 15 }
    }
}
