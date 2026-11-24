# MacSync v0.19.0 — Aggiornamento di collaudo (build 198)

- Contatore dei nomi incompatibili cumulativo sui due lati, rettifiche coordinate e gestione indipendente dei gruppi pendenti.
- In caso di mancata rinomina certa sul secondo lato, ripristino prudente del nome locale; se l'esito remoto è incerto, conservazione del piano e protezione dei percorsi. Nessuna sovrascrittura automatica.
- QUICK e INTELLIGENT possono accodare file e cartelle extra validati anche con mirror disattivato. La verifica non elimina dati dal server. Le cancellazioni sono eseguite solo con nuova autorizzazione esplicita al mirror, dopo le verifiche di sicurezza previste.
- Aggiornamento della cache dopo rollback; compilazione universale Intel/Apple Silicon.

## Prima del collaudo

Conservare un backup esterno verificato di database, impostazioni e log. Installare tramite Impostazioni → Aggiornamenti software → Controlla; verificare versione 0.19.0 (198). Non è necessario azzerare automaticamente il database. Mantenere copie automatiche e mirror disabilitati durante i primi controlli, verificare i percorsi e la coda, provare le rettifiche su dati sintetici prima di riattivare operazioni distruttive. La nuova autorizzazione mirror comprende i candidati pregressi verificati.

I test mirati su macOS e il banco Samba sintetico non sono una certificazione dell'archivio operativo Windows Server/Finder/VPN. Il test SMB del nuovo helper non copre Portachiavi, cadute di rete o rollback bilaterale sul server reale. La release precedente rimane disponibile.
