# MacSync v0.18.15 — Aggiornamento di collaudo

Questa è una release stabile **solo per il canale tecnico di aggiornamento**: versione numerica necessaria per la verifica del feed firmato nell'app già installata. **Non è una dichiarazione di idoneità all'uso su archivi di produzione**. Il collaudo sulla connessione Finder SMB/Windows Server 2016 reale è ancora necessario.

## Novità rispetto a v0.18.13

- Verifica archivio QUICK/INTELLIGENT più efficiente, eliminando la scelta DEEP dall'interfaccia senza disabilitare controlli interni, SHA-256 selettivo o protezioni.
- Stabilità della rettifica dei nomi incompatibili su SMB: letture prudenti del fingerprint dopo la convergenza dei metadati, helper di rinomina protetto, stato persistente per lato e mantenimento in coda dei casi incerti.
- Piano di nomi coordinato: continuano le copie indipendenti senza ripetere copie sui percorsi con una rettifica pendente; audit e mirror rispettano le protezioni sui percorsi correlati.
- Migliore gestione dei montaggi Finder che ricompaiono con un diverso percorso, previa verifica dell'identità della condivisione e della cartella. Nessuna accettazione indiscriminata del nuovo volume.
- Interfaccia più reattiva durante scansioni e registri molto estesi: paginazione, letture SQLite per le viste, coalescenza degli aggiornamenti di avanzamento e annullamento più visibile.
- Controllo dell'arresto dei processi Rclone senza attendere l'output: conserva i job non confermati. Non riguarda l'helper remoto di rinomina protetta.
- Riduzione del carico degli aggiornamenti diagnostici: coda limitata con backpressure senza perdere eventi, aggiornamenti grafici adattivi a carico termico e ritardi UI.

## Aggiornamento dall'app esistente

1. Terminare le attività e verificare che non vi siano scritture o rettifiche in corso.
2. Da **Impostazioni > Aggiornamenti**, scegliere **Controlla aggiornamenti**. La disponibilità richiede questa release pubblicata come ultima release non pre-release e il feed `appcast.xml` Ed25519 valido.
3. Accettare il normale arresto delle operazioni e la preparazione dello snapshot locale prima dell'installazione. In caso di errore la sostituzione viene bloccata.
4. Riavviare l'app e verificarne la versione `0.18.15`; controllare configurazioni, coda e disponibilità destinazioni. Le autorizzazioni alle copie automatiche e al mirror vanno riabilitate esplicitamente dopo l'aggiornamento.
5. Eseguire i primi test soltanto su cartelle di prova, verificando file, interruzioni, ripresa e rettifiche SMB.

L'app va eseguita da `/Applications/MacSync.app` o `~/Applications/MacSync.app`. Se il riavvio o il controllo del database falliscono, consultare il recupero protetto `update-backups`; **mai** sostituire manualmente il database con uno snapshot più vecchio.

## Validazione e limiti

Il pacchetto macOS universale è compilato per Intel e Apple Silicon, con Rclone e helper SMB inclusi. CI macOS, test di regressione, pacchetto ZIP/DMG e verifica di firma Sparkle sono prerequisiti alla pubblicazione. Solo la firma di produzione con chiave protetta abilita l'aggiornamento dall'app; una build ad hoc della CI senza tale firma non è installabile via Sparkle. Restano aperti test fisici su iMac, SMB/Windows Server e VPN, incluso Gatekeeper e recupero da aggiornamento interrotto. Nessuna modifica grafica delle schede prevista in questa release.
