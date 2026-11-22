import Foundation
import Darwin

/// Copies only the current job to an unpublished UUID staging path.
/// The caller owns publication, journal acknowledgment and cleanup.
public enum StageTransferEngine {
    case native
    case rclone(URL)
    case rcloneDirect(URL)
    var isDirect: Bool { if case .rcloneDirect = self { return true }; return false }
    public var diagnosticName: String {
        switch self { case .native: return "native"; case .rclone: return "rclone-staging"; case .rcloneDirect: return "rclone-direct" }
    }

    /// Internal rollback switch, intentionally not a user preference.
    public static func applicationDefault() -> StageTransferEngine {
        if ProcessInfo.processInfo.environment["MACSYNC_INTERNAL_TRANSFER_ENGINE"] == "native" {
            return .native
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone")
        if ProcessInfo.processInfo.environment["MACSYNC_INTERNAL_TRANSFER_ENGINE"] == "staging" { return .rclone(helper) }
        return .rcloneDirect(helper)
    }

    static func arguments(source: URL, staging: URL) -> [String] {
        ["copyto", "--config", "/dev/null", "--inplace", "--no-traverse",
         "--ignore-times", "--retries", "1", "--low-level-retries", "1",
         "--multi-thread-streams", "0", "--local-no-clone", "--buffer-size", "16Mi",
         "--use-json-log", "--stats", "1s", "--stats-log-level", "INFO",
         "--log-level", "INFO", "--", source.path, staging.path]
    }

    func copy(source: URL, staging: URL, shouldContinue: () -> Bool,
              progress: (Int64, Double) -> Void) throws {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        switch self {
        case .native:
            try FileManager.default.copyItem(at: source, to: staging)
        case .rcloneDirect: throw MountedCopyError.invalidMapping
        case .rclone(let executable):
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw MountedCopyError.rcloneUnavailable
            }
            var sourceStat = stat()
            guard lstat(source.path, &sourceStat) == 0,
                  sourceStat.st_mode & S_IFMT == S_IFREG,
                  staging.deletingLastPathComponent().lastPathComponent == ".macsync-staging",
                  staging.pathExtension == "partial",
                  UUID(uuidString: staging.deletingPathExtension().lastPathComponent) != nil else {
                throw MountedCopyError.unsafeFile
            }
            var targetStat = stat()
            guard lstat(staging.path, &targetStat) != 0, errno == ENOENT else {
                throw MountedCopyError.unsafeFile
            }
            try Self.run(executable:executable,arguments:Self.arguments(source:source,staging:staging),shouldContinue:shouldContinue,progress:progress)
        }
    }

    static func directArguments(source: URL, destination: URL, newFile: Bool) -> [String] {
        var args = ["copyto","--config","/dev/null","--no-traverse","--ignore-times",
                    "--retries","1","--low-level-retries","1","--multi-thread-streams","0",
                    "--local-no-clone","--buffer-size","16Mi","--use-json-log","--stats","1s",
                    "--stats-log-level","INFO","--log-level","INFO"]
        if newFile { args.append("--immutable") }
        return args + ["--",source.path,destination.path]
    }

    func copyDirect(source: URL, destination: URL, newFile: Bool, shouldContinue: () -> Bool,
                    diagnostic: (SyncLogLevel,String) -> Void = { _,_ in },
                    launched: () -> Void = {},
                    progress: (Int64, Double) -> Void) throws {
        guard case .rcloneDirect(let executable) = self else { throw MountedCopyError.invalidMapping }
        try Self.run(executable:executable,arguments:Self.directArguments(source:source,destination:destination,newFile:newFile),shouldContinue:shouldContinue,diagnostic:diagnostic,launched:launched,progress:progress)
    }

    // Exact paths only; no recursive or source deletion commands.
    func pathOperation(_ verb: String, url: URL, shouldContinue: () -> Bool, diagnostic: (SyncLogLevel,String) -> Void = { _,_ in }) throws {
        guard case .rcloneDirect(let executable) = self,
              ["mkdir","deletefile","rmdir"].contains(verb) else { throw MountedCopyError.invalidMapping }
        try Self.run(executable:executable,arguments:[verb,"--config","/dev/null","--retries","1","--low-level-retries","1","--use-json-log","--log-level","INFO","--",url.path],shouldContinue:shouldContinue,diagnostic:diagnostic,progress:{ _,_ in })
    }

