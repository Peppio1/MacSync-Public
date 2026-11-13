import Foundation

/// Explicit permission applies to COPY and UPDATE only, never DELETE.
/// This decision model is side-effect-free and used to gate autostart.
public enum AutomaticCopyDecision: Equatable, Sendable {
    case disabled
    case monitoringNotReady
    case alreadyActive
    case missingConfiguration
    case legacyVolumeIdentity
    case waitingForDestination
    case unsafeDestination
    case ready

    public var description: String {
        switch self {
        case .disabled: return "Copie automatiche disabilitate"
        case .monitoringNotReady: return "Attendo il monitoraggio delle sorgenti"
        case .alreadyActive: return "Sessione di sincronizzazione già attiva"
        case .missingConfiguration: return "Configura almeno una coppia Sorgente/Destinazione"
        case .legacyVolumeIdentity: return "Riseleziona la destinazione per verificare l'identità del volume"
        case .waitingForDestination: return "Attendo che macOS renda disponibile la destinazione"
        case .unsafeDestination: return "Destinazione diversa dal volume autorizzato: copia sospesa"
        case .ready: return "Destinazioni pronte; avvio copie e aggiornamenti"
        }
    }
}

public struct AutomaticCopyPair: Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let expectedVolume: VolumeFingerprint?

    public init(sourcePath: String, destinationPath: String,
                expectedVolume: VolumeFingerprint?) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.expectedVolume = expectedVolume
    }
}

public enum AutomaticCopyReadiness {
    public static func evaluate(
        enabled: Bool,
        monitorRunning: Bool,
        copyActive: Bool,
        pairs: [AutomaticCopyPair],
        probe: (String, VolumeFingerprint?) -> DestinationAvailability =
            { DestinationProbe.inspect(path: $0, expectedVolume: $1) }
    ) -> AutomaticCopyDecision {
        guard enabled else { return .disabled }
        guard !copyActive else { return .alreadyActive }
        guard monitorRunning else { return .monitoringNotReady }
        let configured = pairs.filter { !$0.sourcePath.isEmpty || !$0.destinationPath.isEmpty }
        guard !configured.isEmpty,
              configured.allSatisfy({
                  !$0.sourcePath.isEmpty && !$0.destinationPath.isEmpty
              }) else { return .missingConfiguration }
        guard configured.allSatisfy({ $0.expectedVolume?.isStrongIdentity == true }) else {
            return .legacyVolumeIdentity
        }
        for pair in configured {
            let state = probe(pair.destinationPath, pair.expectedVolume)
            switch state {
            case .ready: break
            case .unavailable: return .waitingForDestination
            case .differentVolume: return .unsafeDestination
            case .notConfigured, .unverified: return .legacyVolumeIdentity
            }
        }
        return .ready
    }
}
