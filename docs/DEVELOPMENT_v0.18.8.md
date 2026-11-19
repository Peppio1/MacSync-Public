# MacSync v0.18.8 — passaggio di consegne

## Punto di partenza

Questo documento raccoglie le decisioni di progettazione e le proposte da verificare. La v0.18.8 è un candidato di sviluppo da convalidare. Base rilevata nel ramo `develop-v0.18.7`: [c7d28b3b877d69020fddd7b93ac85fa55d64e92d](https://github.com/Peppio1/MacSync-Public/commit/c7d28b3b877d69020fddd7b93ac85fa55d64e92d). Il ramo di documentazione parte da quel commit. Il precedente resoconto indicava CI v0.18.7 verde. Prima di usare il commit come baseline di rilascio, verificarne il run e gli artefatti in GitHub Actions.

- [Rclone diretto e limiti](DEVELOPMENT_v0.18.6.md)
- [Registri e paginazione v0.18.7](DEVELOPMENT_v0.18.7.md)
- [MacOS CI](../.github/workflows/macos-ci.yml) e [regole del progetto](../AGENTS.md). Le sezioni storiche di AGENTS.md descrivono versioni precedenti.

## Decisioni da conservare

1. MacSync replica dal Mac verso cartelle locali o una condivisione SMB già montata nel Finder. L'app usa FSEvents, inventario e coda SQLite, controlli di identità e stabilità, pianificazione, ripetizione dei tentativi, UI e registri. Il ciclo ordinario lavora sui percorsi in coda senza enumerare ricorsivamente la destinazione. Il normale spostamento di un utente continua a seguire la politica esistente di copia del nuovo percorso e cancellazione autorizzata del precedente.
2. Rclone incorporato è il motore di trasferimento diretto della baseline. Usare `copyto` senza `--inplace` e azioni puntuali su percorsi autorizzati. MacSync conferma l'esito del singolo job e conserva i casi incerti. Escludere `rclone sync`, purge, cancellazioni ricorsive, credenziali SMB nell'app e cambi automatici di motore in seguito a errore. Mantenere l'alternativa interna per rollback controllato. La destinazione deve avere un solo scrittore operativo. Il rename di pubblicazione di Rclone non offre compare-and-swap o backup indipendente della versione precedente.
3. La scheda **Nomi incompatibili** ha un pulsante **Scansiona nomi incompatibili**. Scansiona entrambi i lati, con un esito indipendente per lato. **Verifica archivio** rileva gli stessi problemi durante l'enumerazione che esegue già. Condividere regole e persistenza. Conservare l'impostazione della lista attuale, il dettaglio per voce, ricerca, filtri e azioni Finder. Mostrare totali distinti per sorgente/destinazione e file/cartelle.
4. Salvare gli esiti in SQLite, per coppia, lato e generazione di scansione. Alla riapertura, caricare rapidamente il risultato precedente con query indicizzate e paginazione. Indicare ultimo aggiornamento, risultato parziale e destinazione indisponibile. Una scansione interrotta o incompleta non certifica la scomparsa di anomalie. Invalidare la generazione al cambio di coppia o identità del volume.
5. La rettifica, una volta avviata, decide automaticamente su quale lato o su entrambi intervenire. Evitare ricopie quando si può identificare in modo affidabile lo stesso elemento. Riconciliare inventario e coda, compresi i discendenti di cartelle rinominate. Considerare le correzioni pregresse ricostruibili da evidenze locali. I conflitti ambigui restano visibili. Nessuna deduzione di identità basata soltanto sul nome simile o su dimensione e data. La rettifica coordinata è un flusso di manutenzione dedicato.
6. **Verifica archivio** resta separata dal ciclo ordinario, con confronto rapido o approfondito, diagnostica in sola lettura e riparazioni UPSERT esplicite. Rilevare i nomi incompatibili passivamente anche in modalità diagnostica. Nessuna cancellazione di file extra come effetto dell'audit.
7. Reattività durante scansioni, sincronizzazioni e rettifiche. File system, SMB, Rclone, decodifica e query pesanti fuori dal thread UI. Inviare aggiornamenti raggruppati, usare pagine e mantenere navigazione, scroll e filtri disponibili. Stop e annullamento devono rendere subito visibile lo stato di richiesta, anche se l'I/O SMB in corso impiega tempo a rientrare. Riutilizzare la paginazione e la correlazione ciclo/job dei registri v0.18.7. Conservare contatori operativi dal riepilogo e dallo storico e distinguere righe visibili, anomalie, esiti incerti e operazioni concluse.

## Modifiche proposte dopo la revisione

### Rendere recuperabile la rettifica

Prevedere anteprima e conferma di lotto. Il termine automatico si riferisce alla scelta dei lati e all'esecuzione coordinata dopo conferma. Scansioni e audit restano diagnostici per i nomi. Pianificare e ricontrollare collisioni Windows/SMB, nomi riservati, punti e spazi finali, maiuscole/minuscole e normalizzazione Unicode. Per i cambi che richiedono un nome intermedio, riservare un percorso univoco e registrarlo prima di usarlo.

Sospendere e drenare il worker per la coppia interessata, mantenendo il monitoraggio. Registrare su SQLite intento e fasi, ricontrollare identità e percorsi prima di ogni mutazione, aggiornare inventario e coda alla riconciliazione. Un crash fra filesystem e SQLite deve lasciare una rettifica riprendibile o sospesa con ragione esplicita. Il rollback dei nomi è condizionato alla verifica di identità e all'assenza di collisioni. Su SMB disconnesso attendere il rientro del volume verificato. Vietare sovrascritture o eliminazioni per risolvere conflitti. Preferire una rename nativa sullo stesso volume. Considerare Rclone per le rettifiche soltanto se il percorso adottato garantisce una rinomina senza ripiego su copia e cancellazione.

### Misurare l'audit prima di cambiare backend

Usare il motore di enumerazione attuale come riferimento. Provare `lsjson` dietro un percorso sperimentale, a parità di classificazione, copertura, semantica dei nomi e trattamento degli errori. Selezionare il parallelismo con prove 2/4/8 su fixture sintetiche da 10.000, 50.000 e 200.000 file, in locale e su SMB di test. Registrare durata, tempo ai primi risultati, memoria, traffico osservabile e accessi ridondanti. La cache accelera consultazione e confronti dove valida per identità e generazione. L'enumerazione diagnostica non deve usare risultati vecchi come prova di assenza. Promuovere il nuovo enumeratore soltanto con parità funzionale e vantaggio misurabile su SMB.

### Verificare la reattività dal punto di vista utente

Tracciare la latenza di navigazione, ricerca e richiesta di annullamento mentre girano scansioni, trasferimenti e rettifiche. Verificare che la finestra resti utilizzabile anche simulando SMB lento o interrotto. Misurare anche il tempo necessario per aprire la lista dalla cache dopo il riavvio, senza nuova scansione. Ridurre contesa SQLite con transazioni brevi, pagine e riuso delle connessioni di lettura già previste. Definire i limiti di latenza dopo la misurazione della baseline.

## Sequenza di sviluppo e collaudo

1. Derivare `develop-v0.18.8` dal commit di questa nota e fissare un riferimento di rollback sulla baseline verificata. Prima di cambiare schema, provare migrazione del DB precedente, riapertura e compatibilità dell'eventuale rollback applicativo in un ambiente sintetico. Un rollback Git non ripristina filesystem, inventario o coda.
2. Integrare modifiche in commit verificabili: reattività e letture, rilevamento/cache dei nomi, rettifica coordinata, poi benchmark dell'audit e ottimizzazioni ammissibili. Obiettivo di un unico aggiornamento finale. Nessuna release intermedia necessaria.
3. Su macOS 15 eseguire `swift test -Xswiftc -warnings-as-errors` secondo CI. Preparare il binario Rclone con `Packaging/prepare-rclone.sh` e l'ambiente della pipeline. Abilitare il ramo di sviluppo nel workflow o usare l'avvio manuale. Ripetere regressioni Rclone e registri, anteprime UI con fixture, build Intel/Apple Silicon, pacchetti e test updater/recupero.
4. Provare nomi incompatibili, collisioni, cartelle annidate, correzioni pregresse, assenza di ricopie, database precedente, scansioni annullate e interruzioni in ciascuna fase di rettifica. Su Mac con cartelle sintetiche e share SMB montata dal Finder, provare condivisione lenta, disconnessione e riconnessione, esiti incerti, permessi e stabilità dei trasferimenti. Confermare nessuna enumerazione SMB completa nella sync ordinaria.
5. Registrare gli esiti effettivi e il commit collaudato. Preparare firma e pre-release solo dopo verifiche e processo di rilascio del progetto. Aggiornare questa nota con i punti risolti, i risultati riproducibili e le questioni aperte.

## Ripresa da un altro account o PC

Aprire il ramo `docs-v0.18.8-handoff` in MacSync-Public e partire da questo documento e dalle note v0.18.6/v0.18.7 collegate. La lettura del repository pubblico è accessibile da altri account. Per contribuire direttamente serve un account GitHub con permessi di scrittura. Per compilazione e test resta necessario macOS o un runner macOS. Nel repository usare percorsi, immagini, log, dataset e database sintetici. Escludere configurazioni operative, credenziali, chiavi private, indirizzi, percorsi, log e screenshot reali.


## Prima integrazione

- Ramo candidato: `develop-v0.18.8`. Base di rollback: `rollback-before-v0.18.8`. Un solo invio iniziale alla CI, con versione bundle 0.18.8/188.
- La scansione dedicata è di sola lettura e conserva l'ultimo esito verificato di ciascun lato. La Verifica archivio riusa le proprie enumerazioni. SQLite memorizza uno snapshot indicizzato per coppia e lato, letto fuori dal thread dell'interfaccia. La lista usa rendering differito delle righe; una paginazione SQL per singola voce rimane da valutare con misure su archivi grandi.
- La rettifica espande alle voci note con lo stesso percorso nella stessa coppia e chiede conferma del lotto. La destinazione deve avere un binding persistente verificato. Si usa una rinomina esclusiva sul volume attuale: il supporto effettivo di RENAME_EXCL su SMB va collaudato. Un esito incerto interrompe il lotto. Le copie automatiche e il mirror restano sospesi; dopo il riavvio dell'inventario, eseguire Verifica archivio prima di rimettere in marcia le copie.
- La rettifica invalida la cache prima della mutazione e registra intento ed esito nel registro locale. Il recupero automatico delle rettifiche pregresse e la ripresa transazionale di un lotto interrotto restano da implementare. I due filesystem non costituiscono una transazione unica. Non eseguire il candidato su dati reali.
- L'enumeratore dell'audit e il motore Rclone dei trasferimenti restano quelli della baseline. Promozione di lsjson e scelta del parallelismo restano subordinati al benchmark. Le prove macOS, il collaudo SMB e le misure della UI sono separati dai controlli sintattici eseguiti in Linux.
