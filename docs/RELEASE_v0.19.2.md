# MacSync v0.19.2 — Aggiornamento di collaudo

Build 200, macOS 13 o successivo, Intel e Apple Silicon.

- Rettifica locale dei nomi incompatibili, gestione delle collisioni e coda persistente; richiesta di conferma con timeout di 60 secondi.
- Gestione prudente delle cancellazioni e riconciliazione della coda su destinazioni SMB montate; rimozione del motore SMB remoto separato.
- Ripristino volontario alla versione precedente firmata, con backup preventivo e conservazione del database corrente.
- Validati test mirati, laboratorio Samba montato, rollback isolato con pacchetto firmato precedente, compilazione universale e laboratorio Sparkle.

Versione di collaudo, non una dichiarazione di stabilità operativa. Conservare un backup, controllare le impostazioni e verificare con dati sintetici prima di riattivare il mirror. Il collaudo fisico macOS/Windows Server/VPN e il riavvio reale dopo rollback restano necessari. Non eseguire downgrade manuali non verificati.
