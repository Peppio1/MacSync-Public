# MacSync v0.18.2 — sviluppo e verifica

Baseline v0.18.1: cc4cea4e7c5c0ca74c69ff9762342ef3471d3b18. Ramo separato, nessuna modifica alla release pubblicata.

Implementazione da validare: riconoscimento cartelle, seconda verifica dimensioni discordanti, fallback SMB linkat senza overwrite, lettura prudente nomi speciali, report bilaterale, contatori coda, esclusione .DS_Store, cache confronti SHA-256, controllo selettivo prima della copia, svuotamento coda con backup SQLite e blocco persistente fino all'audit manuale. Benchmark sintetico 200.000 file e 48.000 cartelle per lato.

Restano necessari: verifica effettiva CI, collaudo reale SMB Windows Server/VPN, probe isolato delle capacità e cache per sessione, classificazione e backoff persistente degli errori, recupero automatico verificato dei temporanei, ottimizzazione enumerazione/cartelle e prova grande con differenze reali. Non considerare il ramo idoneo alla pubblicazione prima del completamento e controllo delle verifiche. Nessuna soglia numerica per impedire aggiornamenti effettivamente diversi.

## Blocco A — candidato, non ancora validato

Checkpoint `rollback-v0.18.2-before-block-A` sulla CI verde 44313724362. Probe esclusivo in staging con file univoci; fallback hard link, controllo reale di pubblicazione invariato. Retry per job o root con backoff SQLite, reset su nuova connessione osservata e svuotamento. Registro persistente dei temporanei completamente osservati prima della pubblicazione; rimozione solo con identità verificata e ripartenza da zero. Esiti ambigui e residui non attribuibili, inclusi residui storici o di job ritirati, restano conservati per controllo. Test per collisioni, riapertura DB e recupero. Il probe non prova tutte le condizioni di una condivisione SMB reale: serve ancora il collaudo su Windows Server/VPN.

## Blocco B — candidato, non ancora validato

Checkpoint A: `rollback-v0.18.2-before-block-B`, commit 4b8728ba16b49b28e749e64c9644bc578a6717a3, CI 44321907833 verde (compreso laboratorio Sparkle); firma produzione non eseguita. Cache limitata a 64 directory / 100.000 nomi, solo confronto in lettura per singola coppia, identità e timestamp POSIX ricontrollati a ogni accesso, invalidazione per mutazione/errore e fine confronto; niente cache nelle conferme definitive, pubblicazioni o cancellazioni. Inventario destinazione con un lstat per oggetto (senza richieste esplicite duplicate a URLResourceValues); inventario locale invariato. Report JSON: contatori cache e letture directory. Test alias aggiunti dopo confronto, sostituzione cartella, symlink, invalidazione, metadati ed esclusioni. I tempi su SMB reale restano da misurare; benchmark locale non rappresenta latenza VPN.
