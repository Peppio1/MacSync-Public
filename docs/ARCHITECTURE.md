# MacSync — Architettura v0.5 (prototipo)

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

## Rischi non ancora risolti
- Automatic login SMB e rimontaggio Finder dopo cambio VPN/sospensione/riavvio.
- Foundation.replaceItemAt e atomicità su Windows SMB: test con vere grandi foto richiesti.
- Inventario iniziale dei file già caricati sul server, evitando ricopia molto lenta.
- Staging temporanei e backup conservati; manca pulizia sicura e spazio minimo.
- FSEvents e file in scrittura/rename/permessi: necessita collaudo prolungato.
- Eventuali cancellazioni speculari in futuro richiedono policy fail-closed rigorosa e snapshot/verifiche dei percorsi.
- Test GitHub Actions macOS 15 non provano la VPN o i volumi reali.

## Privacy
Non caricare fotografie, DB reali, file di configurazione privati, password o log sensibili nel repository. Le destinazioni non devono mai essere lette/riutilizzate come sorgente per una copia inversa.
