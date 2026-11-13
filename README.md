# MacSync — prototipo v0.7.0

Applicazione nativa macOS per la futura sincronizzazione **unidirezionale Sorgente → Destinazione**, con copie selettive ogni 5 minuti, SQLite e FSEvents.

> **STATO: PROTOTIPO DA TESTARE, NON VERSIONE DI PRODUZIONE.** Le copie sono disabilitate per impostazione predefinita e si attivano solo su conferma per la sessione corrente. Le cancellazioni speculari non vengono eseguite. Per ora selezionare **solo cartelle di prova**, senza dati di produzione.

## Configurazione approvata

Per ognuna delle due coppie iniziali (Cartella_1 e Cartella_2):
- **Sorgente**: selezionare con Sfoglia oppure trascinare una cartella **locale del Mac** dal Finder nell'area (il monitor FSEvents non tratta cartelle SMB come sorgenti).
- **Destinazione**: selezionare con Sfoglia oppure trascinare una cartella dal Finder nell'area.
- La destinazione può essere una normale cartella locale del Mac (per test sullo stesso computer) oppure una condivisione SMB **già montata e accessibile nel Finder**.
- MacSync non richiede server/IP, dominio, username, password SMB, Keychain dedicato, rclone, script di shell o installazione sul Windows Server 2016. Autenticazione e montaggio della condivisione sono gestiti da macOS.
- Non è consentito configurare una destinazione dentro una sorgente, due sorgenti sovrapposte o due destinazioni sovrapposte. Il monitoraggio è locale e la replica è sempre a senso unico.

## Funzionalità sviluppate

- Monitoraggio delle cartelle con **FSEvents** e inventario **SQLite** in ~/Library/Application Support/MacSync/inventory.sqlite.
- Scansione completa delle sorgenti locali all'avvio, poi rilevamento file e sottoalberi modificati. Riconciliazione locale programmata o in caso di eventi persi.
- Coda persistente per i file aggiunti e modificati. Le cancellazioni sono memorizzate come eventi ma **NON sono mai applicate alla destinazione** in v0.7.
- Motore **Foundation/FileManager** che copia un file alla volta verso la cartella destinazione selezionata, con staging nella directory .macsync-staging. Nella v0.6 verifica lo spazio libero per il file, un eventuale backup e 16 MiB di margine; controlla inoltre la dimensione del file temporaneo e la stabilità della sorgente prima della pubblicazione. Se lo spazio non è dichiarato dal filesystem, il controllo preventivo non può garantire la capacità.
- Per un file già presente alla destinazione, backup preventivo seguito da sostituzione, senza cancellazione speculare. Nella v0.6 è possibile ispezionare, e soltanto dopo esplicita conferma ripulire, file UUID .partial più vecchi di sette giorni nella cartella .macsync-staging. I backup non vengono puliti. Su share SMB, atomicità/compatibilità devono ancora essere verificate con prove reali.
- Verifica dell'identità del volume di destinazione (filesystem e mount point), così la scomparsa di una share SMB montata non viene trattata come un normale percorso locale di ripiego.
- **Registro SQLite** consultabile dall'app: avvii, rilevamento modifiche, ciclo di sincronizzazione, file trasferiti, byte, tempi e anomalie. La v0.6 aggiunge ricerca per nome/errore, filtri per esito, esportazione TSV filtrata e retention di massimo 20.000 eventi o 90 giorni. I log registrano percorsi relativi, non password o indirizzi IP. Prima di condividere un log controllare comunque i nomi dei file, che possono essere sensibili.
- **Anteprima iniziale in sola lettura**: confronto su richiesta fra cartelle sorgenti e destinazioni, incluse cartelle SMB già montate. Segnala differenze, file presenti solo a destinazione e possibili conflitti di maiuscole/minuscole. I match di timestamp e dimensione sono **presunti**, non una verifica byte per byte.

## Come effettuare prove interamente su Mac

