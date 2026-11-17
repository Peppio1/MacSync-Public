# MacSync v0.17.0 — Pre-release di collaudo

Versione universale macOS 13 o successivo, Intel e Apple Silicon. Per il **primo collaudo su Mac fisico**, non ancora release stabile. Nessun servizio necessario sul server.

## Download e installazione
- **MacSync-v0.17.0-macOS-universal.dmg** (consigliato): aprire, trascinare MacSync.app in Applicazioni, leggere la guida illustrata inclusa, espellere il volume e avviare da Applicazioni.
- ZIP universale alternativo: estrarre e spostare l'app in Applicazioni.
- Verificare SHA-256 prima di aprire il pacchetto. Firma ad hoc del bundle, non notarizzato da Apple. Ed25519 protegge lo ZIP e il feed aggiornamenti; non sostituisce Developer ID o notarizzazione.
- Se Gatekeeper blocca l'apertura, verificare origine e integrità, poi autorizzare la singola applicazione in Privacy e sicurezza. Non disattivare Gatekeeper globalmente.

## Novità
- Icona originale approvata elaborata con trasparenza, risoluzioni Finder da 16 a 1024 px, marchio sidebar e simbolo menu bar.
- Installer DMG grafico e guida HTML illustrata offline.
- Aggiornamenti firmati Sparkle, backup preventivo e recupero assistito del bundle senza sovrascrivere l'archivio operativo.
- Motore unidirezionale, inventario e coda SQLite, protezioni delle copie e cancellazioni invariati rispetto alla baseline validata.

## Risultati CI effettivi
Commit testato: 2fe7037cf135f2cbd0051343885875a50aa6c015.
[Run 44072456998](https://github.com/Peppio1/MacSync-Public/actions/runs/44072456998): 177 test ordinari superati, 0 fallimenti, 2 opt-in eseguiti separatamente, 48 anteprime UI, generazione icone con PNG originale verificato; compilazione ARM64/x86_64, ZIP, DMG montato read-only e verifica firme dei bundle; laboratorio aggiornamenti, recupero, riavvio simulato e rifiuto pacchetto alterato; firma di produzione Ed25519 e appcast verificati. Pacchetti provenienti dagli artefatti originali, senza ricompilazione.

## Collaudo richiesto
Provare inizialmente con cartelle e file sintetici, locali e poi SMB/VPN. Verificare permessi, riconnessione, arresto durante copie, ripresa, eliminazioni speculari con autorizzazione, UI e barra menu. Conservare backup indipendenti dei dati. Le prove CI non certificano il funzionamento su un iMac reale o in produzione; verifica visiva Finder e Gatekeeper ancora necessaria. Non usare dati aziendali prima della validazione. Eventuali piccole rifiniture grafiche sono rinviate al feedback del collaudo.

Questa pre-release non è selezionata come latest stabile e non deve essere distribuita automaticamente ai client. Il feed firmato è incluso per tracciabilità; l'aggiornamento ordinario rimane limitato alle future release stabili.
