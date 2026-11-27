import Foundation

/// Session-local sweep state. Only the serial copy worker owns this value.
/// A new sweep is due at most hourly; unfinished pages continue at later
/// successful cycles. No timer, filesystem work or automatic copy changes.
public struct RetentionSweep {
    public struct Result:Equatable,Sendable {
        public var examined=0
        public var queueRemoved=0
        public var receiptsRemoved=0
        public var pages=0
        public var held=false
        public var finished=false
        public var attempted=false
    }
    private var queueCursor:Int64=0
    private var receiptCursor:Int64=0
    private var queueFinished=false
    private var receiptFinished=false
    private var nextSweepAt:Double=0
    public init() {}

    /// Bounded slice; every completed page is an independent transaction.
    /// The caller checks successful cycle, cancellation and monitor readiness.
    /// A busy/error page never advances its cursor. Previously committed
    /// pages are not retried until the next complete sweep.
    public mutating func advance(journal:ChangeJournal, now:Date=Date(),
        uptime:()->Double={ProcessInfo.processInfo.systemUptime},
        shouldContinue:()->Bool, maxPages:Int=8) throws -> Result {
        var result=Result()
        let started=uptime()
        guard shouldContinue(),started>=nextSweepAt else {return result}
        result.attempted=true
        let limit=max(1,min(8,maxPages))
        for _ in 0..<limit {
            guard shouldContinue(),uptime()-started<0.10 else {break}
            let isQueue = !queueFinished
            let page:RetentionPage
            if isQueue {
                page=try journal.pruneCompletedQueuePage(afterID:queueCursor,now:now,shouldContinue:shouldContinue)
            } else if !receiptFinished {
                page=try journal.pruneRectificationReceiptPage(afterID:receiptCursor,now:now,shouldContinue:shouldContinue)
            } else {break}
            result.pages+=1
            if page.held {result.held=true;break}
            result.examined+=page.examined
            if isQueue {
                queueCursor=page.nextAfterID
                queueFinished=page.finished
                result.queueRemoved+=page.removed
            } else {
                receiptCursor=page.nextAfterID
                receiptFinished=page.finished
                result.receiptsRemoved+=page.removed
            }
            if queueFinished && receiptFinished {
                result.finished=true
                queueCursor=0;receiptCursor=0
                queueFinished=false;receiptFinished=false
                nextSweepAt=uptime()+3600
                break
            }
        }
        return result
    }
}
