import AppKit

/// The first click is a request for confirmation, never permission to
/// suspend work, create backups, download packages or launch a helper.
@MainActor
enum RollbackConfirmation {
    static func make(installed:String,previous:String)->NSAlert {
        let alert=NSAlert()
        alert.alertStyle = .warning
        alert.messageText="Confermi il ripristino di MacSync?"
        alert.informativeText="Versione attuale: "+installed+"\nVersione da ripristinare: "+previous+"\n\nSolo dopo la conferma MacSync terminerà le attività, creerà un backup e verificherà il pacchetto firmato. Il database attuale verrà conservato. Eventuali cancellazioni ancora protette saranno conservate nel backup e archiviate fuori dalla coda attiva: non verranno rieseguite automaticamente dalla versione precedente. L’applicazione verrà chiusa e, al riavvio, copie automatiche e mirror resteranno disattivati.\n\nAnnulla per continuare a utilizzare la versione attuale."
        let cancel=alert.addButton(withTitle:"Annulla")
        let confirm=alert.addButton(withTitle:"Ripristina "+previous)
        // Escape cancels. Return cannot select the destructive action.
        cancel.keyEquivalent="\u{1b}"
        confirm.keyEquivalent=""
        return alert
    }
    static func isConfirmed(_ response:NSApplication.ModalResponse)->Bool {
        response == .alertSecondButtonReturn
    }
}
