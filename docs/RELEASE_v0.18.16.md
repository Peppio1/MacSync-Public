# MacSync v0.18.16 — Aggiornamento di collaudo

Questo aggiornamento è destinato al **collaudo tecnico**, non equivale alla certificazione del funzionamento sull'archivio aziendale. La versione precedente v0.18.15 rimane disponibile come riferimento.

## Novità

- **QUICK — Verifica archivio rapida:** una sola acquisizione completa dei metadati della destinazione SMB. Successivi confronti e riconciliazione della coda riutilizzano i dati già acquisiti, senza seconda fase massiva di riconoscimento e senza SHA-256. Stesso percorso/tipo, dimensioni e timestamp entro la tolleranza di 2 secondi sono considerati corrispondenti *secondo i metadati*.
- **INTELLIGENT — Verifica intelligente:** stesso percorso ottimizzato per l'inventario e la coda, mantenendo SHA-256 selettivo sui file dubbi e le verifiche di stabilità necessarie durante la lettura.
- **Provenienza della coda SQLite:** i nuovi job vengono distinti tra inventario iniziale, monitoraggio FSEvents, riparazioni dell'audit e riallineamento della nuova destinazione. Soltanto gli UPSERT identificati con certezza come **primo inventario** e già corrispondenti possono essere confermati localmente, senza nuove interrogazioni al server. Gli aggiornamenti FSEvents, anche arrivati durante la verifica, prevalgono sempre.
- **Migrazione DB conservativa:** gli ID e gli stati dei vecchi job sono preservati. I job storici senza origine dimostrabile sono marcati `legacy_unknown` e non vengono eliminati automaticamente, anche se i metadati corrispondono. Questo può lasciare eventuali copie superflue ma evita di perdere aggiornamenti.
- Restano il backup preventivo del database, i controlli su radici e volumi, la protezione dei nomi incompatibili, il motore di copia prudente, il mirror con consenso separato e nessuna eliminazione automatica dei file presenti soltanto sul server.

## Installazione tramite MacSync

Aprire MacSync sul Mac, entrare nella sezione **Aggiornamenti**, selezionare **Controlla aggiornamenti** e seguire la procedura guidata per il pacchetto v0.18.16. L'app esegue l'arresto coordinato delle operazioni e il backup previsto prima dell'installazione. Verificare la versione `0.18.16 (196)` dopo il riavvio.

## Limiti del collaudo

Le suite Swift e le regressioni SQLite/FSEvents, la compilazione universale Intel/Apple Silicon, il DMG, lo stress test sintetico e il laboratorio Sparkle sono stati validati da CI. **Non è ancora stato eseguito il collaudo fisico end-to-end su iMac/macOS Sequoia, Finder SMB, Windows Server 2016 e VPN**, né misurata la durata sul dataset aziendale di circa 350 GB. Usare inizialmente cartelle sintetiche e un backup verificato; non interpretare un controllo QUICK come una prova dell'identità byte-per-byte dei file.

La migrazione SQLite è esclusivamente locale e non introduce una seconda lettura remota. La modalità INTELLIGENT continua intenzionalmente a leggere il contenuto dei file selezionati per SHA-256.

Per eventuali problemi, sospendere le copie e utilizzare i log tecnici. Non ripristinare un vecchio database sopra operazioni successive: il ripristino dell'applicazione e dei dati seguono procedure diverse.
