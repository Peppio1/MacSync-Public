# MacSync v0.19.3 — build 201

- Distinzione tra proposte di rettifica, collisioni effettive e situazioni ancora da verificare.
- Gestione dei nomi con spazi e punti finali; i punti intermedi restano compatibili.
- Pulizia eccezionale dei duplicati rettificati identificabili, subordinata alle autorizzazioni mirror e ai controlli di identità e contenuto. I nomi nascosti o ambigui rimangono protetti.
- Consultazione della coda in sola lettura, con ordine previsto dal motore, filtri, percorsi completi e stati.
- Diagnostica separata della verifica Rapida (metadati) e Intelligente; riepilogo delle operazioni ancora pendenti senza riscrittura dello storico.
- Azzeramento protetto con riavvio automatico e conferma dopo verifica; richiesta di apertura della finestra in primo piano dopo manutenzione.
- Rollback volontario alla v0.19.2 build 200 tramite il pacchetto originale firmato, subordinato ai controlli di compatibilità e sicurezza dell'archivio.

Test automatici mirati e condivisione SMB montata in laboratorio superati sul codice candidato. Il collaudo della finestra e del flusso operativo su un Mac reale resta necessario. Non tutte le grafie incompatibili sono accessibili attraverso ogni server SMB; gli elementi non identificabili restano sospesi.

Compatibile con Apple Silicon e Intel, macOS 13 o successivo.
