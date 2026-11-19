# Preparazione v0.18.7 — Registri
Ramo isolato prepare-v0.18.7-logs. Base v0.18.6 CI ffd659365ac1531d9563da758758144322cee452. Non modificare develop-v0.18.6, main, tag, feed o workflow in corso. Nessun bump di versione finché la release precedente non è conclusa.

## Prima tranche
- Metadati di correlazione additivi in tabella separata per preservare vecchio schema di sync_activity. Ciclo e job espliciti; legacy non attribuito per inferenza.
- Registro tecnico paginato per ID (100 righe), filtro, sola lettura, dettaglio espandibile, export esplicito massimo 5000, aggiornamento incrementale ogni 5 secondi durante la consultazione.
- Diagnostica fallback locale bounded indipendente da SQLite (ciclo start/end, sospensione, fallimento scrittura log e avvio sessione), senza percorsi o output raw di Rclone.
- Test core di paginazione/correlazione e fallback. Nessun cambiamento al motore Rclone, alle verifiche archivio o all'inventario.

## Prima della compilazione e del rilascio
Riallineare al commit finale validato v0.18.6 senza sovrascriverne correzioni. Completare riepilogo per ciclo, correlazione eventi e codici errore effettivi Rclone/SQLite/SMB, log level Normale/Dettagliato/Debug (non registrare credenziali o path assoluti), avvisi ripetitivi aggregati, diagnostica blocchi prima di sessione, UI ed export test, benchmark su log popolato. Verificare migrazione/rollback, lock SQLite, coerenza paginazione, retention/rotazione, accessibilità, eventuali log incompleti. Avviare workflow dedicato solo dopo completamento v0.18.6. Questo è un primo sviluppo non compilato, non un aggiornamento disponibile.
