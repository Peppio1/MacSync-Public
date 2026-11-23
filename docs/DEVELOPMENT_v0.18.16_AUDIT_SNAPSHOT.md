# MacSync v0.18.16 — verifica archivio a snapshot, ramo sperimentale

Stato: modifica **solo sul ramo di sviluppo**, basata sulla release firmata v0.18.15 (commit ad376a3fb8f7cf64a2fc3834f3b5320803d0b642). Rollback del CODICE: `rollback-before-v0.18.16-audit-snapshot`. Nessuna firma o pubblicazione autorizzata prima di verificare l'esito della CI e della prova SMB reale.

## Decisioni funzionali

- QUICK classifica file con percorso/tipo, dimensione e data/ora compatibili (tolleranza esistente 2 s) come **corrispondenti per metadati**, senza SHA-256.
- Una corrispondenza non dimostra l'identità dei byte. La destinazione è intesa con singolo scrittore operativo; l'audit non pretende di garantirne l'immutabilità dopo lo snapshot.
- La coda persiste `origin`: `initial_inventory`, `source_monitor`, `archive_audit`, `destination_rebind`, `legacy_unknown`. Solo gli UPSERT identificati con certezza come `initial_inventory` possono essere confermati quando QUICK/INTELLIGENT li ha trovati corrispondenti. FSEvents e operazioni storiche ambigue rimangono in coda.
- Se durante il confronto viene generato un nuovo evento FSEvents, questo prevale e rimane in coda. I controlli di sessione e il monitor gate devono continuare a interrompere verifiche invalidated.
- Nuove differenze missing/different generano solo UPSERT idempotenti con la guardia SQLite `enqueueAuditRepairs`; nessun DELETE viene creato. La successiva copia resta protetta dal motore ordinario.
- INTELLIGENT usa lo stesso inventario senza riconoscimento massivo, ma conserva hash SHA-256 selettivi sui file con dimensione uguale e mtime divergente di oltre 2 s, con verifiche di stabilità/fingerprint e cache validata.
- La modalità interna DEEP e la verifica SHA-256 esplicita per riconoscimento storico restano nel core. Non vengono modificate la rettifica dei nomi, il mirror o il motore di trasferimento.

## Implementazione sul ramo

1. `ArchiveAudit` classifica un mismatch di dimensione QUICK/INTELLIGENT utilizzando i metadati acquisiti durante l'inventario. Non esegue l'ulteriore lettura `safeURL+fingerprint` del file SMB in questa diramazione. DEEP mantiene la riconvalida legacy.
2. `SeededArchiveSession.auditPreservingQueuedChanges` esegue audit+accodamento delle differenze, **senza** `approve()` massivo dei job pendenti; chiama `ChangeJournal.acknowledgeInitialInventoryMatches` soltanto sui matching del report, esclusivamente SQLite, con origine esatta, guardie su inventario locale, radice, timestamp, job più recenti, intenti di pubblicazione, recuperi e blocchi.
3. `MountedCopyController.startArchiveAudit` usa il nuovo percorso sia per QUICK che per INTELLIGENT; rimuove la seconda fase `Riconoscimento automatico` e completa soltanto i job iniziali con matching confermato per metadati, senza rileggere SMB. Continua il backup preventivo DB, controlli di radice/volume, politiche di ricostruzione coda, salvataggio nomi/report e log.
4. Aggiornato il testo della scheda per chiarire la conservazione della coda.
5. Aggiunti test locali per: job FSEvents già pendente e matching QUICK; nuovo evento sorgente durante il confronto; INTELLIGENT con SHA selettivo e nuova differenza accodata, senza cancellare il job esistente.

## Limiti e validazioni richieste

- Un risultato QUICK è una diagnosi dei metadati **al tempo della scansione**, non un hash di contenuto. La scelta di non riconvalidare i file remoti riduce la garanzia contro modifiche esterne successive allo snapshot. Il requisito operativo prevede un solo scrittore autorizzato.
- L'inventario richiede comunque enumerazione directory SMB, controllo delle radici e lstat per elemento; **una sola acquisizione di metadati per file** non significa necessariamente una sola richiesta di rete in assoluto.
- INTELLIGENT continuerà a leggere i contenuti necessari agli hash selettivi e a effettuare le riletture di sicurezza prima/dopo tali hash.
- I job FSEvents e i job preesistenti classificati `legacy_unknown` per file corrispondenti restano in coda e possono comportare copie ridondanti: scelta esplicita per evitare perdita di aggiornamenti. Per nuove radici solo il primo inventario **verificato pristine nella transazione SQLite** produce `initial_inventory`; gli avvii successivi, la riconciliazione locale dopo crash e gli eventi FSEvents producono `source_monitor`. Riassegnazione destinazione produce `destination_rebind`, mai confermabile tramite audit. Migrazione additiva e indicizzata eseguita da entrambi i writer SQLite, senza alcuna scansione SMB.
- Prima di rilascio: suite Swift warnings-as-errors, regressioni FSEvents/mirror/queue reset, test macOS con montaggio SMB autentico, benchmark per scansione/confronto, fault test mount/reconnect/cancellazione, verifica installazione/firma Sparkle su versione **nuova**; nessuna modifica ai dati aziendali di test.
