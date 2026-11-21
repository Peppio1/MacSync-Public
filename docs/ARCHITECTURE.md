# MacSync — Architettura v0.15.0

> Riferimento convalidato: commit 2cc398b, CI macOS 15 completata. v0.15.0 mantiene il motore invariato; regressione e pacchetto universale da verificare. Le note relative alle versioni precedenti sono conservate in [ARCHITECTURE_HISTORY.md](ARCHITECTURE_HISTORY.md) e [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md). Non modificare le protezioni operative per rendere più facili i test.

## Componenti

| Componente | Responsabilità |
|---|---|
| MacSyncApp / MacSyncRuntime | UI SwiftUI, ciclo di vita, pianificazione, notifiche e coordinamento |
| MountedCopyController | Coda seriale di trasferimento e manutenzione, stati, progressi |
| LocalMonitorService / FSEventsWatcher | Monitoraggio locale, riconciliazione e recupero eventi |
| LocalInventory / ChangeJournal | Inventario SQLite, cursori, coda durevole UPSERT/DELETE e binding |
| MountedFolderCopy / TransferPreflight | Trasferimento per file, staging, capacità, pubblicazione e retry |
| OperationalSafety / RuntimeStorageGuard | Identità, sicurezza percorsi, blocco istanze, integrità e backup del DB |
| MirrorDeletion / DeletionSafety | Consenso, rimozioni speculari, recovery e soglie opzionali |
| ArchiveAudit / SeededArchiveVerifier | Confronto rapido o SHA-256, riconoscimento e riparazioni accodate |
| SyncActivityLog / SyncCycleHistory | Log tecnici, eventi e risultati persistenti |
| SyncSchedule / ConnectionOutageTracker | Slot temporali e gestione episodi di indisponibilità |

## Flusso operativo

1. Configurazione di radici locali e destinazioni locali/SMB già montate. Validazione delle sovrapposizioni, dei percorsi e delle identità.
2. FSEvents rileva modifiche locali; inventario iniziale e riconciliazioni mirate producono eventi SQLite. Pubblicazione del cursore e degli aggiornamenti in transazione locale.
3. Allo slot previsto, il worker verifica lo stato del monitor, tutte le destinazioni e le autorizzazioni correnti. In caso di indisponibilità o identità incompatibile sospende le scritture.
4. La coda usa paginazione keyset e un limite di ID per ciclo: nuovi eventi rimangono disponibili per il ciclo seguente. Nessuna scansione ricorsiva SMB in ogni sincronizzazione incrementale.
5. Copie/aggiornamenti precedono le eliminazioni; audit e manutenzione sono coordinati attraverso la coda seriale. Lo stop conserva i lavori pendenti.
6. Lo storico registra esiti effettivi, non stime delle operazioni completate.

## Trasferimenti e sicurezza filesystem

- FileManager.copyItem verso staging nella destinazione, con verifica della capacità dichiarata (quando disponibile), stabilità del sorgente, metadati di staging e target, identità root/volume.
- Pubblicazione mediante operazioni native ancorate ai descrittori di directory e controlli di collisione. La compatibilità delle operazioni atomiche con il server SMB specifico deve essere verificata.
- Sostituzioni: backup prudente della copia precedente, nuova verifica prima della pubblicazione, conferma condizionale in SQLite; pulizia tecnica solo dopo conferma e verifiche. Esiti incerti conservano i backup.
- Intento di pubblicazione persistente: dopo un'interruzione tra pubblicazione e conferma, il motore può verificare SHA-256 del file esistente e riconciliare il job senza ricopia.
- I nomi incompatibili Windows, alias ambigui, percorsi riservati e symlink pericolosi sono bloccati. Il ctime aiuta a rilevare cambiamenti con mtime/dimensione invariati.
- La copia ordinaria non impone hash integrale per ogni trasferimento. Non esiste una transazione distribuita tra SQLite e SMB, né una garanzia assoluta contro scritture concorrenti esterne.

## Cancellazioni e recupero

Il mirror è OFF per default; l'autorizzazione persistente è legata a identità del database, sorgenti, destinazioni e cutoff della coda. DELETE anteriori al consenso non sono autorizzati. I controlli tecnici non sono disattivabili; tre protezioni quantitative opzionali (assoluta, percentuale e sorgente vuota) sono OFF per default e possono attivare un blocco persistente.

Gli upload pendenti bloccano le rimozioni. Rinomine e spostamenti sono copie più eliminazioni, non rename remoto. File regolari e directory vuote sono trattati con operazioni non ricorsive; elementi extra rilevati da audit non vengono cancellati automaticamente. In modalità recupero, il file è spostato sulla stessa destinazione sotto .macsync-recovery, con manifest SQLite; retention 1–30 giorni o illimitata, con convalida prima della scadenza.

## Archivio locale e ciclo di vita