1. Creare due cartelle locali di test separate: una per la **Sorgente** e una vuota per la **Destinazione**. Mettere nella sorgente alcuni file sintetici, NON fotografie originali.
2. Aprire la finestra dedicata **MacSync — Configurazione** (accessibile anche dall'icona nella barra dei menu). Per una coppia, trascinare la cartella sorgente nell'area **Sorgente** e la cartella destinazione nell'area **Destinazione**, oppure selezionarle tramite i due pulsanti **Sfoglia…**.
3. MacSync costruisce un inventario SQLite. Premere **Anteprima iniziale (sola lettura)** per un controllo non distruttivo facoltativo.
4. Premere **Attiva copie di prova** e confermare l'avviso: solo allora avvia copie della coda, con controllo circa ogni 5 minuti. Il processo può sovrascrivere file già esistenti nella destinazione scelta.
5. Consultare **Registro sincronizzazioni**. Verificare il numero di file, la durata e gli eventuali errori; premere **Esporta registro…** per ottenere un TSV.
6. Premere **Ferma copie** prima di cambiare cartelle. Un singolo trasferimento già in corso potrebbe finire.

### Per una cartella SMB del server

Montare e aprire la condivisione da Finder con le credenziali **già salvate in macOS**, quindi selezionare o trascinare la sottocartella desiderata nell'area Destinazione. MacSync **non** effettua ora il montaggio automatico dopo lo spegnimento, il login o le interruzioni VPN: verifica la disponibilità e si sospende in caso di problemi. Questa parte andrà sviluppata e collaudata prima di poterlo "configurare e dimenticare".

## Novità v0.6 — spazio, temporanei e diagnostica

- **Spazio libero:** il preflight controlla il volume prima di creare staging o backup; in caso di insufficienza l'operazione resta in coda. Non libera automaticamente spazio cancellando file.
- **Staging:** controllo della dimensione del file temporaneo prima della pubblicazione, oltre al confronto di dimensione, data e inode della sorgente. Non è ancora una verifica hash byte per byte.
- **Manutenzione manuale:** Verifica file temporanei e Pulisci temporanei… riguardano solo file UUID .partial in .macsync-staging vecchi almeno sette giorni, con approvazione esplicita, verifica volume e ricontrollo delle identità. Foto e backup non vengono cancellati.
- **Registro:** filtri per livello, ricerca, export TSV filtrato; retention di massimo 20.000 eventi o 90 giorni. Non condividere log senza verificare i nomi dei file.
- **Test:** GitHub Actions verifica il blocco per spazio insufficiente, preservazione dei file nuovi/vecchi durante la pulizia, cambiamenti dopo l'anteprima e le ricerche nel log.

Il trasferimento riparte dall'inizio dopo un'interruzione; i temporanei recenti non vengono eliminati automaticamente e i backup possono occupare spazio significativo. Non usare con file di produzione finché non sono stati effettuati test reali su Mac Sequoia e Windows Server SMB/VPN.
## Novità v0.7 — prima sincronizzazione intelligente senza ritrasferire i file identici

La v0.7 permette di **riconoscere i file già presenti nella Destinazione**, per esempio dopo una prima copia di 100 GB tramite disco esterno, senza sovrascriverli o copiarli nuovamente se il loro contenuto coincide.

1. Configurare la **Sorgente** locale e la **Destinazione** (cartella locale oppure condivisione SMB già montata nel Finder), utilizzando **Sfoglia** o trascinamento.
2. Avviare il monitoraggio e attendere che SQLite registri i file locali. Prima di verificare, fermare le copie sperimentali.
3. Premere **Verifica file già presenti**. MacSync prende i job UPSERT in coda, controlla il volume e i percorsi, scarta file assenti o di dimensione diversa e confronta il contenuto dei candidati con **SHA-256 calcolato a blocchi da 1 MiB**. Non modifica alcun file né i job durante la verifica.
4. Consultare numero di file esaminati, file con hash identico, file diversi/non verificabili e byte letti; è possibile annullare la verifica senza cambiare la coda SQLite.
5. Solo dopo la verifica, premere **Conferma N file identici** e approvare l'avviso. MacSync ricontrolla i metadati dei file verificati, l'identità del volume e lo stato della coda, quindi contrassegna in una transazione SQLite unicamente i job ancora validi. **Nessuna scrittura nella cartella di destinazione.**
6. Le copie successive elaboreranno soltanto i file che restano in coda: quelli mancanti, differenti o non verificabili. Le cancellazioni speculari restano disabilitate.

**Traffico VPN:** il confronto SHA-256 deve **leggere per intero il contenuto della Destinazione e della Sorgente** per ciascun file candidato. Per 100 GB di file già identici potrebbe significare circa **100 GB letti dal server via VPN più 100 GB letti localmente**, se tutti vengono verificati. Questa modalità evita di riscrivere il server e permette di distinguere file con uguali date/dimensioni ma contenuto differente, **non elimina il traffico di lettura sulla VPN**. Per il primo archivio può essere utile un'alternativa basata su manifest di hash calcolati localmente durante la copia iniziale; questa funzione non è ancora implementata.

**Prestazioni e sicurezza:** la scansione SHA-256 avviene soltanto su richiesta, NON ogni cinque minuti, e usa RAM limitata perché legge blocchi piccoli. I file non disponibili, symlink, modificati durante il controllo o con volume smontato non vengono marcati come sincronizzati. Le corrispondenze per sola dimensione/data nell'altra Anteprima iniziale restano soltanto presunte. Non sono previsti write/delete o rimozioni automatiche sul server.

**Stato sperimentale:** la funzione è verificata con test automatici su due cartelle locali in runner macOS 15. Il collaudo su share SMB montata, VPN e Windows Server 2016, l'esecuzione per 100 GB reali, la resistenza a interruzioni e le prestazioni devono essere verificati sull'iMac prima dell'uso in produzione.

## Test, limiti e sicurezza

GitHub Actions macOS 15 esegue swift test, swift build -c release e prepara un pacchetto sperimentale .app, firmato ad hoc e non notarizzato. I test usano cartelle locali sintetiche; **non verificano la VPN di test, una condivisione SMB effettiva né le prestazioni con 100 GB**.

Prima della versione di produzione servono:
- login item e verifica della riconnessione/riapertura condivisione SMB tramite macOS;
- robustezza in trasferimenti di file grandi PSD via VPN: dopo un'interruzione il singolo file viene ritentato dall'inizio; test reali di atomicità delle sostituzioni SMB, controllo degli hash e rotazione dei backup;
- bootstrap sicuro per file già copiati sul server (senza riconfronti integrali a ogni ciclo);
- gestione delle cancellazioni e rinomine remote con protezioni anti-cancellazione di massa;
- collaudo sul vero iMac/macOS Sequoia e Windows Server 2016.

**MacSync sarà una replica, non un backup storico:** mantenere backup versionati indipendenti. Non caricare foto, password, dati VPN, log sensibili o database reali nel repository.

Per proseguire con Codex leggere AGENTS.md e docs/ARCHITECTURE.md.
