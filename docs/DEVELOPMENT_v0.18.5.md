# MacSync v0.18.5 — candidato Rclone

Base: v0.18.4; rollback-before-v0.18.5-rclone. Rclone v1.76.0, binari ufficiali con digest SHA-256 fissati nel repository, universal arm64/x86_64 e firma ad hoc dentro il bundle. MIT, licenza inclusa; nessuna installazione sul server.

* Il programma applicativo usa Rclone solo per copyto da file regolare a UUID.partial nella cartella .macsync-staging. --inplace vale esclusivamente per lo staging, mai per il percorso finale. Nessuna scansione ricorsiva programmata. I retry sono responsabilità del coordinatore.
* Nessun fallback automatico dopo errore; motore nativo mantenuto e selezionabile internamente via MACSYNC_INTERNAL_TRANSFER_ENGINE=native al lancio, nessuna UI. Test core esistenti continuano con nativo; CI aggiunge un test integrato con helper reale.
* Il motore non modifica SQLite, le cancellazioni, l'identità delle radici, la pubblicazione esclusiva e i backup. Il controllo POSIX ENOTSUP (45) per nuove pubblicazioni resta attivo: Rclone non risolve da solo un limite SMB. Il problema database is locked è distinto e non è dichiarato risolto.
* Solo statistiche numeriche dei log JSON elaborate; nessun percorso assoluto o credenziale nei log. Media live indicativa, conferme e storico restano quelli di MacSync. Una syscall SMB bloccata può ritardare stop; nessuna garanzia di timeout kernel o resistenza a una sostituzione concorrente di percorso tra controlli.
* Rclone mantiene mtime, ma la copia dei metadati estesi macOS non equivale a Foundation; verificare ACL/attributi sui dati di prova. La verifica integrata non è una rilettura completa dal server. Nessuna modifica a strategia backup o rename esclusivo fino a prova SMB.
* Candidato soltanto: eseguire CI, verificare package e firma, collaudo reale iMac/SMB/VPN, e solo dopo pubblicare come pre-release firmata. Non sostituire tag/asset precedenti.
