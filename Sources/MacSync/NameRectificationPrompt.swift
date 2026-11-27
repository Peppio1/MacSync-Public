import AppKit
import MacSyncCore

@MainActor
enum NameRectificationPrompt {
    static func present(items:[IncompatibleName],decision:NamePromptDecision) {
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
        for row in items {
            text.append(NSAttributedString(string:row.displayName+"\n",attributes:emphasized))
            let proposed=NameRectification.proposedName(row.name) ?? "Correzione manuale necessaria"
            text.append(NSAttributedString(string:"Nome proposto: "+proposed+"\n",attributes:emphasized))
            let detail=(row.isDirectory ? "Cartella · \(row.affectedDescendants) elementi contenuti" : "File")+" · "+row.reason
            let path=ArchivePathPresentation(root:row.rootPath,relative:row.relativePath,side:row.side == .source ? .source:.destination,kind:.init(row.objectKind))
            text.append(NSAttributedString(string:detail+"\n"+path.lines.joined(separator:"\n")+"\n\n",attributes:normal))
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
        let stack=NSStackView(views:[scroll,countdown])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=8
        stack.frame=NSRect(x:0,y:0,width:510,height:300)
        scroll.widthAnchor.constraint(equalToConstant:510).isActive=true
        scroll.heightAnchor.constraint(equalToConstant:270).isActive=true
        alert.accessoryView=stack
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
        defer { timer.invalidate(); alert.window.orderOut(nil) }
        guard decision.answer == nil else { return }
        let response=alert.runModal()
        if response == .alertFirstButtonReturn { decision.confirm() }
        else { decision.skip() }
    }
}
