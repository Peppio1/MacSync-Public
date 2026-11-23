# MacSync v0.18.16 — Candidata di aggiornamento di collaudo

**Stato: preparazione isolata, NON ancora rilasciata.** La versione 0.18.15 attualmente pubblicata rimane invariata. Questa candidata richiede CI completa e verifica specifica SMB/Finder prima di essere firmata e pubblicata nel canale aggiornamenti.

## Novità

- La verifica archivio RAPIDA (QUICK) usa una sola acquisizione dei metadati remoti per file nell'inventario; il confronto successivo non ripete la lettura massiva sulla destinazione SMB.
- La verifica INTELLIGENTE condivide l'inventario e non esegue il riconoscimento massivo, ma mantiene hash SHA-256 selettivo sui file sospetti (stessa dimensione, differenza timestamp oltre 2 secondi), con controlli di stabilità durante la lettura.
- I file con stesso percorso, tipo, dimensione e data/ora (tolleranza 2s) vengono classificati corrispondenti secondo metadati; non è una prova di contenuto identico.
- L'audit non conferma né elimina più job già pendenti in SQLite, compresi gli aggiornamenti FSEvents, anche quando il report mostra file corrispondenti.
- File mancanti o differenti vengono accodati senza duplicare i job pendenti, con le protezioni preesistenti; nessuna eliminazione automatica di file extra, né modifica del mirror.
- Restano backup SQLite preventivo, protezioni delle radici e del volume SMB, rilevamento nomi incompatibili, stop/annullamento e controlli del motore di copia.

## Limitazioni note

- La coda storica **non memorizza un'origine affidabile degli UPSERT**: non si può distinguere con certezza un job FSEvents da uno creato durante l'inventario iniziale. Per evitare la perdita di eventi, questa versione conserva entrambi; possono quindi rimanere copie ridondanti, benché il confronto QUICK sia più rapido.
- L'archivio SMB è assunto a scrittore unico MacSync; la lettura singola non rileva modifiche esterne successive allo snapshot. QUICK non controlla i byte; usare INTELLIGENT quando è necessario un controllo più approfondito.
- INTELLIGENT continua a leggere i dati remoti necessari agli SHA selettivi, per definizione fuori dalla politica QUICK di sola lettura metadati.
- Il collaudo CI/macOS di laboratorio non dimostra da solo l'affidabilità su Windows Server 2016 e montaggio Finder/VPN reale.

## Aggiornamento e precauzioni

Non installare questa candidata sull'archivio operativo prima della validazione e di un backup verificato. La pubblicazione firmata tramite Sparkle richiede un pacchetto esattamente corrispondente al commit testato, una nuova firma Ed25519 e un appcast che incrementi la versione rispetto a 0.18.15.

Documento tecnico: [Verifica archivio a snapshot](DEVELOPMENT_v0.18.16_AUDIT_SNAPSHOT.md).
