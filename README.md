# MacSync

**Sincronizzazione unidirezionale nativa per macOS, verso cartelle locali o condivisioni SMB.**

![Ultima release](https://img.shields.io/badge/release-0.18.13-blue)
![Piattaforma](https://img.shields.io/badge/platform-macOS-lightgrey)
[![macOS CI](https://github.com/Peppio1/MacSync-Public/actions/workflows/macos-ci.yml/badge.svg?branch=main)](https://github.com/Peppio1/MacSync-Public/actions/workflows/macos-ci.yml)

MacSync è un'applicazione desktop sviluppata in Swift e SwiftUI per replicare cartelle di lavoro del Mac su una destinazione locale o di rete, senza installare componenti sul server. La sorgente rimane l'unica fonte di verità: nessuna sincronizzazione inversa.

> **Stato al 21 novembre 2026:** ultima release pubblicata **[v0.18.13](https://github.com/Peppio1/MacSync-Public/releases/tag/v0.18.13)** (aggiornamento di collaudo). La **v0.18.14** è un [candidato di sviluppo](docs/DEVELOPMENT_v0.18.14.md) con CI e benchmark locali sintetici superati, **non pubblicato** e ancora da validare su SMB/VPN reale. Per il collaudo usare soltanto dati di prova; non considerare il risultato CI una garanzia di sicurezza operativa.

## Download

### Ultima release pubblicata: MacSync v0.18.13 (20 novembre 2026)

- [DMG universale](https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.13/MacSync-v0.18.13-macOS-universal.dmg) · [SHA-256 del DMG](https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.13/MacSync-v0.18.13-macOS-universal.dmg.sha256)
- [ZIP universale](https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.13/MacSync-v0.18.13-macOS-universal.zip) · [SHA-256 dello ZIP](https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.13/MacSync-v0.18.13-macOS-universal.zip.sha256) · [firma Ed25519](https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.13/MacSync-v0.18.13-macOS-universal.zip.edsignature)
- [Note ufficiali della release](https://github.com/Peppio1/MacSync-Public/releases/tag/v0.18.13)

La v0.18.14 **non** è disponibile tra le release: gli artefatti prodotti dal [workflow di sviluppo](https://github.com/Peppio1/MacSync-Public/actions/runs/44905111203) servono solo ai test e non costituiscono una distribuzione firmata per la produzione.

### Archivio storico: MacSync v0.17.0 — pre-release di collaudo (17 novembre 2026)

[![Scarica MacSync per macOS](https://img.shields.io/badge/Scarica_MacSync_v0.17.0-DMG-2563eb?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.dmg)

macOS 13 o successivo (Intel e Apple Silicon). CI eseguita su macOS 15.

| Pacchetto | Download | Integrità |
|---|---|---|
| **DMG — consigliato** | [Installer grafico (9,57 MB)](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.dmg) | [SHA-256](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.dmg.sha256) |
| ZIP universale (alternativo) | [Archivio (7,30 MB)](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.zip) | [SHA-256](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.zip.sha256) · [Firma Ed25519](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/MacSync-v0.17.0-macOS-universal.zip.edsignature) |

[Release e note di versione](https://github.com/Peppio1/MacSync-Public/releases/tag/v0.17.0) · [Checksum completi](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/SHA256SUMS) · [Provenienza build](https://github.com/Peppio1/MacSync-Public/releases/download/v0.17.0/build-provenance.txt) · [Guida installazione](docs/INSTALLATION.md)

I download appartengono alla release pubblica e non agli artefatti temporanei di Actions. Il DMG include MacSync.app, collegamento ad Applicazioni e guida illustrata offline. Il bundle è firmato ad hoc, **non notarizzato**; la firma Ed25519 del pacchetto ZIP e del feed non sostituisce Developer ID o notarizzazione Apple. La pre-release non è un aggiornamento stabile automatico.

Versione precedente: [v0.15.0 — pre-release convalidata](https://github.com/Peppio1/MacSync-Public/releases/tag/v0.15.0). La v0.16.0 è stata convalidata e firmata, ma non pubblicata separatamente.

## Funzionalità

- Configurazione grafica delle cartelle, tramite selezione Finder o drag and drop; più coppie separate e controllo delle sovrapposizioni.
- Sincronizzazione incrementale: monitor FSEvents, inventario locale e coda persistente SQLite; nessuna scansione ricorsiva della destinazione ad ogni ciclo ordinario.
- Avvio manuale immediato oppure pianificazione: 1–59 minuti, 1–23 ore, giornaliera o settimanale; avvio al login facoltativo e consenso separato per le copie automatiche.
- Copie prudenti con staging, controlli di identità e stabilità, protezione delle sostituzioni e ripresa dalla coda dopo interruzioni.
- Cancellazioni speculari facoltative, disattivate per impostazione predefinita, con consenso persistente esplicito; recupero opzionale e conservazione da 1 a 30 giorni o illimitata.
- Controllo della disponibilità delle destinazioni e notifiche facoltative per disconnessioni prolungate.
- Verifica archivio manuale o programmata: confronto rapido dei metadati oppure approfondito SHA-256; diagnostica non distruttiva e riallineamento facoltativo dei file mancanti/differenti.
- Riconoscimento dei file già copiati con verifica SHA-256 e conferma esplicita, utile per un archivio inizializzato in precedenza.
- Stato delle operazioni, avanzamento, tempi, velocità media di copia, storico per ciclo, dettagli per file e registro esportabile.
- Interfaccia in italiano, con temi chiaro e scuro e layout adattivo.
- Aggiornamenti solo stabili con controllo facoltativo ogni 24 ore, firma Ed25519 del feed e dello ZIP, conferma esplicita, backup preventivo e recupero assistito.

## Come funziona

```mermaid
flowchart LR
    A[Cartelle locali Mac] --> B[FSEvents e inventario]
    B --> C[Coda SQLite persistente]
    C --> D[Worker seriale e controlli]
    D --> E[Destinazione locale o SMB]
```

MacSync usa la condivisione già montata e accessibile al Finder. Non gestisce VPN, password SMB o rimontaggi forzati; se la destinazione scompare, conserva le operazioni pendenti e ritenta quando è nuovamente accessibile e verificata. I permessi di lettura/scrittura degli altri utenti vengono configurati sul server, non da MacSync.

## Sicurezza e limiti

- Il mirror richiede autorizzazione esplicita per le coppie identificate; le eliminazioni anteriori al consenso non vengono riprodotte.
- Le protezioni tecniche sono obbligatorie. Le soglie facoltative contro eliminazioni massive e sorgente vuota sono disattivate per default.
- Spostamenti e rinomine sono trattati come nuova copia e rimozione del percorso precedente; le cancellazioni attendono il completamento degli upload pendenti.
- Il trasferimento interrotto riparte dall'inizio del singolo file; non è previsto resume a offset.
- Le normali copie verificano stabilità, identità e dimensione; non effettuano sempre un hash completo. La verifica approfondita legge i file anche dalla destinazione e può consumare banda VPN.
- I backup SQLite sono verificati e autonomi, includono i dati WAL confermati e vengono pubblicati senza sovrascritture. Non sostituiscono il backup delle fotografie o dei documenti.
- Non è garantita l'atomicità su tutte le implementazioni SMB; identità dei file dopo rimontaggio, ACL Windows, guasti reali e sospensione devono essere collaudati.

## Requisiti e compilazione

- macOS 13 o successivo secondo il manifest; CI su macOS 15. Compatibilità fisica con le altre versioni da verificare.
- Swift 5.9 o successivo per compilare, toolchain macOS con SDK.
- Destinazione locale oppure SMB già accessibile; nessun servizio MacSync richiesto sul server.

```bash
swift test
swift build -c release
```

La CI assembla anche un bundle MacSync.app con firma ad hoc, non notarizzato. I pacchetti temporanei e le anteprime grafiche si trovano negli [artefatti GitHub Actions](https://github.com/Peppio1/MacSync-Public/actions); possono scadere. Non sono release di produzione.

## Installazione e guida all'utilizzo

### 1. Installazione su macOS

Scaricare il [DMG v0.18.13](https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.13/MacSync-v0.18.13-macOS-universal.dmg) e il relativo [SHA-256](https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.13/MacSync-v0.18.13-macOS-universal.dmg.sha256). Aprire il DMG, trascinare MacSync.app su Applicazioni, leggere la guida illustrata inclusa, espellere il volume e avviare MacSync da Applicazioni. In alternativa estrarre lo ZIP e spostare MacSync.app in Applicazioni.

Controllo facoltativo nel Terminale (dalla cartella che contiene DMG e checksum):

```bash
shasum -a 256 -c MacSync-v0.18.13-macOS-universal.dmg.sha256
```

Proseguire soltanto se la verifica restituisce OK. MacSync è un'applicazione della barra dei menu: da lì si apre la finestra di configurazione.

Essendo una build non notarizzata, macOS potrebbe impedirne l'apertura. Verificare provenienza e integrità del pacchetto prima di autorizzare eventualmente la singola applicazione nelle impostazioni Privacy e sicurezza. Non disattivare globalmente Gatekeeper. Usare soltanto file sintetici per il collaudo.

### 2. Configurazione delle cartelle

Aprire **Cartelle** e scegliere le sorgenti locali tramite **Sfoglia…** o trascinamento dal Finder. È possibile aggiungere sorgenti e configurare le rispettive destinazioni, anche sotto una cartella comune. Non selezionare percorsi sovrapposti.

Esempio dimostrativo:

```text
Mac (sorgente)                  Destinazione locale o SMB
Cartella_A             ─────►   Condivisione/Cartella_A
Cartella_B             ─────►   Condivisione/Cartella_B
```

Per una destinazione di rete, collegarsi prima alla condivisione SMB con Finder, quindi selezionare la cartella accessibile. Non occorre installare MacSync sul server.

### 3. Prima sincronizzazione

1. Attendere l'inventario delle sorgenti locali.
2. Aprire **Verifica archivio** ed eseguire un confronto diagnostico, senza riallineamento.
3. Se la destinazione contiene già una copia iniziale, usare la verifica approfondita e il riconoscimento dei file identici con conferma esplicita. Il confronto SHA-256 legge anche i dati remoti.
4. Nella **Panoramica**, scegliere **Avvia sincronizzazione**.
5. Controllare file copiati, coda residua, errori e risultati in **Registro attività**.

### 4. Pianificazione e avvio automatico

Dalla pagina **Pianificazione** scegliere l'intervallo in minuti oppure ore, o un orario giornaliero/settimanale. Per esempio, un ciclo ogni cinque minuti. Salvare l'impostazione.

In **Impostazioni** è possibile attivare separatamente l'avvio dell'app al login e la sincronizzazione automatica. L'avvio dell'app non autorizza da solo le copie o le eliminazioni. Se una destinazione non è accessibile, le scritture vengono sospese.

### 5. Cancellazioni speculari e recupero

| Impostazione | Comportamento |
|---|---|
| Cancellazione speculare disattivata (predefinita) | I file rimossi dalla sorgente rimangono nella destinazione |
| Mirror attivo, recupero attivo | Le eliminazioni autorizzate spostano i file nella cartella di recupero |
| Mirror attivo, recupero disattivato | Le eliminazioni autorizzate sono definitive |

L'attivazione del mirror richiede consenso esplicito. Provare questa funzione esclusivamente su archivi di test. Le eliminazioni precedenti all'autorizzazione non sono riprodotte. Le nuove copie hanno priorità sulle rimozioni: durante uno spostamento il vecchio percorso resta preservato finché le copie pendenti non sono completate.

### 6. Controllo delle operazioni e manutenzione

- **Panoramica:** stato, coda, avanzamento e riepilogo dei cicli.
- **Cartelle:** configurazione e associazione dei percorsi.
- **Pianificazione:** frequenza e prossimi cicli.
- **Verifica archivio:** confronto rapido o SHA-256, programmazione e manutenzione controllata.
- **Registro attività:** esiti, errori, dettagli e esportazione TSV.
- **Impostazioni:** avvio, aspetto, recupero, sicurezza e notifiche.

Usare **Ferma tutto** prima di interventi straordinari. Attendere la conclusione delle operazioni in corso; una chiamata SMB bloccata può ritardare la chiusura.

### 7. Aggiornamenti e recupero

In **Impostazioni → Aggiornamenti software**, usa Controlla o attiva il controllo automatico (non avvia download automatici). Le pre-release, inclusa v0.17.0, non vengono offerte dal canale stabile: scaricarle manualmente da Releases. Installa MacSync.app in Applicazioni. La conferma iniziale sospende e drena le operazioni, crea uno snapshot verificato e apre Sparkle; conferma l’installazione nella sua finestra. Dopo annullamento o aggiornamento, riapri MacSync dalla posizione originale e verifica le impostazioni. Copie automatiche, mirror e audit pianificato restano disabilitati finché non li riabiliti esplicitamente.

Se MacSync non si avvia e l’installatore è terminato, apri nel Finder la cartella `~/Library/Application Support/MacSync/update-backups`, individua il backup della transazione pendente e apri **Ripristina MacSync.command**. Conferma con RIPRISTINA. Il recupero è offline, senza sudo; rifiuta database modificati o destinazioni/identità non verificabili, preserva l’app sostituita e non sovrascrive SQLite né preferenze. Non avviare il recupero mentre Sparkle sta ancora installando. La guida tecnica è in [Aggiornamenti e recupero](docs/UPDATES.md). Non eliminare manualmente il marcatore o i file di lock.

## Stato della validazione

**Versione pubblicata più recente:** [v0.18.13](https://github.com/Peppio1/MacSync-Public/releases/tag/v0.18.13). **Candidato v0.18.14:** [documentazione tecnica, regressioni e benchmark](docs/DEVELOPMENT_v0.18.14.md).

Per la v0.18.14 la [CI del 21 novembre 2026](https://github.com/Peppio1/MacSync-Public/actions/runs/44905111203) ha verificato 248 test Swift (4 saltati, 0 falliti), benchmark sintetici con 200.000 file per lato e 50.000 differenze reali, build universale e pacchetti temporanei. La scansione rapida non ha letto il contenuto dei file nel benchmark. **Non sono ancora disponibili misure su SMB/VPN reale** e non è stata eseguita la firma definitiva di produzione.

### Storico dei test della v0.17.0

Versione pubblicata: [v0.17.0](https://github.com/Peppio1/MacSync-Public/releases/tag/v0.17.0), commit del pacchetto [2fe7037](https://github.com/Peppio1/MacSync-Public/commit/2fe7037cf135f2cbd0051343885875a50aa6c015). [CI e firma](https://github.com/Peppio1/MacSync-Public/actions/runs/44072456998) e [pubblicazione dell'artefatto esatto](https://github.com/Peppio1/MacSync-Public/actions/runs/44074982577) completate con successo. Nessuna ricompilazione in fase di pubblicazione.

| Verifica | Risultato |
|---|---|
| Suite ordinaria | 177 superati, 0 falliti, 2 opt-in (UI e recupero eseguiti separatamente); 179 rilevati |
| Test integrato: due coppie, disconnessione simulata, backup e ripresa | Superato |
| Carico sintetico: 40 cartelle, 360 file, quattro cicli di modifica | Superato |
| Mirror definitivo e con recupero | Superato |
| Release build e 48 anteprime UI | Completati |
| 96 cicli accelerati, inventario 10.000 file, interruzione simulata | Superati |
| Compilazione universale v0.17.0 (Intel e Apple Silicon) | Superata |
| Firma Ed25519 di produzione (candidato precedente) | Superata nel run 44063365937 |
| Installazione Sparkle e rifiuto archivio alterato | Superati nel run 44066873367 |
| Recupero e preflight su processi separati, firma v0.16.0 | Superati (44068276632) |
| Branding con PNG approvato, DMG montato e verifica bundle, guida | Superati |
| Sparkle v0.17.0 → v0.17.1, riavvio simulato, recupero e rifiuto manomissione | Superati |
| Firma Ed25519 ZIP e feed v0.17.0 | Superata |
| Pubblicazione pre-release con 8 asset verificati | Superata |
| Durata reale e risorse app installata | Da collaudare |
| Interazioni UI, avvio al login, arresto e SMB/VPN reale | Da collaudare |

Il prossimo obiettivo è il collaudo della v0.17.0 su Mac reale, iniziando da cartelle sintetiche locali e poi SMB/VPN. La candidata 1.0.0-rc.1 sarà preparata in base agli esiti; nessuna versione 1.0 stabile è dichiarata.

## Cronologia e changelog

Le versioni sono riportate dalla più recente alla più vecchia. Lo storico descrive lo sviluppo progressivo: le impostazioni e i limiti delle vecchie versioni non sostituiscono quelli della versione attuale.

### v0.17.0 — branding e installer (pre-release pubblicata)

- Icona Finder/Applicazioni .icns, marchio nella sidebar e simbolo monocromatico template della menu bar. Il master approvato viene riconosciuto tramite SHA-256; fallback esclusivamente CI se assente.
- DMG grafico drag-and-drop, guida HTML illustrata offline e ZIP universale per Sparkle.
- Controlli risorse, montaggio read-only del DMG e verifica firma del bundle interno, regressione e test Sparkle isolati superati.
- ZIP/feed firmati Ed25519 e pre-release pubblicata il 17 novembre 2026 dagli artefatti esatti della CI, senza ricompilazione. Nessuna release stabile automatica.
- [Guida installazione e distribuzione](docs/INSTALLATION.md).

### v0.16.0 — sistema aggiornamenti (validato in CI)

- Pannello aggiornamenti nelle Impostazioni e comando dalla barra menu.
- Controllo manuale e automatico delle release stabili; nessuna installazione non autenticata.
- Sparkle 2.10.0 integrato; feed e archivio firmati, conferma, arresto dei worker, backup e recupero assistito del solo bundle.
- Firma di produzione, installazione isolata e collaudo integrato del riavvio/rollback superati nel run 44068276632. Nessuna release v0.16.0 pubblicata.

### v0.15.0 — consolidamento

- Motore, interfaccia, database e autorizzazioni invariati; versione visualizzata e metadati aggiornati.
- Compilazione universale arm64/x86_64, controllo firma ad hoc, verifica del pacchetto estratto e checksum SHA-256.
- Workflow di pubblicazione condizionato alla regressione completa, senza sovrascrivere release esistenti.
- Baseline precedente: 167 test ordinari superati, 96 cicli accelerati, inventario di 10.000 file.
- Nessuna dichiarazione di stabilità in produzione; collaudo reale ancora necessario.

### v0.14.3 — baseline precedente

- Backup SQLite autonomi tramite VACUUM INTO, correzione della creazione del file temporaneo su macOS, controllo integrità e pubblicazione esclusiva.
- Validazione della ripresa dopo disconnessione simulata, ripristino separato della coda e diagnostica finale.
- Test di carico con 40 cartelle e 360 file sintetici, quattro cicli di aggiornamento e verifica delle cancellazioni definitive/con recupero.
- 164 test ordinari superati, nessun errore; rendering separato e 48 anteprime.
- Validazione prolungata e collaudo fisico ancora da effettuare.

### v0.14.0 – v0.14.2 — sicurezza operativa

| Versione | Novità |
|---|---|
| v0.14.2 | Isolamento dei backup SQLite e pubblicazione esclusiva degli snapshot verificati |
| v0.14.1 | Correzioni dei test di riconnessione, nomi Unicode e gestione WAL |
| v0.14.0 | Identità persistente delle cartelle, controlli Windows, blocco istanze multiple, sicurezza database, arresto controllato e gestione delle pubblicazioni interrotte |

### v0.13 — interfaccia grafica e organizzazione

| Versione | Novità |
|---|---|
| v0.13.9 | Ripristino del pannello operativo della verifica archivio |
| v0.13.8 | Layout desktop adattivo e 48 anteprime nei due temi |
| v0.13.7 | Miglioramento del layout della verifica e dei nomi dei giorni |
| v0.13.6 | Organizzazione della schermata verifica archivio |
| v0.13.5 | Verifica archivio unificata e riconoscimento SHA-256 |
| v0.13.4 | Configurazione delle sorgenti e destinazione comune, modifica protetta della pianificazione |
| v0.13.3 | Layout desktop compatto |
| v0.13.2 | Revisione UI/UX e annullamento del singolo ciclo |
| v0.13.1 | Consolidamento della compilazione e delle anteprime automatiche |
| v0.13.0 | Nuova organizzazione dell'interfaccia e della pianificazione |

### Versioni precedenti — sviluppo del motore

| Versione | Novità |
|---|---|
| v0.12.4 | Statistiche dettagliate, avanzamento, storico e verifica completa programmabile |
| v0.12.3 | Autorizzazione persistente del mirror e protezioni facoltative configurabili |
| v0.12.2 | Ripartenza dei file interrotti e gestione dei temporanei |
| v0.12.1 | Gestione prudente dei backup temporanei |
| v0.12 | Coda paginata e prestazioni dei cicli |
| v0.11 | Resilienza, verifica dei file e sicurezza delle sostituzioni |
| v0.10.1 | Correzioni della pianificazione e degli avvisi |
| v0.10 | Intervalli configurabili e avviso di disconnessione |
| v0.9.1 | Ripresa automatica delle copie |
| v0.9 | Avvio al login e verifica della disponibilità |
| v0.8.1 | Correzione dello scanner e riepilogo operativo |
| v0.8 | Cancellazioni speculari, recupero e conservazione |
| v0.7 | Riconoscimento SHA-256 dei file già presenti |
| v0.6 | Spazio disponibile, staging, diagnostica e registro |
| v0.5 | Base del prototipo: monitoraggio locale, coda SQLite e replica unidirezionale |

Per le modifiche tecniche dettagliate di ogni versione consultare lo [storico completo dello sviluppo](docs/DEVELOPMENT_HISTORY.md) e lo [storico dell'architettura](docs/ARCHITECTURE_HISTORY.md).

### Prossime fasi

- Installare e collaudare v0.17.0 su Mac fisico con dati sintetici: primo avvio, Gatekeeper, UI, menu bar e funzionamento locale.
- Verificare SMB/VPN, permessi Windows, disconnessione/riconnessione, copie interrotte, arresto, mirror e uso prolungato su un archivio di prova.
- Correggere eventuali problemi rilevati e preparare 1.0.0-rc.1.
- Pubblicare una versione stabile soltanto dopo la validazione operativa.

## Documentazione

- [Installazione e primo avvio](docs/INSTALLATION.md)
- [Aggiornamenti e recupero](docs/UPDATES.md)
- [Architettura tecnica](docs/ARCHITECTURE.md)
- [Contesto di sviluppo e regole di sicurezza](AGENTS.md)
- [Note storiche di sviluppo](docs/DEVELOPMENT_HISTORY.md)
- [Architettura storica](docs/ARCHITECTURE_HISTORY.md)

L'edizione pubblica contiene solo esempi e dati sintetici. Non pubblicare configurazioni aziendali, fotografie, database operativi, credenziali o log sensibili. Il repository attualmente non contiene una licenza esplicita: la disponibilità del codice non costituisce di per sé autorizzazione al riutilizzo o alla redistribuzione.
