# MacSync v0.18.9 — Aggiornamento di collaudo

- Il Registro tecnico mantiene ricerca, filtro di livello, dettaglio Rclone e diagnostica di emergenza. **Log Completo** apre lo storico conservato, caricato a pagine con gli eventi più recenti in alto.
- In **Impostazioni → Diagnostica per i test** è disponibile l'esportazione JSON per periodo, con identificativi sostitutivi e senza testo libero del registro. Comprende le misure disponibili per confrontare i test, per esempio i tempi di copia, avvio di Rclone, Verifica archivio, apertura del log e annullamento dell'audit.
- I lotti di rettifica già confermati sono persistenti. Dopo un'interruzione MacSync controlla i percorsi e l'identità prima di proseguire. Le copie restano sospese in presenza di esiti incerti.
- La sincronizzazione verifica il contenuto dei file nei percorsi rettificati prima di riconoscerli come già allineati. La verifica via hash può leggere i file attraverso SMB.
- La scheda **Nomi incompatibili** mostra le date dei risultati disponibili per sorgente e destinazione.

La Verifica archivio usa lo scanner MacSync e la sincronizzazione ordinaria elabora serialmente la coda. Il collaudo della rinomina esclusiva su una condivisione Windows reale e le comparative di prestazioni su SMB via VPN si svolgono su cartelle di prova.
