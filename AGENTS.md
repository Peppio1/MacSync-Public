# AGENTS.md — MacSync

## Obiettivo
App nativa macOS Sequoia per sincronizzazione unidirezionale delle cartelle dell'iMac verso due cartelle di destinazione, locali (test sullo stesso Mac) o su condivisioni SMB già montate dal Finder. repository pubblico Videomakercd/MacSync-Public. Disponibile in uso commerciale senza componenti a pagamento, nessun servizio da installare sul server Windows 2016.

## REQUISITI CONFERMATI (novembre 2026)
- UI con configurazione per entrambe le coppie: Sorgente → Destinazione. Le due cartelle si scelgono con NSOpenPanel o drag & drop dal Finder. I nomi di riferimento sono Cartella_1 e Cartella_2 ma sono configurabili gli effettivi percorsi.
- Sorgenti locali del Mac (monitor FSEvents); destinazioni locali o SMB già montate; sfruttare le credenziali memorizzate nel sistema operativo. Niente form IP/utente/password/dominio, niente rclone o Keychain proprietario per il trasferimento.
- SQLite locale per inventario, coda persistente, attività e log esportabili. FSEvents per rilevare modifiche, con scansioni locali mirate e audit periodici.
- Copie ogni circa 5 minuti quando abilitate; non enumerare ricorsivamente la destinazione a ogni ciclo.
- Obiettivo finale: installo/configuro/dimentico, avvio automatico al login, recupero VPN e verifica monte SMB, mirror di cancellazioni e rinomine.
- Gli altri utenti hanno accesso in lettura alla copia server; permessi gestiti da Windows. L'iMac è fonte di verità.

## Regole di sicurezza obbligatorie
1. MAI replicare una cancellazione per fonte assente, volume SMB smontato, errori, timeout o percorso errato.
2. In v0.8 le cancellazioni speculari sono **OFF per impostazione predefinita**. Possono essere provate soltanto dopo un consenso esplicito a ogni sessione, con baseline valida, blocco mass-delete e nessun evento precedente all'abilitazione. Non usare su file di produzione senza collaudo SMB.
3. Validare che nessuna sorgente/destinazione si sovrapponga, anche tra coppie, e che il volume destinazione risponda alla fingerprint di selezione (filesystem + mount point).
4. Trasferimenti per file singolo, via staging nella destinazione stessa. Verificare sorgente stabile prima della pubblicazione. Sovrascritture in fase test devono avere backup non cancellato.
5. Non loggare password, IP/host di server, percorsi assoluti, variabili d'ambiente con credenziali. Registro SQLite contiene percorso relativo del file e metadati: avvisare prima dell'esportazione.
6. Versioni di codice e test sempre sul repository; GitHub Actions macOS 15 deve passare PR/commit. Nessun test GitHub sostituisce il collaudo SMB reale con iMac vero.
7. **Non dichiarare pronto per i 100 GB** finché bootstrap, cleanup staging, password Finder/VPN, macOS login, SMB rename e resilienza non sono collaudati.
8. In assenza di certezze sull'API Foundation o sul comportamento di SMB, interrompere l'azione distruttiva e loggare l'errore senza peggiorare lo stato.

## Architettura corrente (base v0.5, estesa fino a v0.8)
- Sources/MacSync/MacSyncApp.swift: finestra persistente SwiftUI per la configurazione drag&drop delle due coppie, icona menu bar per aprirla, monitor e log viewer.
- Sources/MacSync/MountedCopyController.swift: worker di test in background, intervallo 5 minuti, registro, anteprima iniziale read-only.
- Sources/MacSyncCore/LocalMonitorService.swift + FSEventsWatcher.swift: watcher nativo e recupero.
- Sources/MacSyncCore/LocalInventory.swift + ChangeJournal.swift: inventario e coda SQLite.
- Sources/MacSyncCore/MountedFolderCopy.swift: FileManager copia locale/macOS SMB già montato, fingerprint volume e staging.
- Sources/MacSyncCore/SyncActivityLog.swift: storico persistente, operazione, byte, secondi ed esportazione TSV.
- Sources/MacSyncCore/BootstrapPreview.swift + MountedBootstrapPreview.swift: confronto una tantum per archivi pre-esistenti senza modifiche.