L'archivio operativo è ~/Library/Application Support/MacSync/inventory.sqlite, con SQLite WAL. Il lock esclusivo impedisce una seconda istanza operativa. Il controllo integrità blocca l'avvio se il database è non valido o risulta mancante dopo un precedente avvio.

La migrazione v0.14 e la sostituzione rilevata del database richiedono snapshot verificato, salvataggio delle preferenze e revoca dell'automazione/mirror/audit programmato: le autorizzazioni devono essere rinnovate dopo verifica. A ogni avvio si crea, se assente, uno snapshot giornaliero; non è un backup periodico durante l'esecuzione continua.

La v0.14.3 usa VACUUM INTO con percorso parametrizzato, lasciando a SQLite la creazione del file nella directory privata. Lo snapshot è chiuso, verificato in sola lettura, controllato per assenza di sidecar e header autonomo, limitato a permessi 0600, sincronizzato su disco e pubblicato con rename esclusivo. Non si modifica il journal mode del sorgente e non si sovrascrive uno snapshot precedente.

La chiusura controllata annulla nuovi lavori e attende il drenaggio di worker e monitor; una chiamata filesystem bloccata può ritardare l'uscita. Lo storico può indicare cicli interrotti senza inventare esiti mancanti. Il recupero del database è manuale: non sovrascrivere l'archivio attivo o le foto per effettuare un rollback del codice.

## Pianificazione, verifica e telemetria

- Sincronizzazione: minuti 1–59, ore 1–23, quotidiana/settimanale. Slot ancorati al calendario/cadenza, nessuna esecuzione simultanea o recupero in massa degli slot persi.
- Notifiche: soglia 1–168 ore, opzionale; misurazione dal primo controllo offline e invio al successivo controllo utile. Nessun polling autonomo della connessione.
- Audit, candidata v0.18.15: manuale o giornaliero/settimanale/mensile (giorni 1–28). L'interfaccia espone solo QUICK (dimensione/mtime con tolleranza di 2 secondi, senza SHA-256) e INTELLIGENT (hash selettivo quando serve secondo i metadati); DEEP resta un motore diagnostico interno per report storici e test di sicurezza. Le vecchie preferenze DEEP vengono convertite e ri-salvate in INTELLIGENT mantenendo gli altri campi. Riallineamento solo tramite UPSERT verificati e facoltativi, mai DELETE; riconoscimento dei file preesistenti con conferma separata.
- Statistiche: nuovi/aggiornati dopo conferma, cancellati reali e recuperati come sottoinsieme, esclusione del housekeeping. Velocità media pesata dei byte di staging; non è throughput fisico VPN. Log tecnico con esportazione TSV; storico delle sincronizzazioni separato.

## Evidenze e criteri di rilascio

| Workflow | Evidenza |
|---|---|
| [43981589204](https://github.com/Peppio1/MacSync-Public/actions/runs/43981589204) | Correzione backup SQLite: 161 test ordinari superati |
| [43982920242](https://github.com/Peppio1/MacSync-Public/actions/runs/43982920242) | Test integrato e 162 test ordinari superati |
| [43983414603](https://github.com/Peppio1/MacSync-Public/actions/runs/43983414603) | 164 test ordinari superati; rendering separato; release e 48 PNG |
| [43985988474](https://github.com/Peppio1/MacSync-Public/actions/runs/43985988474) | 167 test ordinari superati; 96 cicli accelerati, inventario 10.000 file e recupero simulato |

Test locali includono resistenza a interruzioni, coda da 20.000 operazioni, copia sintetica da 64 MiB, oltre 1.000 cancellazioni autorizzate, carico giornaliero sintetico (40 cartelle, 360 file), quattro cicli di modifica e audit finale. Non equivalgono a un benchmark completo di archivio o rete.

Ancora richiesti: durata reale e risorse dell'app installata, arresto/riavvio effettivo del processo, interazioni UI e accessibilità, SMAppService/notifiche, compatibilità SMB/ACL Windows, riconnessioni VPN, sospensione, comportamento su disco pieno e carico effettivo. Usare solo dati sintetici e share di prova finché questi controlli non sono completati.

## Rollback e privacy

Baseline convalidata conservata nel ramo [rollback-before-endurance-validation](https://github.com/Peppio1/MacSync-Public/tree/rollback-before-endurance-validation). Il rollback Git protegge il codice, non i dati: interrompere tutte le istanze, conservare archivio corrente, verificare compatibilità di schema e preferenze e ripristinare eventualmente solo snapshot coerenti con autorizzazioni revocate. Non pubblicare percorsi privati, credenziali, database o dati reali.

## Aggiornamenti v0.16.0 (sviluppo)

Controller indipendente dal runtime di copia, disattivato in preview, arrestato durante shutdown. Il controllo consulta solo la release stabile pubblica GitHub; non scarica né esegue codice. Il componente UpdateRecoverySnapshot è una primitiva, non ancora collegata a un installatore. Vedi [piano e limiti](UPDATES.md).
