# MacSync — Architettura v0.8 (prototipo)

## Flusso
Cartella Sorgente macOS → FSEvents → inventario e coda SQLite → worker seriale → cartella Destinazione (locale oppure SMB già montata dal Finder). Nessun componente sul server Windows 2016; macOS gestisce il login SMB esistente.

L'app permette due coppie separate di cartelle: Cartella_1 e Cartella_2. Una finestra di configurazione persistente (apribile dall'icona menu bar) offre NSOpenPanel e trascinamento Finder (UTType.fileURL), senza chiudersi quando si passa al Finder. Le coppie non devono sovrapporsi, anche tra coppie.

## Monitor e database
- Alla partenza: scansione locale della sorgente, recupero modifiche durante lo spegnimento, FSEvents dal cursore impostato prima dell'inventario iniziale.
- Durante l'attività: scansioni mirate a file o sottoalberi; query SQLite indicizzate. Nessuna scansione ricorsiva SMB ad ogni 5 minuti.
- Eventi persi, root non disponibile ed errori: interrompere i processi potenzialmente distruttivi, ritentare con scansione locale programmata.
- ChangeJournal ha righe upsert e delete, ma solo upsert sono consumati dal worker di copia. Nessun worker di cancellazione è disponibile.
- Cambio sorgente: dopo avviso esplicito, reset del solo inventario locale relativo, senza cancellare alcun file; cambio destinazione: riprepara gli upsert dei file sorgente tracciati.
- SQLite WAL in ~/Library/Application Support/MacSync/inventory.sqlite.

## Motore di trasferimento
- Controllo della disponibilità di Sorgente/Destinazione e fingerprint del volume scelto, per evitare scrittura in un mount point SMB divenuto una cartella locale.
- Validate path relativo dentro la mappatura. Rifiuta symlink come file o nelle gerarchie destinazione; niente shell né processo rclone.
- Per un singolo file (PSD/DNG/JPG ecc): copia tramite Foundation FileManager in .macsync-staging/<UUID>.partial dentro destinazione, poi verifica local file size, modification time e inode (lstat). Se stabile, sposta il temporaneo al percorso definitivo; se già esiste, utilizza replaceItemAt con backup senza cancellazione automatica. Verifica nuovamente il sorgente e solo dopo completa il job SQLite.
- Job falliti o deferred rimangono in coda, con registro dettagliato e ritentativi. In caso di errore, i file temporanei possono rimanere e devono essere puliti solo con regole di sicurezza future.
- Versione attuale: copia attivabile soltanto manualmente e per la sessione corrente. Lo spostamento può sovrascrivere un file esistente nella destinazione che l'utente ha scelto.

## Storico
SyncActivityLog crea una tabella SQLite sync_activity con timestamp, livello, root ID, azione, percorso relativo, byte, durata ed esito. Il menu bar presenta gli ultimi 200 record ed esporta fino a 5000 righe TSV; controllare i nomi file prima di condividere i log. Registro non contiene password o indirizzi IP. Future attività: filtraggio, retention/rotazione, diagnostica per codice errore.

## Anteprima di baseline
MountedBootstrapPreview esegue una scansione completa delle due cartelle selezionate solo su richiesta dell'utente e senza scrivere. BootstrapPlanner classifica i file già presenti: match presunti (size+mtime), mismatch, server-only, conflitti case insensitive. Non autorizza automaticamente il salto di trasferimenti né le cancellazioni.

## Protezioni v0.6
- Prima di ogni file copy, TransferPreflight.availableBytes legge statfs sul volume destinazione. Richiede capacità per staging + backup della vecchia versione + 16 MiB; valori non dichiarati vengono trattati come capacità sconosciuta, non come certezza di spazio.
- Dopo FileManager.copyItem verso .macsync-staging, un nuovo lstat controlla file regolare e dimensione attesa. Solo allora si procede con la verifica del sorgente e la pubblicazione. Errori rinviati lasciano job e file temporaneo; la pubblicazione su SMB deve essere ancora testata.
- StagingMaintenance.inspect conta e misura UUID.partial vecchi 7 giorni solo dentro .macsync-staging, senza ricorsione. StagingMaintenance.cleanup elimina esclusivamente elementi esplicitamente approvati dopo nuova verifica dell'ID del volume, inode, dimensione e mtime. UI blocca pulizia con copie attive e mostra conferma; niente pulizia dei backup.
- SyncActivityLog.recent supporta filtro esito e ricerca su file relativo/messaggi, export filtrato e prune del solo sync_activity (fino a 20.000 record o 90 giorni). Timer continua a lavorare ogni 5 minuti senza interrogazione ricorsiva SMB.
- Limiti non risolti: mancanza di resume byte-per-byte, hash, spazio backup illimitato, atomicità effettiva SMB, test rete/permessi reali, montaggio automatico, bootstrap e cancellazioni speculari.

