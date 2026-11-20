import Foundation

/// A confirmed reset is completed at startup under the archive lock and
/// before any component opens the database or reads the app's preferences.
public enum FactoryReset {
    private static let markerName = "factory-reset.pending"
    private static let lockName = "archive.lock"

    public static func schedule(in directory: URL, configuredPaths: [String]) throws {
        let normalized = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard normalized.path == directory.standardizedFileURL.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for path in configuredPaths where !path.isEmpty {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path != normalized.path, !candidate.path.hasPrefix(normalized.path + "/") else {
                throw JournalError.database("Una cartella sincronizzata è nell’area dati di MacSync. Spostala prima di azzerare il programma.")
            }
        }
        try Data().write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    public static func completeIfScheduled(in directory: URL, clearPreferences: () throws -> Void) throws {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(markerName)
        guard fm.fileExists(atPath: marker.path) else { return }
        guard directory.standardizedFileURL.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard item.lastPathComponent != markerName, item.lastPathComponent != lockName else { continue }
            try fm.removeItem(at: item)
        }
        try clearPreferences()
        try fm.removeItem(at: marker)
    }
}
