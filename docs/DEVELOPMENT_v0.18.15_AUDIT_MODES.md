# v0.18.15 — selezione delle sole verifiche QUICK e INTELLIGENT

**Candidato sperimentale, non pubblicato.** Ramo `develop-v0.18.15-audit-two-modes` derivato dal commit approvato della candidata v0.18.15 `6fa9f99dd94ccffd80c3a7569793fb17d3a91980`. Il riferimento precedente resta disponibile per rollback Git. Nessun merge su `main` né firma/release.

## Cambiamento visibile

- Il selettore della scheda Verifica archivio propone soltanto **Rapida (metadati)** e **Intelligente**.
- DEEP (`ArchiveAuditMode.deep`) **rimane nel core** per registri e report storici e test di sicurezza; non viene cancellato il calcolo SHA-256.
- Il testo UI illustra la tolleranza di due secondi delle date. QUICK non legge il contenuto. INTELLIGENT mantiene il confronto dati e l'hash selettivo *quando i timestamp differiscono oltre due secondi e la dimensione corrisponde*, secondo la logica esistente. Le dimensioni differenti sono segnalate direttamente.
- Nel ripristino delle preferenze `MacSync.archiveAuditSettings`, `mode=deep` viene convertito a `intelligent` e ri-salvato, conservando `enabled`, `repair`, calendario e orario. La selezione viene difesa anche prima dell'avvio manuale o programmato qualora un chiamante imposti temporaneamente DEEP.
- Le anteprime UI usano ora INTELLIGENT per non mostrare una modalità non selezionabile.

## Controlli invariati

Rimangono invariati `ArchiveAudit.run`, la logica di confronto, hashing e cache, controlli `lstat`, coda SQLite, FSEvents, replica Rclone, mirror, protezioni volume, autorizzazioni e cancellazioni. In particolare **non** viene estesa la tolleranza di 2 secondi al fingerprint di identità, `ctime` o timestamp dei controlli contro modifiche durante il read. In caso di incertezza, le operazioni di riconoscimento continuano a fallire chiuse.

## Test nuovi e preesistenti

Nuovi test sintetici:
- modalità UI selezionabili `quick`/`intelligent` e decodifica dello storico `deep`;
- migrazione preferenze DEEP con salvataggio, senza perdita di frequenza, riparazione o altre preferenze;
- QUICK, date entro/oltre 2 secondi e nessuna lettura dei contenuti;
- INTELLIGENT, hashing quando date oltre 2 secondi, cache validata e invalidazione dopo cambio fingerprint/contenuto.

Restano i test storici di sicurezza per DEEP. I risultati della CI non devono essere dichiarati positivi prima dell'effettiva esecuzione.

## Limite SMB

La CI di integrazione `smbfs` è mantenuta in un ramo distinto, senza alterare il workflow in corso. Il comportamento dei timestamp SMB e il salto del `ctime` durante SHA-256 su file nuovi restano problemi da investigare, indipendenti dalla rimozione della voce DEEP dal selettore. Nessuna modifica del motore di sicurezza è inclusa in questa candidata.
