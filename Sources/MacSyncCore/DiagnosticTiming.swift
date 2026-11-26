import Foundation

/// Constant-memory timing distribution. Each observation uses monotonic seconds.
/// Bucket limits are upper bounds, not exact measured percentiles.
public struct DiagnosticTiming: Codable, Equatable, Sendable {
    public static let bounds:[Double] = [0.00001,0.00005,0.0001,0.00025,0.0005,0.001,0.002,0.005,0.01,0.02,0.05,0.1,0.15,0.25,0.5,1,2,5,10,30,60,120,300,600]
    public private(set) var count:Int = 0
    public private(set) var totalSeconds:Double = 0
    public private(set) var maximumSeconds:Double = 0
    public private(set) var buckets:[Int] = Array(repeating:0,count:DiagnosticTiming.bounds.count+1)
    public init() {}
    public mutating func observe(_ seconds:Double) {
        guard seconds.isFinite,seconds>=0,count<Int.max,totalSeconds+seconds<Double.greatestFiniteMagnitude else { return }
        count+=1
        totalSeconds+=seconds
        maximumSeconds=max(maximumSeconds,seconds)
        let index=Self.bounds.firstIndex(where:{seconds<=$0}) ?? Self.bounds.count
        buckets[index]+=1
    }
    public var isValid:Bool {
        guard count>=0,count<=100_000_000,totalSeconds.isFinite,totalSeconds>=0,
            maximumSeconds.isFinite,maximumSeconds>=0,buckets.count==Self.bounds.count+1,
            buckets.allSatisfy({$0>=0 && $0<=count}) else { return false }
        return buckets.reduce(0,+)==count
    }
    public mutating func merge(_ other:Self) {
        guard isValid,other.isValid,count+other.count<=100_000_000,
              (totalSeconds+other.totalSeconds).isFinite else { return }
        count+=other.count
        totalSeconds+=other.totalSeconds
        maximumSeconds=max(maximumSeconds,other.maximumSeconds)
        for index in buckets.indices { buckets[index]+=other.buckets[index] }
    }
    public var meanSeconds:Double? { count>0 ? totalSeconds/Double(count) : nil }
    public func percentileUpperBound(_ fraction:Double)->Double? {
        guard isValid,count>0,fraction>0,fraction<=1 else { return nil }
        let rank=Int(ceil(Double(count)*fraction))
        var cumulative=0
        for (index,n) in buckets.enumerated() {
            cumulative+=n
            if cumulative>=rank {
                return index<Self.bounds.count ? min(Self.bounds[index],maximumSeconds) : maximumSeconds
            }
        }
        return nil
    }
    /// Only explicitly recognized metric names are interpreted as structured
    /// timing data. Never export arbitrary free-form log messages.
    public static let transferActions:Set<String> = [
        "metric_copy_preflight","metric_copy_postflight","metric_queue_acknowledgment",
        "metric_rclone_process_launch","metric_rclone_total_process","metric_rclone_mkdir",
        "metric_job_wall","metric_job_reconciliation","metric_job_retry_preparation",
        "metric_audit_destination_lstat"
    ]
    public static let prefix="timing_distribution_"
}
