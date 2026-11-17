import Foundation
import Darwin
import AppKit
import MacSyncCore

/// Independent binary launched from the verified snapshot, no sudo.
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
