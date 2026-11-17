# MacSync v0.18.1 — Aggiornamento di collaudo

- Panoramica: differenze rilevate cliccabili sopra i riepiloghi affiancati di sorgente e destinazione; indicatori di lettura più espliciti con informazioni contestuali.
- Durante la sincronizzazione, i risultati dell'ultima verifica sono identificati come dati storici; nessuna scansione aggiuntiva introdotta da questa modifica grafica.
- Layout più compatto; rimane disponibile lo scorrimento verticale quando necessario. La rifinitura sarà affrontata in un aggiornamento successivo.
- Motore, database e protezioni invariati rispetto al candidato di collaudo.

Pacchetto esatto della CI [44198040306](https://github.com/Peppio1/MacSync-Public/actions/runs/44198040306), commit 1896b3d4d8dc8bae13c29ea90f2e413b0adf5f89: 194 test ordinari superati, 3 opt-in saltati nella suite ordinaria, 4 test UI eseguiti separatamente, 50 PNG validati, build universale Intel/Apple Silicon e laboratorio Sparkle completati.

macOS 13 o successivo. Aggiornamento di collaudo, non una dichiarazione di stabilità definitiva: collaudo fisico macOS/SMB/VPN e notarizzazione Apple ancora da effettuare. Dopo l'aggiornamento verificare configurazione e archivio prima di riabilitare gli automatismi. Non ripristinare database precedenti sopra dati più recenti.
