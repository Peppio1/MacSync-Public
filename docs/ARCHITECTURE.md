# Architecture and safety strategy

Mac source directories -> FSEvents -> durable SQLite journal -> single serialized sync worker -> selective rclone SMB operations -> existing Windows Server 2016 share.

## Safety invariants
- Only Mac is authoritative for configured mirror pairs.
- No server-side software or writable state outside destination files.
- Disconnected SMB/VPN, inaccessible source, dropped events, unresolved errors or invalid mappings = pause, never purge.
- During bootstrap, existing remote-only files MUST NOT be deleted automatically. Establish and verify a baseline first.
- Remote deletes require verified absence of originally tracked local paths, source root available, matching inventory state and healthy remote.
- Bulk deletion threshold causes pause and requires intervention.
- No full remote scan every 5 minutes; allow first baseline and occasional deliberate reconciliation.
- The app provides a **mirror, not a versioned backup**. Keep separate server backups.

## Correctness details
- Persist FSEvents event ID and inspect MustScanSubDirs, UserDropped and KernelDropped flags.
- Treat watcher notifications as hints; resolve actual filesystem state before enqueuing safe work.
- On watcher overflow or downtime, reconcile local inventory first; reconcile server during scheduled audited maintenance.
- Ignore temporary active writes until stable; copy to remote temp then commit to final filename when possible.
- Rename may be validated as a create of new path plus delete of old tracked path.
- Every queued operation is retriable, idempotent and logged without secrets.
- No credentials or private server paths in GitHub.

## Mandatory test phases
1. Synthetic directories and no remote destructive operations.
2. Copies, edits, deletes and renames against temporary SMB test share.
3. VPN disconnected mid-copy, reconnect, Mac sleeps/boots, missing source folder.
4. Bulk-delete fail-safe, partial PSD writes, inode/path changes, dropped FSEvents.
5. Representative archive performance tests and safe non-destructive bootstrap.
6. Only after successful tests permit any production mirror deletion.

## Stato implementato al 13 novembre 2026

Il monitor FSEvents macOS aggiorna l'inventario SQLite locale: prima scansione completa locale, successive scansioni mirate per file o sottoalbero, audit locale al riavvio e ogni 24 ore, retry locale dopo errore. Nessuna connessione SMB o modifica di file sul server è attualmente attiva. Test automatici e smoke-test FSEvents superati sul runner macOS 15.

## Experimental SMB copy engine (v0.3)
SelectiveSMBCopyWorker filters pending UPSERT entries from SQLite, checks that source paths stay inside configured local roots, forbids symlinks, and starts one rclone copyto per regular file or rclone mkdir for tracked directories. It checks source file size, inode and modification timestamp after a successful copy, then acknowledges that queue ID. If a file is still being written, disappears, or rclone fails, the pending record is retained. It cycles through queue IDs to prevent one failed file starving later files. No deletes are executed and sync recursion is never invoked.

The operator MUST explicitly enable uploads on each app run and use TEST folders only; the endpoint is a locally defined rclone SMB remote. No Windows server installation. The UI does not persist upload enablement and no Keychain integration exists yet. Existing rclone config files are locally managed and may contain obscured (not securely encrypted) passwords.

Before production: verify over actual VPN/SMB, perform a safe initial baseline, implement temp upload and atomic rename, prevent accidental overwrites, migrate credentials to Keychain, add unattended login and error notifications, and separately implement guarded deletes after extensive tests.

## v0.4 — temporanei, Portachiavi, verifica iniziale

Il worker di test usa rclone copyto per caricare UN file in una posizione .macsync-staging/<UUID>.partial del remote, confronta un nuovo lstat con lo snapshot sorgente e usa rclone moveto per pubblicare sul percorso di destinazione. Dopo la pubblicazione ricontrolla ancora il sorgente; solo in caso di successo marca il job SQLite come completato. In caso di errore il job rimane nella coda e NON viene eseguita nessuna cancellazione remota. Lo staging può accumulare residui: pianificare garbage collection limitata al solo prefisso gestito da MacSync, dopo test.

Password SMB conservata nel Keychain utente via Security.framework. Il comando rclone obscure - riceve la password su STDIN; la configurazione SMB temporanea viene passata a rclone tramite RCLONE_CONFIG_MACSYNC_SMB_* in environment, mentre RCLONE_CONFIG è /dev/null. Le preferenze ordinarie su host/utente/dominio/share non contengono password. Non usare debug o dump di environment per non esporre i dati.

Il pannello di test costruisce il percorso sandbox remote:share/MacSync_TEST_ONLY/<sottocartella>; non esegue mai scritture nel percorso produttivo. Il pulsante di anteprima legge le vere sottocartelle remote con rclone lsjson --recursive --files-only, solo quando richiesto esplicitamente: NON ad ogni ciclo di cinque minuti. Il confronto di metadati non prova l'identità del contenuto e NON autorizza cancellazioni.

Da verificare prima della produzione: rclone moveto su backend SMB Windows 2016 e atomicità effettiva, tolleranza date e timezone, comportamento su VPN instabile, file aperti PSD, riallineamento manual seed 100 GB, sicurezza completa delle credenziali, performance e backup indipendenti.

## Current implementation
This repo begins with SQLite queue + safety checks + menu bar placeholder and CI. It does **not** perform real SMB transfers yet.