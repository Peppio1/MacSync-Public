# MacSync v0.18.5 — Aggiornamento di collaudo Rclone

- Rclone 1.76.0 incorporato nel bundle universale, senza installazione separata. Copia dei soli file accodati verso lo staging della destinazione già montata tramite Finder.
- Nessuna scansione ricorsiva della destinazione nei cicli incrementali. FSEvents, SQLite, mirror, backup di sicurezza e pubblicazione esclusiva restano invariati.
- Motore nativo conservato per rollback interno, senza selettore grafico e senza fallback automatico dopo errore.
- Statistiche di copia in tempo reale; conferma e storico governati da MacSync.

## Validazione
Run CI 44554169135, tentativo 1, commit 5b6ba269f12f5d52fd5d239a60ec304fcfc4a5ea. 227 test elencati: 223 eseguiti senza errori, 4 saltati; due test dedicati al motore Rclone superati incluso helper reale, nuovo file, aggiornamento, errore e rollback nativo. Build Intel/Apple Silicon, DMG, 56 anteprime e laboratorio Sparkle superati. I due benchmark opzionali grandi archivi non sono stati rieseguiti. Artefatto 14547190018, SHA-256 verificato nella procedura di firma.

Versione di collaudo e non certificata stabile. L'errore SMB POSIX 45 e SQLite database is locked non sono dichiarati risolti. Prestazioni e affidabilità su iMac, VPN e Windows Server 2016 richiedono prove reali; iniziare con cartelle di prova e mirror disattivato. Conservare backup indipendenti. Rollback sorgente: rollback-before-v0.18.5-rclone. Il feed latest permette l'aggiornamento manuale dall'app; nessuna promozione a stabilità produttiva.
