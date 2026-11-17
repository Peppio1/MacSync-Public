# MacSync v0.17.0 — installazione e distribuzione

## Download ufficiale

[Installer DMG v0.17.0](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.dmg) · [SHA-256](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.dmg.sha256) · [ZIP alternativo](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.zip) · [GitHub Releases](https://github.com/Peppio1/MacSync-Public/releases/tag/v0.17.0).

Pre-release pubblicata, non notarizzata, destinata al collaudo su Mac fisico. Non avviare ancora una sincronizzazione su dati aziendali reali.

## Pacchetti
- ZIP universale (Sparkle usa esclusivamente il ZIP firmato per gli aggiornamenti).
- DMG compresso read-only: MacSync.app, link Applicazioni, guida HTML illustrata offline e fondo grafico con indicazione drag-and-drop. Il DMG non installa servizi server, non richiede script privilegiati e non modifica archivi esistenti.
- Risorse .icns 16–1024 px, PNG a trasparenza per sidebar, template monocromatico a 18 pt per menu bar. Il tema del sistema colora il template.

La guida HTML si apre dal volume montato; è inclusa anche in Contents/Resources. Le illustrazioni sono schemi e non catture di macOS. L'utente deve trascinare l'app in Applicazioni, espellere il DMG ed eseguire il collaudo. Non avviare MacSync dal volume di installazione. App firmata ad hoc, non notarizzata; verificare SHA-256 e autorizzare la singola app soltanto se riconosciuta. Mai disabilitare Gatekeeper globalmente.

## CI e gate
Il codice riparte dalla v0.16.0 validata (commit e6ace65, run 44068276632). Backup Git: rollback-v0.16.0-validated-before-v0.17.0. La CI genera risorse, controlla iconset, compila app + helper per entrambe le architetture, verifica bundle e ZIP, crea DMG e verifica montaggio read-only, symlink, guida, firma e uguaglianza dei binari. Ripete i tre scenari Sparkle 0.17.0 → 0.17.1 su fixture effimere e 48 immagini UI.

Il PNG originale approvato deve essere presente con l'hash indicato in Packaging/Branding/README.md. Prima compilazione senza asset: placeholder esplicito, nessun accesso al secret. Con originale esatto e CI verde, la firma può essere richiesta con commit contenente [verify-signing-key] oppure workflow_dispatch sign_candidate. Produce ZIP e feed Ed25519, DMG con SHA-256 e provenance, senza pubblicare. Non abilitare release stabile. Rimangono verifica visiva Finder su Mac fisico, Gatekeeper, SMB/VPN, menu bar reale e aggiornamento durante operazioni attive.

## Correzione DMG
Il run 44071544699 ha completato test, compilazione universale e creazione/montaggio DMG, ma codesign ha rifiutato il bundle montato per Finder information/resource fork. Rimossa la proprietà hide_extensions dal bundle .app (rimane solo per la guida). Nessun allentamento dei controlli: verifica --deep --strict --all-architectures sul volume read-only, diagnostica xattr in caso di errore. PNG originale caricato nel ramo main; hash e risoluzione verificati dalla CI prima di autorizzare la firma protetta. Correzione verificata: [run 44072456998](https://github.com/Peppio1/MacSync-Public/actions/runs/44072456998) con successo, incluso codesign sul volume DMG read-only, originale approvato, 48 anteprime e firma Ed25519. [Run di pubblicazione 44074982577](https://github.com/Peppio1/MacSync-Public/actions/runs/44074982577) completato, 8 asset pubblici; nessun nuovo build. Resta il collaudo fisico.
