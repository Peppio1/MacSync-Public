# MacSync v0.18.11 — Correzione del riavvio dell’inventario

- Una rettifica sospesa resta salvata in SQLite. Il monitor locale completa l’inventario senza essere fermato dai ritentativi periodici.
- In **Nomi incompatibili**, il pulsante esistente diventa **Riprendi rettifica** quando c’è un lotto salvato. La ripresa verifica ancora identità e percorsi. Le copie restano sospese finché l’esito è incerto.
- Incluse le correzioni di collaudo v0.18.10. La scansione dei nomi mostra lato, elementi letti e durata. Dopo 90 secondi senza attività l’enumerazione termina con un esito esplicito e conserva gli esiti salvati. La protezione vale anche per l’enumerazione della destinazione nella Verifica archivio.
- Se la finestra principale è occupata, l’aggiornamento si può avviare da **MacSync → Controlla aggiornamenti…** nella barra dei menu. L’installazione aspetta l’arresto ordinato del monitor e dei worker e il backup locale.

Se la condivisione rifiuta la rinomina esclusiva con POSIX 45, il lotto resta sospeso. Questa release elimina il riavvio ciclico dell’inventario e conserva la protezione contro le sovrascritture.