## Stato v0.6.0 — hardening motore di copia
- Aggiunto preflight di capacità tramite statfs: stima la dimensione del nuovo staging, del backup dell'eventuale vecchio file e 16 MiB di riserva. Se la capacità dichiarata è insufficiente, lascia l'upsert in coda e segnala errore recuperabile. Alcune share SMB possono non riportare la capacità.
- Aggiunto controllo del file di staging (tipo regolare e dimensione) prima della sostituzione; test automatici su cartelle Mac locali. Mancano verifica crittografica hash e garanzia di pubblicazione atomica su SMB Windows Server.
- Aggiunta StagingMaintenance: ispezione non ricorsiva dei soli file UUID.partial oltre sette giorni in .macsync-staging, pulizia ESCLUSIVAMENTE dopo conferma e ripetizione dei controlli di volume/inode/data/dimensione. Mai eseguita dal timer, mai rimuovere foto o .macsync-backup.
- Registro SQLite: filtri per livello e testo, export TSV filtrato, retention di 20.000 righe o 90 giorni; non registrare segreti/percorsi assoluti, controllare nomi file sensibili.
- Lo scaricamento/copia di un file grande interrotto riparte dall'inizio. Continuare a vietare cancellazioni speculari e funzionamento unattended in questa fase; usare soltanto cartelle di prova.

## Stato v0.7.0 — seed SHA-256 verificato
- Implementato SeededArchiveVerifier: legge in streaming da 1 MiB il contenuto dei file UPSERT pendenti, con SHA-256 CryptoKit, considerando soltanto sorgenti/destinazioni regolari. Convalida tutti i parent via lstat, blocca symlink e verifica fingerprint del volume SMB.
- Non fidarsi mai di dimensione/data come prova di identità: i candidati con stessa dimensione vengono confrontati byte-per-byte via digest SHA-256. Progress basato anche su byte letti; supporto ad annullamento.
- La scansione non cambia file né coda: il pulsante Conferma N file identici approva esplicitamente. Prima della transazione vengono confrontati nuovamente inode, dev, size, mtime e ctime delle due copie; UPDATE SQLite condizionale verifica job ID, root, path, inventario e assenza di job concorrenti. Nessuna cancellazione e nessuna scrittura nella destinazione.
- I file mancanti, diversi, cambiati, symlink e cartelle non sono riconosciuti; gli UPSERT restano in coda. Il DELETE non viene mai toccato.
- La verifica può leggere 100 GB dalla share via VPN e 100 GB localmente: non ritrasferisce i file ma non elimina il costo della lettura SMB. Non eseguirla ogni 5 minuti, solo su richiesta.
- GitHub Actions testa anche il falso positivo di size+mtime uguale ma hash diverso, il contenuto alterato dopo il preview, i job rimpiazzati da FSEvents e annullamento/atomicità.
- Ancora necessari: prova reale SMB e validazione carico 100 GB; alternativa opzionale per primo seed con manifest hash calcolati mentre si copia via disco USB (non realizzata).

