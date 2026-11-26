import Foundation
import MacSyncCore

/// Observes main-queue delivery, not frame rendering or OS input latency.
/// All mutable state belongs to the utility lane. At most one heartbeat
/// awaits the main queue; bounded distributions are flushed off-main.
final class UIResponsivenessProbe: @unchecked Sendable {
    private let lane=DispatchQueue(label:"macsync.diagnostic.ui",qos:.utility)
    private var timer:DispatchSourceTimer?
    private var running=false
    private var pending=false
    private var databasePath:String?
    private var stats:[String:DiagnosticTiming]=[:]
    private var lastFlush:Double=0
    private var lastHeartbeat:Double=0
    private var lastPrune:Double = -3600
    private var resourceBaseline:DiagnosticResourceCounters?
    private var resourceSamples:[DiagnosticResourceSample]=[]
    private var droppedResourceSamples=0
    private var generation=0

    func start(path:String) {
        lane.async { [weak self] in
            guard let self,!self.running else { return }
            self.running=true
            self.generation+=1
            self.databasePath=path
            self.lastFlush=ProcessInfo.processInfo.systemUptime
            self.resourceBaseline=DiagnosticResourceCounters.read()
            let timer=DispatchSource.makeTimerSource(queue:self.lane)
            timer.schedule(deadline:.now()+1,repeating:.seconds(1),leeway:.milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer=timer
            timer.resume()
        }
    }

    private func tick() {
        guard running else { return }
        let now=ProcessInfo.processInfo.systemUptime
        let level=DiagnosticCollectionLevel.current
        if now-lastFlush>=level.flushInterval { sampleResources();flush();lastFlush=now }
        guard !pending,now-lastHeartbeat>=level.heartbeatInterval else { return }
        lastHeartbeat=now
        pending=true
        let epoch=generation
        let sent=ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            let elapsed=ProcessInfo.processInfo.systemUptime-sent
            guard let self else { return }
            self.lane.async { [weak self] in
                guard let self,self.running,self.generation==epoch else { return }
                self.pending=false
                self.stats["metric_ui_main_queue_delay",default:DiagnosticTiming()].observe(elapsed)
            }
        }
    }

    /// Fixed action identifiers only. No filenames, query text or input data.
    func record(_ action:String,seconds:Double) {
        guard DiagnosticTiming.uiActions.contains(action) else { return }
        lane.async { [weak self] in
            guard let self,self.running else { return }
            self.stats[action,default:DiagnosticTiming()].observe(seconds)
        }
    }

    private func sampleResources() {
        guard let next=DiagnosticResourceCounters.read() else { return }
        if let previous=resourceBaseline,let sample=DiagnosticResourceSample.between(previous,next) {
            if resourceSamples.count>=4 {
                resourceSamples.removeFirst()
                droppedResourceSamples=min(Int.max-1,droppedResourceSamples+1)
            }
            resourceSamples.append(sample)
        }
        resourceBaseline=next
    }

    private func flush() {
        let now=ProcessInfo.processInfo.systemUptime
        let shouldPrune=now-lastPrune>=3600
        guard shouldPrune || !stats.isEmpty || !resourceSamples.isEmpty || droppedResourceSamples>0,
              let path=databasePath,
              FileManager.default.fileExists(atPath:path),
              let writer=try? SyncActivityLog(path:path) else { return }
        if shouldPrune {
            if (try? writer.pruneDiagnostics(maxAgeDays:DiagnosticCollectionLevel.retentionDays)) != nil { lastPrune=now }
        }
        // Bound failures: never accumulate an unbounded backlog.
        while let sample=resourceSamples.first,
              let data=try? JSONEncoder().encode(sample) {
            do {
                try writer.record(level:.info,rootID:"app",action:DiagnosticResourceSample.action,
                    durationSeconds:sample.intervalSeconds,message:String(decoding:data,as:UTF8.self))
                resourceSamples.removeFirst()
            } catch { break }
        }
        if droppedResourceSamples>0 {
            do {
                try writer.record(level:.warning,rootID:"app",action:"metric_resource_samples_dropped",
                    message:String(droppedResourceSamples))
                droppedResourceSamples=0
            } catch {}
        }
        for (action,timing) in stats {
            guard let data=try? JSONEncoder().encode(timing) else { continue }
            do {
                try writer.record(level:.info,rootID:"app",action:DiagnosticTiming.prefix+action,
                    durationSeconds:timing.totalSeconds,message:String(decoding:data,as:UTF8.self))
                stats.removeValue(forKey:action)
            } catch { /* Retain bounded aggregates for the next flush. */ }
        }
    }

    /// Include buffered diagnostics before user-initiated export.
    func flushForExport(completion:@escaping @MainActor ()->Void) {
        lane.async { [weak self] in
            if let self,self.running {
                self.sampleResources()
                self.flush()
                self.lastFlush=ProcessInfo.processInfo.systemUptime
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Quiesce before update/reset snapshots; no SQLite writes afterward.
    func stop(completion:@escaping @MainActor ()->Void) {
        lane.async { [weak self] in
            if let self {
                self.running=false
                self.generation+=1
                self.pending=false
                self.timer?.cancel()
                self.timer=nil
                self.sampleResources()
                self.flush()
                self.resourceBaseline=nil
            }
            DispatchQueue.main.async { completion() }
        }
    }
    deinit { timer?.cancel() }
}
