import Foundation

public enum OperationEstimate {
    public static func remaining(processed: Int, total: Int, elapsed: Double) -> Double? {
        guard total > 0, processed > 0, processed < total, elapsed.isFinite, elapsed >= 1 else { return nil }
        let result = elapsed * Double(total-processed)/Double(processed)
        return result.isFinite && result >= 0 ? result : nil
    }
}
