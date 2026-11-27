import AppKit
import SwiftUI
import MacSyncCore

/// Same labels, line wrapping and display-only escaping in every expanded path.
struct ArchivePathBlock: View {
    let path: ArchivePathPresentation
    var currentRoot=false
    var body: some View {
        VStack(alignment:.leading,spacing:3) {
            line(path.side.label+(currentRoot ? " attuale" : ""),path.rootDisplay,emphasis:false)
            line("Cartella",path.folder,emphasis:path.kind == .directory)
            if let leaf=path.leaf { line(path.leafLabel,leaf,emphasis:true) }
        }.frame(maxWidth:.infinity,alignment:.leading)
            .help(path.originalFullPath)
    }
    private func line(_ label:String,_ value:String,emphasis:Bool)->some View {
        HStack(alignment:.top,spacing:8) {
            Text(label+":").font(.caption).foregroundStyle(.secondary).frame(width:92,alignment:.leading)
            Text(value).font(emphasis ? .subheadline.weight(.semibold) : .caption)
                .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                .frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

@MainActor
struct ArchiveFinderButton: View {
    let path:ArchivePathPresentation
    let rootID:String
    let model:MacSyncViewModel
    var label="Apri in Finder"
    var disabled=false
    @State private var busy=false
    @State private var message=""
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            Button { reveal() } label: { Label(label,systemImage:"folder") }
                .disabled(disabled || busy || path.root.isEmpty || path.side == .unknown || path.relative.isEmpty)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
        }
    }
    private func reveal() {
        guard let pair=model.configuredPairs().first(where:{$0.id==rootID}),
              (path.side == .destination ? pair.destination : pair.path)==path.root else {
            message="Configurazione cambiata: percorso non aperto.";return
        }
        let expected=pair.expected
        let request=path
        busy=true;message=""
        Task { @MainActor in
            defer { busy=false }
            do {
                let found=try await Task.detached(priority:.utility) {
                    try ArchiveRevealTarget.resolve(request,expectedVolume:expected)
                }.value
                guard let current=model.configuredPairs().first(where:{$0.id==rootID}),
                      (request.side == .destination ? current.destination : current.path)==request.root,
                      current.expected==expected else {
                    message="Configurazione cambiata: percorso non aperto.";return
                }
                if found.exact { NSWorkspace.shared.activateFileViewerSelecting([found.url]) }
                else {
                    NSWorkspace.shared.open(found.url)
                    message="Elemento non disponibile con il nome esatto: aperta la cartella verificata."
                }
            } catch {
                message="Percorso non disponibile o non verificabile; nessuna apertura."
            }
        }
    }
}
