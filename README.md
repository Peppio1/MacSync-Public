# MacSync

Applicazione macOS per la futura **sincronizzazione unidirezionale iMac → Windows Server 2016**, tramite condivisione SMB già disponibile su VPN.

> **Stato: prototipo v0.2 con monitoraggio LOCALE. Non è una versione di produzione. Nessun trasferimento SMB o cancellazione sul server è attivo.**

## Requisiti
- Solo software sull'iMac, nessuna installazione sul server.
- Gratuito anche in ambito commerciale.
- Due cartelle sorgenti configurabili: Cartella_1 e Cartella_2.
- Destinazione: sottocartelle omonime di Condivisione_SMB su Windows Server.
- Replica di aggiunte, modifiche, rinomine e **cancellazioni**, dopo i test del motore remoto.
- Obiettivo sincronizzazione ogni circa 5 minuti senza scansione SMB completa a ogni ciclo.
- SQLite persistente e FSEvents per il monitoraggio.

## Funzionalità realizzate e testate su macOS 15 GitHub Actions
- App SwiftUI nella barra dei menu con scelta delle due cartelle locali.
- Monitoraggio macOS FSEvents per creazioni e modifiche di file.
- Inventario SQLite locale (~/Library/Application Support/MacSync/inventory.sqlite).
- Riconciliazione mirata ai file e sottorami modificati, con coda SQLite transazionale.
- Rilevamento dei file mancanti e registrazione della cancellazione *solo nella coda locale*.
- Scansione completa **solo locale** all'avvio per recuperare modifiche avvenute a programma chiuso.
- Controllo locale ogni 5 minuti; ricontrollo locale completo dopo eventi persi, errori o almeno 24 ore.
- Blocchi per cartelle non disponibili, percorsi sovrapposti e modifiche inattese alla root.
- Test automatici SQLite, rinomine, cancellazioni, percorsi /var e /private/var, FSEvents reale.

## Funzionalità ancora da sviluppare
- rclone / SMB, copia selettiva, cancellazioni e rinomine remote.
- Keychain, esecuzione automatica al login, notifiche e log avanzati.
- Bootstrap SMB non distruttivo e protezioni definitive per la cancellazione in remoto.
- Collaudo sulla VPN e sul server di destinazione effettivo, verifica della performance.
- Notarizzazione Apple e distribuzione definitiva.

## Compilazione
GitHub Actions esegue swift test e swift build -c release su macOS 15. Il pacchetto sperimentale .app viene firmato ad hoc, non notarizzato, e salvato come artifact ZIP nella pagina Actions.

## Sicurezza e privacy
Questo progetto sarà una **copia speculare, non un backup versionato**. Prima di attivare eliminazioni serve una baseline verificata e protezioni contro cancellazioni accidentali e di massa. Conservare inoltre backup indipendenti sul server.

Non caricare sul repository foto, database reali, password SMB, IP privati, configurazioni VPN o log sensibili.

Per continuare con Codex leggere [AGENTS.md](AGENTS.md) e [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Le attività aperte sono negli Issues.