## v0.7 — checksum forte dei file già seminati
- `SeededArchiveVerifier` scorre con paginazione soltanto i job `upsert` pendenti in SQLite, senza lanciare un `rclone sync` né enumerare la destinazione completa ogni cinque minuti. Per il candidato con stessa dimensione, verifica percorsi e volume, quindi legge sorgente e destinazione in streaming a blocchi di 1 MiB, calcolando SHA-256 con CryptoKit. Dimensione e timestamp da soli non provano mai l'uguaglianza.
- `SeedFileFingerprint` conserva dev/inode, size, mtime e ctime con precisione nanosecondi prima/dopo la lettura per accorgersi dei file cambiati. La GUI mostra progresso, byte letti e annullamento. Un file diverso o non disponibile resta in coda.
- `approve` è una operazione SEPARATA, approvata esplicitamente: dopo verifica delle fingerprint, `ChangeJournal.acknowledgeVerifiedFiles` esegue una sola transazione SQL con UPDATE condizionale su id/root/path/kind upsert, metadati inventario e root associata. Job rimpiazzati da FSEvents, file cambiati o cambi di root non sono marcati; DELETE mai consumati. Nessun file viene scritto o eliminato alla destinazione da questa procedura.
- La lettura SHA-256 del contenuto già presente su SMB CONSUMA comunque banda VPN, anche se evita la riscrittura. Potenziale lettura di 100 GB remoti per 100 GB già identici, oltre ai 100 GB locali. Il confronto su una cartella grande è un'operazione manuale una tantum.
- Condizione di test: GitHub Actions macOS su cartelle locali; servono prove reali di latenza/performance SMB su server Windows 2016 e iMac Sequoia prima dell'attivazione nell'archivio di produzione.

## v0.8 — modello di sicurezza cancellazioni, recupero e retention
### Autorizzazione
`MirrorDeletionPolicy` espone tre opzioni persistenti: `enabled` (default false), `recoveryEnabled` (default true), `retentionDays` (1–30 o nil=never). Le impostazioni non sono una capability: solo una sessione espressamente confermata crea `MirrorDeletionWorker`. L'avvio avviene sulla worker queue, catturando timestamp baseline, conteggio locale >0, device/inode di source e target e fingerprint del volume. Gli eventi DELETE antecedenti all'arming restano esclusi.
### Gate pre-rimozione
Prima di ogni lotto si contano TUTTI i DELETE della sessione. Con >=250 eliminazioni, o >=25 e >=10% dei file iniziali, il worker blocca il lotto. I conteggi comprendono anche le cancellazioni già completate nella sessione, per impedire aggiramenti tramite lotti piccoli in cicli differenti. Per ogni batch viene eseguita UNA scansione della sola Sorgente locale; le operazioni verificano root, volume, assenza reale sorgente anche nel caso di symlink, stato corrente in SQLite e nessun upload concorrente. Le cancellazioni su destinazione usano POSIX unlink per file regolari e rmdir solo per directory vuote; symlink e oggetti speciali non sono eliminati. La coda viene chiusa con UPDATE condizionale sul job originale.
### Recupero
Se il recupero è abilitato, invece di unlink il file target viene spostato all'interno dello stesso volume target in `.macsync-recovery/<UUID>/<percorso relativo>`: lo spostamento non ricopia i byte sulla VPN. Il manifest SQLite locale `mirror_recovery` tiene data, inode, mtime, size, durata e scadenza. `nil` significa conserva sempre. La funzione di scadenza opera soltanto quando la modalità speculare con recupero e retention finita è attiva; ricontrolla inode/mtime/size, root e volume prima di usare unlink. Non tenta cleanup su symlink, oggetti modificati o volumi sostituiti. Operazioni incompiute possono lasciare file orfani recuperabili, mai pulizia indiscriminata.
### Limiti da testare
Transazioni SQLite e filesystem non formano una transazione distribuita: un crash dopo move/unlink può lasciare il job pendente, ma non determina una seconda cancellazione arbitraria. Il recupero resta nascosto dentro target, non esiste ancora un restore guidato e può consumare spazio. I test CI coprono cartelle locali; per cancellazioni reali, ACL Windows, VPN instabile e semantica SMB sono indispensabili test su share di prova. Rinominare/spostare oggi comporta copia del nuovo file e successiva cancellazione vecchio, non moveto nativo.

## Rischi non ancora risolti
- Automatic login SMB e rimontaggio Finder dopo cambio VPN/sospensione/riavvio.
- Foundation.replaceItemAt e atomicità su Windows SMB: test con vere grandi foto richiesti.
- La verifica SHA-256 dei file già caricati evita la ricopia ma legge comunque tutto il loro contenuto su SMB; valutare il primo seed USB con manifest hash e prove reali di banda.
- Pulizia temporanei vecchi disponibile su approvazione; verifica backup/versionamento e quota spazio server ancora necessari.
- FSEvents e file in scrittura/rename/permessi: necessita collaudo prolungato.
- Eventuali cancellazioni speculari in futuro richiedono policy fail-closed rigorosa e snapshot/verifiche dei percorsi.
- Test GitHub Actions macOS 15 non provano la VPN o i volumi reali.

## Privacy
Non caricare fotografie, DB reali, file di configurazione privati, password o log sensibili nel repository. Le destinazioni non devono mai essere lette/riutilizzate come sorgente per una copia inversa.
