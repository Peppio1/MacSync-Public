import Foundation
import Darwin
import MacSyncCore

/// Finder launches the .command file in the backup. This independent binary
/// works even when the new main application no longer starts. No sudo.
do {
    guard CommandLine.arguments.count == 2 else {
        throw ApplicationRollback.Failure("Apri il file Ripristina MacSync.command nella cartella di backup.")
    }
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSync", isDirectory: true)
    let lock = try ExclusiveArchiveLock(url: root.appendingPathComponent("archive.lock"))
    try withExtendedLifetime(lock) {
        let marker = try UpdateTransactionMarker.read(from: root.appendingPathComponent("update-pending.json"))
        let snapshot = root.appendingPathComponent("update-backups", isDirectory: true)
            .appendingPathComponent(marker.snapshotName, isDirectory: true)
        let given = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard given.path == snapshot.standardizedFileURL.path,
              given.resolvingSymlinksInPath().path == snapshot.standardizedFileURL.path else {
            throw ApplicationRollback.Failure("Il backup non corrisponde alla transazione pendente.")
        }
        let manifest = try ApplicationRecoveryManifest.read(from: snapshot.appendingPathComponent("recovery.json"))
        guard manifest.marker == marker else { throw ApplicationRollback.Failure("Manifesto non corrispondente.") }
        let target = URL(fileURLWithPath: manifest.originalPath)
        let backup = snapshot.appendingPathComponent("MacSync.app")
        try ApplicationRollback.validateBundle(backup, version: marker.previousVersion)
        guard NSRunningApplicationsCheck() else {
            throw ApplicationRollback.Failure("MacSync è ancora aperto. Chiudilo prima del ripristino.")
        }
        let scratch = root.appendingPathComponent(".rollback-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let live = try ApplicationRollback.databaseDigest(root.appendingPathComponent("inventory.sqlite"), scratch: scratch)
        let saved = try ApplicationRollback.databaseDigest(snapshot.appendingPathComponent("inventory.sqlite"), scratch: scratch)
        guard live == saved else {
            throw ApplicationRollback.Failure("L’archivio è cambiato o non corrisponde al backup. Ripristino bloccato: nessun dato verrà sovrascritto.")
        }
        // If another app is at the canonical path, don't overwrite it.
        if FileManager.default.fileExists(atPath: target.path) {
            let info = try? Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
            if let info, let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any] {
                guard plist["CFBundleIdentifier"] as? String == "com.macsync.prototype" else {
                    throw ApplicationRollback.Failure("Applicazione diversa nella destinazione.")
                }
            } else {
                throw ApplicationRollback.Failure("Identità dell’applicazione danneggiata non verificabile. Richiesto recupero manuale.")
            }
        }
        print("Ripristino MacSync \(marker.previousVersion) in \(target.path).")
        print("Database e preferenze NON verranno sostituiti. La versione attuale verrà conservata.")
        print("Prima di continuare assicurati che sia terminata anche la finestra di installazione Sparkle.")
        print("Scrivi RIPRISTINA per confermare:")
        guard readLine() == "RIPRISTINA" else { print("Annullato."); return }
        guard NSRunningApplicationsCheck() else { throw ApplicationRollback.Failure("MacSync è aperto.") }
        let preserved = try ApplicationRollback.replaceApplication(target: target, backup: backup) {
            try ApplicationRollback.validateBundle($0, version: marker.previousVersion)
        }
        print("Ripristino applicazione completato. Cartella di recupero: \(preserved.path)")
        print("Riapri MacSync da Applicazioni e verifica le impostazioni. Il marcatore resta fino alla validazione di avvio.")
    }
} catch {
    FileHandle.standardError.write(Data(("Ripristino bloccato: " + error.localizedDescription + "\n").utf8))
    exit(1)
}

import AppKit
func NSRunningApplicationsCheck() -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.macsync.prototype").isEmpty
}
