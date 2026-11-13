# AGENTS.md — MacSync

## Obiettivo
App nativa macOS Sequoia per sincronizzazione unidirezionale delle cartelle dell'iMac verso due cartelle di destinazione, locali (test sullo stesso Mac) o su condivisioni SMB già montate dal Finder. repository pubblico Videomakercd/MacSync-Public. Disponibile in uso commerciale senza componenti a pagamento, nessun servizio da installare sul server Windows 2016.

## REQUISITI CONFERMATI (novembre 2026)
- UI con configurazione per entrambe le coppie: Sorgente → Destinazione. Le due cartelle si scelgono con NSOpenPanel o drag & drop dal Finder. I nomi di riferimento sono Cartella_1 e Cartella_2 ma sono configurabili gli effettivi percorsi.
- Destinazioni locali e SMB già montate; sfruttare le credenziali memorizzate nel sistema operativo. Niente form IP/utente/password/dominio, niente rclone o Keychain proprietario per il trasferimento.
- SQLite locale per inventario, coda persistente, attività e log esportabili. FSEvents per rilevare modifiche, con scansioni locali mirate e audit periodici.
- Copie ogni circa 5 minuti quando abilitate; non enumerare ricorsivamente la destinazione a ogni ciclo.
- Obiettivo finale: installo/configuro/dimentico, avvio automatico al login, recupero VPN e verifica monte SMB, mirror di cancellazioni e rinomine.
- Gli altri utenti hanno accesso in lettura alla copia server; permessi gestiti da Windows. L'iMac è fonte di verità.

## Regole di sicurezza obbligatorie
1. MAI replicare una cancellazione per fonte assente, volume SMB smontato, errori, timeout o percorso errato.
2. In v0.5 **NESSUNA cancellazione speculare remota**, persino se evento delete è in SQLite. Solo copie di prova, esplicitamente abilitate per la sessione.
3. Validare che nessuna sorgente/destinazione si sovrapponga, anche tra coppie, e che il volume destinazione risponda alla fingerprint di selezione (filesystem + mount point).
4. Trasferimenti per file singolo, via staging nella destinazione stessa. Verificare sorgente stabile prima della pubblicazione. Sovrascritture in fase test devono avere backup non cancellato.
5. Non loggare password, IP/host di server, percorsi assoluti, variabili d'ambiente con credenziali. Registro SQLite contiene percorso relativo del file e metadati: avvisare prima dell'esportazione.
6. Versioni di codice e test sempre sul repository; GitHub Actions macOS 15 deve passare PR/commit. Nessun test GitHub sostituisce il collaudo SMB reale con iMac vero.
7. **Non dichiarare pronto per i 100 GB** finché bootstrap, cleanup staging, password Finder/VPN, macOS login, SMB rename e resilienza non sono collaudati.
8. In assenza di certezze sull'API Foundation o sul comportamento di SMB, interrompere l'azione distruttiva e loggare l'errore senza peggiorare lo stato.

## Architettura v0.5
- Sources/MacSync/MacSyncApp.swift: finestra persistente SwiftUI per la configurazione drag&drop delle due coppie, icona menu bar per aprirla, monitor e log viewer.
- Sources/MacSync/MountedCopyController.swift: worker di test in background, intervallo 5 minuti, registro, anteprima iniziale read-only.
- Sources/MacSyncCore/LocalMonitorService.swift + FSEventsWatcher.swift: watcher nativo e recupero.
- Sources/MacSyncCore/LocalInventory.swift + ChangeJournal.swift: inventario e coda SQLite.
- Sources/MacSyncCore/MountedFolderCopy.swift: FileManager copia locale/macOS SMB già montato, fingerprint volume e staging.
- Sources/MacSyncCore/SyncActivityLog.swift: storico persistente, operazione, byte, secondi ed esportazione TSV.
- Sources/MacSyncCore/BootstrapPreview.swift + MountedBootstrapPreview.swift: confronto una tantum per archivi pre-esistenti senza modifiche.

## Prossime fasi
1. Confermare CI completo versione 0.5, testare drop e sostituzione file Mac localmente.
2. Rendere trasparente e sicura la sostituzione di file grossi, metadati, e cleanup degli staging/backups; test di interruzione e retry.
3. Bootstrap guidato dei 100 GB già presenti (differenze per dimensione/data solo presunte; verifica robusta prima di marcare come sincronizzati).
4. Auto-login e riconnessione mount Finder dopo VPN, sospensione e riavvio; notifiche e politiche log rotation.
5. Cancellazioni/rinomine remote rigorosamente protette da baseline, conferme e interruttori anti-mass-delete.
6. Collaudo reale su macOS Sequoia + Windows Server 2016/VPN (test iniziali locali e su sottocartelle sintetiche).

## Definition of done
Sincronizzazione automatica per molte settimane con ripresa da errori VPN, nessuna perdita di dati, nessun software aggiuntivo sul server, performance misurate e manuale essenziale. V0.5 è solo prototipo, non produzione.