## Stato v0.8.0 — cancellazione speculare opzionale
- UI: interruttore cancellazioni speculari default OFF, opzione recupero default ON, giorni 1–30 oppure Mai (0), accesso Finder a `.macsync-recovery`.
- Preferenze memorizzate non bastano ad autorizzare le eliminazioni: sessione sperimentale confermata esplicitamente ad ogni avvio; inizializzazione e scansione locale su queue di lavoro. La sessione considera solo DELETE generati DOPO la baseline armata (nessuna cancellazione retroattiva).
- `MirrorDeletionWorker` controlla sorgente locale, volume destinazione SMB, inode/dev di entrambe le root, inventario e coda SQLite, soglie anti-mass-delete (>=250 o >=25 e >=10% baseline), ricomparsa file, symlink e directory non vuote. `unlink` e `rmdir` POSIX evitano rimozioni ricorsive.
- Senza recupero: eliminazione definitiva del file in destinazione. Con recupero: spostamento nello stesso volume sotto `.macsync-recovery/<UUID>/<percorso originale>` e registrazione manifest SQLite.
- Retention: 1–30 giorni => scadenza su record recupero, rimozione automatica solo durante sessione attiva e se identità/inode, dimensione, mtime, root e volume coincidono. Mai => scadenza NULL, niente purge; se sessione non attiva niente cleanup.
- `MirrorDeletionCancellation` blocca operazioni successive allo stop; una singola unlink/move già avviata potrebbe completarsi.
- Il recovery è dentro la cartella destinazione ed è nascosto. Non fare purge indiscriminati o scansioni ricorsive SMB ogni 5 minuti. Dati dei clienti NON devono essere usati nei test; test di produzione solo dopo collaudo su iMac e Windows Server 2016.
- Le rinomine oggi vengono rappresentate da copy nuovo percorso + delete vecchio, non ancora da rename SMB server-side. Le cancellazioni intenzionali oltre soglia restano bloccate finché non implementato un override manuale protetto. La soglia considera anche le cancellazioni già effettuate nei cicli precedenti della stessa sessione.

## Stabilizzazione v0.8.1 (scanner, dashboard, test sicurezza)
- Corretto LocalScanner: skipDescendants non deve essere invocato su file ordinari; soltanto i symlink sono esclusi dalla ricorsione. Il vecchio comportamento ometteva talvolta file in directory successive a file nel livello principale. La correzione è coperta da regression test.
- Rafforzati i test MirrorDeletion: directory con figli cancellati, cartella server con elementi sconosciuti, stop con DELETE pendente, ripartenza senza riprodurre cancellazioni antecedenti all'arming.
- Aggiunto SyncDashboardStats, alimentato dai risultati effettivi del motore: nuovi file, file aggiornati, eliminazioni definitive, file recuperabili, errori e rimandati, directory e byte trasferiti. Mostrare ultimo ciclo e totale sessione in finestra dedicata, con sintesi nel pannello principale.
- I contatori in memoria si azzerano all'attivazione di una nuova sessione; il registro SQLite mantiene lo storico persistente delle attività. Non contare scansioni hash o job rimandati come copie completate.
- La pipeline GitHub Actions macOS 15 è stata verificata sui nuovi test. Rimangono obbligatori collaudi di Finder UI, SMB/VPN e autorizzazioni macOS; non attivare cancellazioni sui dati reali.

## Prossime fasi
1. Confermare CI completo versione 0.8.1, testare in Finder drag & drop e sostituzione su Mac locale.
2. Rendere trasparente e sicura la sostituzione di file grossi, metadati, e cleanup degli staging/backups; test di interruzione e retry.
3. Bootstrap guidato dei 100 GB già presenti (differenze per dimensione/data solo presunte; verifica robusta prima di marcare come sincronizzati).
4. Auto-login e riconnessione mount Finder dopo VPN, sospensione e riavvio; notifiche e politiche log rotation.
5. Cancellazioni/rinomine remote rigorosamente protette da baseline, conferme e interruttori anti-mass-delete.
6. Collaudo reale su macOS Sequoia + Windows Server 2016/VPN (test iniziali locali e su sottocartelle sintetiche).

## Definition of done
Sincronizzazione automatica per molte settimane con ripresa da errori VPN, nessuna perdita di dati, nessun software aggiuntivo sul server, performance misurate e manuale essenziale. V0.8.1 è solo prototipo, non produzione.
