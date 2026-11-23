# MacSync v0.18.17 — Baseline locale senza coda iniziale massiva

**Stato:** sviluppo isolato, non pubblicato. Baseline v0.18.16 (tag firmato). Rollback sorgente `rollback-before-v0.18.17-inventory-baseline`. La versione installata e il database dell'utente non vengono modificati dal lavoro sul repository.

## Problema osservato

Su un profilo nuovo, con un archivio locale già popolato e una destinazione preesistente, la prima scansione `LocalInventory.reconcile` registrava metadati locali **e** UPSERT per ogni elemento, accumulando oltre 200.000 job. La fase successiva `Salvataggio operazioni nel database` poteva impiegare molto tempo per operare su questa coda, nonostante QUICK avesse individuato meno di un migliaio di differenze relative a file.

## Nuova semantica del primo avvio

- Per ogni root **davvero nuova** (nessun `watched_roots`, nessun `directory_bindings`, nessun `file_inventory`, nessun `change_queue` storico per la root), la scansione locale salva in `file_inventory` percorsi, tipi, dimensioni, mtime e change stamp, ma **non genera nuovi UPSERT di bootstrap**.
- Questo non equivale a considerare l'archivio server già sincronizzato. L'utente deve eseguire una verifica QUICK/INTELLIGENT dopo la prima baseline, prima di abilitare copie automatiche o mirror. L'audit con un'unica scansione SMB e confronto in memoria genera esclusivamente UPSERT missing/different realmente rilevati; non elimina extra server.
- FSEvents prende un event ID *prima* della scansione iniziale e avvia lo stream da quel checkpoint dopo la baseline. Eventi durante la baseline vengono riprocessati come modifiche `source_monitor`. Le successive scansioni locali su radici già inventariate accodano cambiamenti normalmente.
- Le operazioni storiche esistenti, `legacy_unknown`, `archive_audit`, `destination_rebind` e `source_monitor` non sono annullate o declassificate dalla modifica; non viene resettata automaticamente la coda.
- Nessuna scansione ulteriore del server SMB, nessun nuovo hash QUICK. INTELLIGENT preserva gli hash selettivi. Mirror/copie/rename e salvaguardie delle pubblicazioni restano invariati.

## Persistenza e prestazioni

- Si mantiene **un solo file SQLite locale** con tabelle indipendenti `file_inventory` e `change_queue`. Separare fisicamente i DB comprometterebbe la semplicità della transazione condivisa senza eliminare il problema delle operazioni iniziali.
- Primo inventario: una transazione per salvare l'inventario senza due scritture aggiuntive per ogni file nella tabella coda. Con un archivio di 200k elementi, ciò elimina la causa principale del numero eccessivo di job.
- L'audit QUICK mostra l'avanzamento effettivo della fase `Salvataggio operazioni nel database · n/N` con notifiche limitate a circa 0,5 s, e della fase successiva `Riconciliazione coda iniziale · n/N` per i database storici che contengono ancora job iniziali. Non implica ulteriori letture SMB.
- Un profilo storico v0.18.16 con 207k job non viene azzerato automaticamente. Il pulsante **Impostazioni → Ripristino MacSync → Azzera tutti i dati** elimina impostazioni, inventario, coda, log e backup interni al successivo avvio, ma non tocca foto/cartelle né sul Mac né sul server. Usarlo solo dopo aver esportato log e conservato copia esterna delle impostazioni e del DB. Richiede riconfigurazione di cartelle e pianificazione.

## Test e criteri

- Baseline su 800 file + 20 directory: coda 0, inventario 820, riavvio invariato 0, modifica su disco durante pausa rilevata come `source_monitor`.
- Modifica durante inventario: un evento riprodotto dopo il checkpoint ripristina l'UPSERT, anche se la baseline non lo aveva accodato.
- QUICK su 100 file (96 corrispondenti + 1 differente + 3 mancanti) con cartella comune: 4 UPSERT totali, SHA 0, nessun riconoscimento cieco.
- Conservazione delle precedenti regressioni su job pendenti FSEvents, intenti di pubblicazione e migration legacy.
- Necessari CI Swift warnings-as-errors, stress/benchmark sintetici, build universale Intel/Apple Silicon, DMG, firma Sparkle temporanea; collaudo Finder SMB/Windows Server 2016/VPN reale separato e non effettuato da GitHub Actions.

## Esempio di percorso di collaudo dopo release firmata

1. Aggiornare da MacSync mediante Sparkle alla **v0.18.17**.
2. Conservare copia esterna dei dati MacSync che si vogliono poter consultare; poi chiudere i processi in modo coordinato.
3. Utilizzare `Azzera tutti i dati`, riaprire l'app, configurare le cartelle e lasciare copie automatiche e mirror disattivati.
4. Attendere **Inventario locale iniziale**. La coda deve risultare 0 salvo eventuali eventi FSEvents effettivi.
5. Avviare una sola verifica archivio **QUICK** per determinare differenze sorgente/destinazione. L'ordine di grandezza previsto per i dati dell'ultimo controllo dell'utente era inferiore a 1000 UPSERT relativi a file, ma non è una garanzia: possono esserci differenze nuove, cartelle e operazioni locali successive.
6. Controllare report, log e numero di job; abilitare copie/mirror solo dopo verifica dei percorsi e delle differenze e su dati di prova.