    private static func run(executable: URL, arguments: [String], shouldContinue: () -> Bool,
                            diagnostic: (SyncLogLevel,String) -> Void = { _,_ in },
                            launched: () -> Void = {},
                            progress: (Int64, Double) -> Void) throws {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw MountedCopyError.rcloneUnavailable }
        let process = Process()
        process.executableURL = executable
        let verbosity = TechnicalLogVerbosity.current
        var args=arguments
        if verbosity == .debug, let i=args.firstIndex(of:"--log-level"), args.indices.contains(i+1) { args[i+1]="DEBUG" }
        process.arguments = args
        // No inherited RCLONE_* settings, remotes, credentials or shell.
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let output = Pipe()
        process.standardError = output
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw MountedCopyError.rcloneLaunchFailed }
        launched()
        var pending = Data()
        var cancelled = false
        var seen:[String:Int]=[:]
        var lastStats:(Int64,Double)?
        let reader = output.fileHandleForReading
        defer { try? reader.close() }
        // Poll stderr instead of blocking in availableData when a silent
        // Rclone process is stalled on SMB. Cancellation is checked every
        // 100 ms independently of logging, and no remote operation is
        // acknowledged here: the caller keeps uncertain jobs pending.
        // Drain stderr on this worker; never expose raw output or credentials.
        let descriptor = reader.fileDescriptor
        var reachedEOF = false
        var cancellationStarted: TimeInterval?
        var sentKill = false
        while true {
            if !shouldContinue() && !cancelled {
                cancelled = true
                cancellationStarted = ProcessInfo.processInfo.systemUptime
                if process.isRunning { process.terminate() }
            }
            // SIGTERM may be ignored by a stalled subprocess. Escalate only
            // for this dedicated Rclone process, never the protected SMB
            // rename helper; the worker still reports cancellation, not success.
            if cancelled && !sentKill && process.isRunning,
               let started = cancellationStarted,
               ProcessInfo.processInfo.systemUptime - started >= 2.0 {
                sentKill = true
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            var pollFD = pollfd(fd: descriptor,
                                events: Int16(POLLIN | POLLHUP | POLLERR),
                                revents: 0)
            let ready = Darwin.poll(&pollFD, 1, process.isRunning ? 100 : 0)
            if ready < 0 {
                if errno == EINTR { continue }
                // A polling error is not proof that Rclone has stopped.
                // Keep rechecking its lifetime rather than blocking forever
                // in waitUntilExit; the cancellation grace period still applies.
                if !cancelled {
                    cancelled = true
                    cancellationStarted = ProcessInfo.processInfo.systemUptime
                    if process.isRunning { process.terminate() }
                }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if ready > 0 && !reachedEOF &&
               (pollFD.revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                // Only read when poll indicates available data or EOF.
                let chunk = reader.availableData
                if chunk.isEmpty {
                    reachedEOF = true
                } else {
                    pending.append(chunk)
                    while let index = pending.firstIndex(of: 10) {
                        let line = Data(pending.prefix(upTo: index))
                        pending.removeSubrange(pending.startIndex...index)
                        if let sample = Self.parseStats(line) { lastStats=sample; progress(sample.0, sample.1) }
                        if let event = Self.classifyDiagnostic(line,verbosity:verbosity) {
                            let key=event.0.rawValue+"|"+event.1
                            seen[key,default:0]+=1
                            if seen[key]==1 { diagnostic(event.0,event.1) }
                        }
                    }
                    if pending.count > 262144 { pending.removeAll(keepingCapacity: false) }
                }
            }
            if !process.isRunning && (reachedEOF || ready == 0) { break }
            if reachedEOF && process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        }
        process.waitUntilExit()
        for (key,count) in seen.sorted(by:{$0.key<$1.key}) where count>1 {
            let parts=key.split(separator:"|",maxSplits:1)
            if parts.count==2, let level=SyncLogLevel(rawValue:String(parts[0])) {
                diagnostic(level,String(parts[1])+" — ripetizioni aggiuntive: "+String(count-1))
            }
        }
        if verbosity != .normal, let sample=lastStats {
            diagnostic(.info,String(format:"Rclone: %lld byte in %.3f s",sample.0,sample.1))
        }
        if process.terminationStatus != 0 { diagnostic(.error,"Rclone: exit code "+String(process.terminationStatus)) }
        else if verbosity != .normal { diagnostic(.success,"Rclone: exit code 0") }
        if cancelled || !shouldContinue() { throw SeedVerificationError.cancelled }
        guard process.terminationStatus == 0 else {
            throw MountedCopyError.rcloneFailed(process.terminationStatus)
        }
    }

    // Only fixed classifications derived from Rclone's JSON; never persist
    // msg/object/URLs or arbitrary strings from subprocess output.
    static func classifyDiagnostic(_ data:Data,verbosity:TechnicalLogVerbosity) -> (SyncLogLevel,String)? {
        guard let item=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let msg=item["msg"] as? String,let raw=item["level"] as? String else { return nil }
        let s=msg.lowercased()
        if ["error","fatal","critical","warning","warn"].contains(raw.lowercased()) {
            let level:SyncLogLevel = ["warning","warn"].contains(raw.lowercased()) ? .warning : .error
            let rules:[(String,String)]=[
                ("operation not supported","operazione non supportata"),("permission denied","permessi insufficienti"),
                ("access denied","accesso negato"),("input/output error","errore I/O"),
                ("no space left","spazio esaurito"),("connection reset","connessione interrotta"),
                ("broken pipe","connessione interrotta"),("timed out","timeout"),("i/o timeout","timeout"),
                ("partial file rename failed","rinomina del temporaneo fallita"),
                ("corrupted on transfer","verifica integrità fallita"),("immutable","destinazione già esistente / immutabile"),
                ("file not found","file non trovato"),("no such file","percorso non trovato"),
                ("directory not empty","cartella non vuota")
            ]
            let reason=rules.first(where:{s.contains($0.0)})?.1 ?? "causa non classificata"
            return (level,"Rclone: "+reason)
        }
        if verbosity != .normal {
            if s.contains("copied (") { return (.success,"Rclone: copia completata") }
            if s.contains("renamed to:") { return (.success,"Rclone: rinomina completata") }
            if s.contains("deleted") { return (.success,"Rclone: cancellazione eseguita") }
        }
        if verbosity == .debug {
            if s.contains("sizes differ") { return (.info,"Rclone: dimensioni diverse") }
            if s.contains("hash") { return (.info,"Rclone: controllo hash") }
            if s.contains("need to transfer") { return (.info,"Rclone: trasferimento necessario") }
        }
        return nil
    }

    static func parseStats(_ data: Data) -> (Int64, Double)? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stats = message["stats"] as? [String: Any],
              let bytes = stats["bytes"] as? NSNumber,
              let elapsed = stats["elapsedTime"] as? NSNumber,
              bytes.int64Value >= 0, elapsed.doubleValue.isFinite, elapsed.doubleValue > 0 else { return nil }
        return (bytes.int64Value, elapsed.doubleValue)
    }
}
