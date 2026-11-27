import AppKit
import MacSyncCore

@MainActor
enum NameRectificationPrompt {
    static func present(items:[IncompatibleName],decision:NamePromptDecision,sourceRoots:[String:String],previewCapture:((NSWindow)->Void)? = nil) {
        guard decision.answer == nil else { return }
        // Do not nest unrelated confirmation modals (e.g. an update).
        guard NSApp.modalWindow == nil else { decision.skip(); return }
        let alert=NSAlert()
        alert.alertStyle = .warning
        alert.messageText="Rettifica nomi incompatibili"
        alert.informativeText="\(items.count) elementi in attesa. Verranno rinominati solo nelle sorgenti locali. Annulla per sincronizzare gli altri elementi."
        alert.addButton(withTitle:"Rettifica e prosegui")
        alert.addButton(withTitle:"Annulla rettifica")
        alert.buttons.first?.isEnabled=items.contains{ NameRectification.proposedName($0.name) != nil }
        alert.buttons.first?.keyEquivalent=""
        alert.buttons.last?.keyEquivalent="\u{1b}"
        let text=NSMutableAttributedString(string:"")
        let normal=[NSAttributedString.Key.font:NSFont.systemFont(ofSize:12),
                    .foregroundColor:NSColor.labelColor]
        let emphasized=[NSAttributedString.Key.font:NSFont.boldSystemFont(ofSize:14),
                        .foregroundColor:NSColor.labelColor]
        for (index,row) in items.enumerated() {
            text.append(NSAttributedString(string:row.displayName+"\n",attributes:emphasized))
            let proposed=NameRectification.proposedName(row.name) ?? "Correzione manuale necessaria"
            text.append(NSAttributedString(string:"Nome proposto: "+proposed+"\n",attributes:emphasized))
            let detail=(row.isDirectory ? "Cartella · \(row.affectedDescendants) elementi contenuti" : "File")+" · "+row.reason
            let path=ArchivePathPresentation(root:row.rootPath,relative:row.relativePath,side:row.side == .source ? .source:.destination,kind:.init(row.objectKind))
            text.append(NSAttributedString(string:detail+"\n"+path.lines.joined(separator:"\n")+"\n",attributes:normal))
            if row.side == .source, sourceRoots[row.rootID] != nil,
               let link=URL(string:"macsync-finder://item/\(index)") {
                text.append(NSAttributedString(string:"Apri in Finder",attributes:[.link:link,.font:NSFont.systemFont(ofSize:12)]))
            }
            text.append(NSAttributedString(string:"\n\n",attributes:normal))
        }
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:510,height:270))
        scroll.hasVerticalScroller=true; scroll.borderType = .bezelBorder
        let view=NSTextView(frame:scroll.bounds)
        view.isEditable=false; view.isSelectable=true
        view.autoresizingMask=[.width]
        view.isVerticallyResizable=true
        view.textContainer?.widthTracksTextView=true
        view.textStorage?.setAttributedString(text)
        scroll.documentView=view
        let countdown=NSTextField(labelWithString:"Annullamento automatico tra \(decision.remaining) s")
        countdown.font = .monospacedDigitSystemFont(ofSize:13,weight:.medium)
        let status=NSTextField(labelWithString:"")
        status.font = .systemFont(ofSize:11)
        let finder=PromptFinderDelegate(items:items,sourceRoots:sourceRoots,alert:alert,decision:decision,status:status)
        view.delegate=finder
        let stack=NSStackView(views:[scroll,countdown,status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=8
        stack.frame=NSRect(x:0,y:0,width:510,height:324)
        scroll.widthAnchor.constraint(equalToConstant:510).isActive=true
        scroll.heightAnchor.constraint(equalToConstant:270).isActive=true
        alert.accessoryView=stack
        if let previewCapture {
            alert.layout()
            previewCapture(alert.window)
            alert.window.orderOut(nil)
            return
        }
        let timer=Timer(timeInterval:0.1,repeats:true) { _ in
            // AppKit invokes this timer on the main modal run loop.
            MainActor.assumeIsolated {
                countdown.stringValue="Annullamento automatico tra \(decision.remaining) s"
                if decision.answer != nil && NSApp.modalWindow === alert.window {
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer,forMode:.common)
        RunLoop.main.add(timer,forMode:.modalPanel)
        defer { withExtendedLifetime(finder) {}; timer.invalidate(); alert.window.orderOut(nil) }
        guard decision.answer == nil else { return }
        let response=alert.runModal()
        if response == .alertFirstButtonReturn { decision.confirm() }
        else { decision.skip() }
    }
}


/// The modal already owns a frozen source snapshot and its existing
/// countdown. Finder lookup is asynchronous and never extends that deadline.
@MainActor
private final class PromptFinderDelegate:NSObject,NSTextViewDelegate {
    let items:[IncompatibleName]
    let sourceRoots:[String:String]
    weak var alert:NSAlert?
    let decision:NamePromptDecision
    let status:NSTextField
    private var busy=false
    init(items:[IncompatibleName],sourceRoots:[String:String],alert:NSAlert,decision:NamePromptDecision,status:NSTextField) {
        self.items=items;self.sourceRoots=sourceRoots;self.alert=alert;self.decision=decision;self.status=status
    }
    func textView(_ textView:NSTextView,clickedOnLink link:Any,at charIndex:Int)->Bool {
        guard let url=link as? URL,url.scheme=="macsync-finder",url.host=="item",
              let index=Int(url.lastPathComponent),items.indices.contains(index),!busy,
              decision.answer==nil else { return true }
        let item=items[index]
        guard item.side == .source,let configured=sourceRoots[item.rootID] else { return true }
        busy=true
        status.stringValue="Verifica percorso…"
        Task { @MainActor in
            defer { busy=false }
            do {
                let found=try await Task.detached(priority:.utility) {
                    let root=URL(fileURLWithPath:configured,isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
                    guard root.path==item.rootPath else { throw MountedCopyError.invalidMapping }
                    let path=ArchivePathPresentation(root:item.rootPath,relative:item.relativePath,side:.source,kind:.init(item.objectKind))
                    return try ArchiveRevealTarget.resolve(path,expectedVolume:nil)
                }.value
                guard decision.answer==nil,let alert,NSApp.modalWindow === alert.window else { return }
                if found.exact { NSWorkspace.shared.activateFileViewerSelecting([found.url]);status.stringValue="" }
                else { NSWorkspace.shared.open(found.url);status.stringValue="Elemento non disponibile: aperta la cartella verificata." }
            } catch {
                guard decision.answer==nil else { return }
                status.stringValue="Percorso non disponibile o non verificabile."
            }
        }
        return true
    }
}
