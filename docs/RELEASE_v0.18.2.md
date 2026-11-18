# MacSync v0.18.2 — Aggiornamento di collaudo

- Riconoscimento indipendente delle cartelle già presenti e confronto prudente dei file, con verifica SHA-256 selettiva.
- Gestione più robusta di pubblicazioni SMB, collisioni, errori, tentativi successivi e temporanei verificabili. Nessuna sovrascrittura o rimozione automatica dei residui di identità incerta.
- Esclusione configurabile di .DS_Store (attiva di default), contatori coda distinti, cache di sola lettura del confronto e scansione destinazione ottimizzata.
- Svuotamento della coda con backup SQLite verificato, blocco persistente e ricostruzione mediante audit esplicito. Conservazione delle autorizzazioni e degli intenti di pubblicazione in sospeso; nessun riutilizzo improprio di vecchie evidenze di cancellazione.

Pacchetto esatto della [CI 44346034899](https://github.com/Peppio1/MacSync-Public/actions/runs/44346034899), commit b6c7b1cbd90edd72d0a63eb173df251834d9e364: 212 test ordinari superati, 4 riservati a prove dedicate; benchmark 200.000 file e 48.000 cartelle per lato, 50.000 differenze autentiche accodate dopo reset senza scritture di destinazione, 4 test UI, 50 PNG, build universale, laboratorio Sparkle di installazione e recupero superati. Il confronto/accodamento sintetico di 50.000 differenze ha richiesto 73,61 s, non rappresentativo di SMB/VPN.

**Release di collaudo, non certificata per uso produttivo.** macOS 13 o successivo, Apple Silicon e Intel. Collaudo fisico iMac/SMB Windows Server/VPN e notarizzazione Apple ancora da effettuare. L'interfaccia di aggiornamento installa solo dopo backup verificato; al riavvio verificare configurazione e mantenere sospesi automatismi e cancellazione speculare. Provare prima una coppia di cartelle sintetiche, poi validare archivio e coda reali. Non ripristinare database precedenti su dati più recenti.
