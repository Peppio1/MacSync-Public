import Foundation
import Darwin

/// Resource counters from the OS, independent of any network or archive reads.
/// Child usage is for reaped children, not live Rclone CPU/RAM. Block
/// operation counts are not disk byte counts. Peak RSS is not current RSS.
public struct DiagnosticResourceCounters: Equatable, Sendable {
    public let capturedAt:Date
    public let uptime:Double
    public let processCPUSeconds:Double
    public let completedChildrenCPUSeconds:Double
    public let processPeakResidentBytes:Int64
    public let processInputBlocks:Int64
    public let processOutputBlocks:Int64
    public let thermal:DiagnosticResourceSample.Thermal
    public let lowPower:Bool

    public init(uptime:Double,processCPUSeconds:Double,completedChildrenCPUSeconds:Double,
                processPeakResidentBytes:Int64,processInputBlocks:Int64,processOutputBlocks:Int64,
                thermal:DiagnosticResourceSample.Thermal,lowPower:Bool,capturedAt:Date=Date()) {
        self.capturedAt=capturedAt;self.uptime=uptime;self.processCPUSeconds=processCPUSeconds
        self.completedChildrenCPUSeconds=completedChildrenCPUSeconds
        self.processPeakResidentBytes=processPeakResidentBytes
        self.processInputBlocks=processInputBlocks;self.processOutputBlocks=processOutputBlocks
        self.thermal=thermal;self.lowPower=lowPower
    }
    public static func read()->Self? {
        var own=rusage(),children=rusage()
        guard getrusage(RUSAGE_SELF,&own)==0,getrusage(RUSAGE_CHILDREN,&children)==0 else { return nil }
        func cpu(_ r:rusage)->Double {
            Double(r.ru_utime.tv_sec)+Double(r.ru_utime.tv_usec)/1_000_000
            + Double(r.ru_stime.tv_sec)+Double(r.ru_stime.tv_usec)/1_000_000
        }
        let process=ProcessInfo.processInfo
        let thermal:DiagnosticResourceSample.Thermal
        switch process.thermalState {
        case .nominal:thermal = .nominal
        case .fair:thermal = .fair
        case .serious:thermal = .serious
        case .critical:thermal = .critical
        @unknown default:thermal = .unknown
        }
        return .init(uptime:process.systemUptime,processCPUSeconds:cpu(own),
                     completedChildrenCPUSeconds:cpu(children),processPeakResidentBytes:Int64(own.ru_maxrss),
                     processInputBlocks:Int64(own.ru_inblock),processOutputBlocks:Int64(own.ru_oublock),
                     thermal:thermal,lowPower:process.isLowPowerModeEnabled)
    }
}

public struct DiagnosticResourceSample: Codable, Equatable, Sendable {
    public enum Thermal:String,Codable,Sendable { case nominal,fair,serious,critical,unknown }
    public static let action="metric_resource_interval"
    public let capturedAt:Date
    public let intervalSeconds:Double
    /// 100% means one fully utilized logical core, not the whole machine.
    public let processCPUPercentOfOneCore:Double
    /// CPU seconds attributed when child processes have been reaped.
    /// Can include work from before this interval; NOT instantaneous CPU%.
    public let completedChildrenCPUSeconds:Double
    public let processPeakResidentBytes:Int64
    public let processInputBlocks:Int64
    public let processOutputBlocks:Int64
    public let thermal:Thermal
    public let lowPower:Bool

    public static func between(_ start:DiagnosticResourceCounters,_ end:DiagnosticResourceCounters)->Self? {
        let elapsed=end.uptime-start.uptime
        let cpu=end.processCPUSeconds-start.processCPUSeconds
        let children=end.completedChildrenCPUSeconds-start.completedChildrenCPUSeconds
        guard elapsed>=1,elapsed.isFinite,cpu>=0,cpu.isFinite,children>=0,children.isFinite,
              start.processInputBlocks>=0,start.processOutputBlocks>=0,
              end.processInputBlocks>=start.processInputBlocks,end.processOutputBlocks>=start.processOutputBlocks else { return nil }
        let sample=Self(capturedAt:end.capturedAt,intervalSeconds:elapsed,processCPUPercentOfOneCore:100*cpu/elapsed,
                        completedChildrenCPUSeconds:children,processPeakResidentBytes:end.processPeakResidentBytes,
                        processInputBlocks:end.processInputBlocks-start.processInputBlocks,
                        processOutputBlocks:end.processOutputBlocks-start.processOutputBlocks,
                        thermal:end.thermal,lowPower:end.lowPower)
        return sample.isValid ? sample : nil
    }
    public var isValid:Bool {
        intervalSeconds.isFinite && intervalSeconds>=1 &&
        processCPUPercentOfOneCore.isFinite && processCPUPercentOfOneCore>=0 &&
        completedChildrenCPUSeconds.isFinite && completedChildrenCPUSeconds>=0 &&
        processPeakResidentBytes>=0 && processInputBlocks>=0 && processOutputBlocks>=0
    }
}
