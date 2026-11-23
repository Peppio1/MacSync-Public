# MacSync v0.18.16 — Candidata di aggiornamento di collaudo

**Stato: preparazione isolata, NON ancora rilasciata.** La versione 0.18.15 attualmente pubblicata rimane invariata. Questa candidata richiede CI completa e verifica specifica SMB/Finder prima di essere firmata e pubblicata nel canale aggiornamenti.

## Novità

- La verifica archivio RAPIDA (QUICK) usa una sola acquisizione dei metadati remoti per file nell'inventario; il confronto successivo non ripete la lettura massiva sulla destinazione SMB.
- La verifica INTELLIGENTE condivide l'inventario e non esegue il riconoscimento massivo, ma mantiene hash SHA-256 selettivo sui file sospetti (stessa dimensione, differenza timestamp oltre 2 secondi), con controlli di stabilità durante la lettura.
- I file con stesso percorso, tipo, dimensione e data/ora (tolleranza 2s) vengono classificati corrispondenti secondo metadati; non è una prova di contenuto identico.
- La nuova colonna SQLite `origin` distingue inventario iniziale, monitoraggio FSEvents/recovery, audit e nuovo target. Solo i job **certificati come primo inventario** e già corrispondenti vengono considerati soddisfatti mediante i dati QUICK/INTELLIGENT in memoria, senza alcuna nuova lettura del server; aggiornamenti FSEvents e altri job rimangono in coda.
- File mancanti o differenti vengono accodati senza duplicare i job pendenti, con le protezioni preesistenti; nessuna eliminazione automatica di file extra, né modifica del mirror.
- Restano backup SQLite preventivo, protezioni delle radici e del volume SMB, rilevamento nomi incompatibili, stop/annullamento e controlli del motore di copia.

## Limitazioni note

- **Compatibilità DB:** le operazioni già presenti prima dell'aggiornamento ricevono `legacy_unknown` senza alterare ID, stato e storico. Non vengono automaticamente completate quando QUICK trova metadati corrispondenti: la loro provenienza non è dimostrabile. Possono rimanere copie ridondanti, ma gli eventi non vengono persi. Il database è migrato localmente senza nuova scansione SMB. I job di riallineamento di una destinazione nuova restano protetti.
- L'archivio SMB è assunto a scrittore unico MacSync; la lettura singola non rileva modifiche esterne successive allo snapshot. QUICK non controlla i byte; usare INTELLIGENT quando è necessario un controllo più approfondito.
- INTELLIGENT continua a leggere i dati remoti necessari agli SHA selettivi, per definizione fuori dalla politica QUICK di sola lettura metadati.
- Il collaudo CI/macOS di laboratorio non dimostra da solo l'affidabilità su Windows Server 2016 e montaggio Finder/VPN reale.

## Aggiornamento e precauzioni

Non installare questa candidata sull'archivio operativo prima della validazione e di un backup verificato. La pubblicazione firmata tramite Sparkle richiede un pacchetto esattamente corrispondente al commit testato, una nuova firma Ed25519 e un appcast che incrementi la versione rispetto a 0.18.15.

Documento tecnico: [Verifica archivio a snapshot](DEVELOPMENT_v0.18.16_AUDIT_SNAPSHOT.md).
