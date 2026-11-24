# MacSync v0.19.1 — Aggiornamento di collaudo (build 199)

- Rettifica SMB con verifica indipendente del nome esatto e dell'identità persistente, supporto della rappresentazione SFM della voce originaria, rifiuto delle collisioni e nessuna sovrascrittura.
- Modalità sperimentale facoltativa solo sorgente oppure solo destinazione: conserva la coda, sospende monitoraggio e sincronizzazione fino a nuova verifica archivio manuale. Modalità coordinata invariata per impostazione predefinita.
- Diagnostica distinta per accesso alle credenziali SMB; controllo preventivo prima della mutazione locale.
- Riduzione delle contese SQLite, attesa delle attività di manutenzione, conferma della selezione e salvataggio dei conteggi effettivi del ciclo.

## Prima del collaudo

Conservare un backup esterno verificato dei dati, impostazioni e database. Usare Impostazioni → Aggiornamenti software → Controlla e verificare versione 0.19.1 (199). Non azzerare automaticamente il database; tenere copie e mirror sospesi durante le prime prove e verificarne esplicitamente le autorizzazioni. Provare prima su dati sintetici.

La scansione dei nomi e la verifica archivio continuano a usare il filesystem montato. Le voci totalmente invisibili a macOS non sono selezionabili; il supporto SFM riguarda i nomi rilevabili. La CI macOS e il banco Samba verificano scenari sintetici, non certificano il funzionamento con Windows Server, Finder, Portachiavi o VPN reali. La release precedente rimane disponibile. Il pacchetto è firmato ad hoc e l'aggiornamento è verificato da Sparkle Ed25519; non è una notarizzazione Apple.
