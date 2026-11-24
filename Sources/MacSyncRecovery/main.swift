import Foundation
import Darwin
import AppKit
import MacSyncCore

/// Independent binary launched from the verified snapshot, no sudo.
if CommandLine.arguments.count==5,CommandLine.arguments[1]=="--signed-rollback" {
    do {
        guard let parent=Int32(CommandLine.arguments[4]),parent>1,parent != getpid() else {
            throw ApplicationRollback.Failure("Processo di origine non valido.")
        }
        let deadline=ProcessInfo.processInfo.systemUptime+45
        while kill(parent,0)==0 || errno != ESRCH {
            guard ProcessInfo.processInfo.systemUptime<deadline else {
                throw ApplicationRollback.Failure("MacSync non si è chiuso. Nessun rollback eseguito.")
            }
            Thread.sleep(forTimeInterval:0.2)
        }
        let root=FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacSync",isDirectory:true)
        let snapshot=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let target=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
        func installStopped() throws {
            let lock=try ExclusiveArchiveLock(url:root.appendingPathComponent("archive.lock"))
            try withExtendedLifetime(lock) {
                guard NSRunningApplication.runningApplications(withBundleIdentifier:"com.macsync.prototype").allSatisfy({$0.processIdentifier==getpid()}) else {
                    throw ApplicationRollback.Failure("MacSync è ancora aperto.")
                }
                guard let defaults=UserDefaults(suiteName:"com.macsync.prototype") else {
                    throw ApplicationRollback.Failure("Preferenze MacSync non accessibili.")
                }
                try SignedRollbackTransaction.install(root:root,snapshot:snapshot,target:target,defaults:defaults)
            }
        }
        try installStopped()
        let launch=Process()
        launch.executableURL=URL(fileURLWithPath:"/usr/bin/open")
        launch.arguments=["-n",target.path]
        try launch.run();launch.waitUntilExit()
        guard launch.terminationStatus==0 else {
            throw ApplicationRollback.Failure("Ripristino completato; apri MacSync da Applicazioni.")
        }
        exit(0)
    } catch {
        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert=NSAlert()
        alert.alertStyle = .warning
        alert.messageText="Ripristino MacSync"
        alert.informativeText=error.localizedDescription+"\n\nL’archivio corrente non è stato sostituito. Apri MacSync da Applicazioni."
        app.activate(ignoringOtherApps:true)
        alert.runModal()
        exit(1)
    }
}

/// Production trust and installed path checks cannot be overridden by arguments.
do {
    guard CommandLine.arguments.count == 2 else {
        throw ApplicationRollback.Failure("Apri Ripristina MacSync.command nella cartella di backup.")
    }
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSync", isDirectory: true)
    let lock = try ExclusiveArchiveLock(url: root.appendingPathComponent("archive.lock"))
    try withExtendedLifetime(lock) {
        let coordinator = UpdateRecoveryCoordinator(root: root)
        let given = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let preserved = try coordinator.recover(from: given, isStopped: {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.macsync.prototype").isEmpty
        }, confirm: { pending in
            print("Ripristino MacSync \(pending.marker.previousVersion) in \(pending.target.path).")
            print("Database e preferenze NON verranno sostituiti. La versione attuale verrà conservata.")
            print("Assicurati che sia terminato anche l’installatore Sparkle.")
            print("Scrivi RIPRISTINA per confermare:")
            return readLine() == "RIPRISTINA"
        })
        if let preserved {
            print("Ripristino completato. Cartella di recupero: \(preserved.path)")
            print("Riapri MacSync da Applicazioni. Il marcatore resta fino alla validazione di avvio.")
        } else { print("Annullato.") }
    }
} catch {
    FileHandle.standardError.write(Data(("Ripristino bloccato: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
