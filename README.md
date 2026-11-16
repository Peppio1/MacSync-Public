# MacSync — prototipo v0.12.4

> Edizione pubblica: lo storico Git è stato anonimizzato. Nomi, indirizzi di rete e dimensioni di archivio sono esempi dimostrativi. Le vecchie versioni e le prove storiche non attestano la convalida della versione corrente.

Applicazione nativa macOS per la futura sincronizzazione **unidirezionale Sorgente → Destinazione**, con copie selettive a frequenza configurabile, SQLite e FSEvents.

> **STATO: PROTOTIPO DA TESTARE, NON VERSIONE DI PRODUZIONE.** Copie automatiche e cancellazioni speculari sono disattivate per default. Dalla v0.12.3 le cancellazioni richiedono un consenso persistente esplicito legato alle coppie verificate; i controlli tecnici sono obbligatori. Per ora selezionare **solo cartelle di prova**, senza dati di produzione. Le sezioni storiche precedenti alla v0.12.3 descrivono i comportamenti delle rispettive versioni.

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
- Coda persistente per i file aggiunti e modificati. Le cancellazioni sono memorizzate nella coda SQLite; nella v0.8 vengono elaborate solo se abilitate e confermate in una sessione di prova e se superano tutti i controlli di sicurezza.
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

## MacSync v0.8 — cancellazioni speculari facoltative e recupero

La finestra di configurazione contiene **Cancellazioni speculari** con le seguenti scelte:

- **Abilita cancellazione speculare**: interruttore separato, **disattivato per impostazione predefinita**. Se spento, eliminare un file dall'iMac NON elimina quello presente in Destinazione.
- **Sposta i file eliminati nella cartella di recupero**: disponibile soltanto quando la cancellazione speculare è abilitata; l'impostazione predefinita è attiva perché più prudente.
- **Conservazione**: selezione da **1 a 30 giorni** oppure **Mai — conserva sempre**. La scelta 'Mai' non programma alcuna rimozione automatica. Se si disabilita il recupero, le cancellazioni sono **definitive** e MacSync non può ripristinarle.
- **Apri cartella di recupero nel Finder**: visualizza i file spostati sotto `.macsync-recovery` nella Destinazione. Per ripristinare un file, copialo preferibilmente nella corretta cartella **Sorgente sull'iMac**: MacSync potrà così replicarlo nuovamente. Non è ancora disponibile un ripristino guidato nell'app.

**Sicurezza fondamentale:** salvare le preferenze NON attiva eliminazioni da solo. In questa versione prototipo è necessario premere **Attiva copie di prova** e confermare per ogni sessione. MacSync prepara una baseline locale, controlla la presenza e l'identità delle cartelle Sorgente/Destinazione e, solo dopo, considera gli eventi di eliminazione generati durante quella sessione. Eventi DELETE registrati *prima* dell'attivazione non vengono eseguiti retroattivamente.

Quando un file viene cancellato dalla Sorgente, MacSync ricontrolla che l'assenza sia reale, che il volume non sia cambiato e che il file non sia stato ricreato. In modalità recupero, sposta il file originale della Destinazione in `.macsync-recovery/<UUID>/<percorso originale>`; senza recupero lo elimina definitivamente. Le directory vengono rimosse soltanto quando vuote. Non modifica i collegamenti simbolici o gli elementi speciali. Non esegue scansioni ricorsive dell'intero server ogni 5 minuti; quando ci sono eliminazioni pendenti, verifica l'inventario della Sorgente locale.

**Protezione cancellazioni massive:** il sistema sospende il lotto quando contiene almeno 250 eliminazioni, oppure 25 o più eliminazioni che rappresentano almeno il 10% dell'inventario locale al momento dell'attivazione. Non tenta di aggirare la protezione dividendole in piccoli gruppi: le eliminazioni già eseguite nei cicli della medesima sessione vengono conteggiate. L'intervento manuale per confermare grandi cancellazioni intenzionali non è ancora implementato.

**Scadenza del recupero:** i file recuperati sono registrati in un manifesto SQLite locale con identificazione dell'elemento. Quando la conservazione è di 1–30 giorni, MacSync verifica a ogni ciclo attivo gli elementi scaduti e rimuove solo i file ancora corrispondenti alla registrazione (inode, dimensione e mtime), nella cartella gestita. La selezione 'Mai' non imposta scadenze. Se MacSync è spento o le cancellazioni sono disabilitate, la pulizia degli elementi scaduti non avviene fino a una successiva sessione attiva. Cambiare la durata non modifica retroattivamente la scadenza già registrata sui file.

**Limiti importanti:** `.macsync-recovery` si trova all'interno della Destinazione, così i file rimangono sullo stesso volume SMB e possono essere spostati senza ricopiare i dati, ma occupano spazio e sono separati dal normale archivio speculare. Le cancellazioni definitive NON hanno cestino. File già eliminati in sessioni precedenti non vengono rimossi automaticamente alla prima attivazione. La replica dei file rinominati funziona come aggiunta del nuovo percorso e rimozione del precedente; il trasferimento può richiedere una nuova copia e non è ancora ottimizzato con un rename SMB diretto.

**Non usare sui dati di produzione:** la logica v0.8 è testata automaticamente su cartelle locali fittizie. La sicurezza di `unlink`, `rmdir`, `moveItem` e della gestione di ACL/volumi SMB va collaudata sul vero iMac con Windows Server 2016 e VPN prima dell'uso produttivo.

## Stabilizzazione v0.8.1 — scanner e riepilogo sincronizzazioni

- **Correzione inventario locale:** il monitor non chiama più skipDescendants() dopo file ordinari, poiché su macOS poteva omettere le sottocartelle successive. Un test di regressione controlla directory annidate dopo file nel livello principale.
- **Cancellazioni di directory:** riconosce i file figli e li elabora prima delle cartelle. I file vengono rimossi con unlink, le directory con rmdir soltanto se vuote. Cartelle con elementi non tracciati sono preservate.
- **Ulteriori test di sicurezza:** stop con eliminazioni ancora pendenti, riavvio senza replay di precedenti eliminazioni e conservazione dei file presenti soltanto sul server.
- **Riepilogo sincronizzazione:** cinque contatori in finestra (nuovi, aggiornati, eliminati, recuperabili, errori) e un pannello dettagliato accessibile tramite Apri riepilogo. È possibile passare da ultimo ciclo a sessione corrente, con conteggi aggiuntivi di rimandati, directory, recuperi scaduti e byte trasferiti.
- La distinzione nuovo/aggiornato viene effettuata dal motore di copia. Le operazioni rimandate non contano come completate. I contatori di sessione ripartono a ogni nuova attivazione; lo storico durevole rimane nel registro SQLite e nell'esportazione TSV.

**Stato:** test automatizzati macOS 15 riusciti, ma Finder drag-and-drop, VPN, SMB e cancellazioni su Windows Server 2016 devono ancora essere collaudati con file sintetici sull'iMac. Non utilizzare la cancellazione definitiva sui dati di produzione.

## MacSync v0.9 — avvio automatico al login e monitor delle destinazioni

- **Checkbox avvio al login:** nella finestra MacSync, sezione Impostazioni di avvio, selezionare Avvia automaticamente MacSync al login macOS. La registrazione è eseguita tramite il framework Apple ServiceManagement (SMAppService.mainApp); non vengono creati script di avvio, daemon, LaunchAgent o programmi esterni.
- Lo stato mostrato dalla checkbox proviene da macOS, non da un valore UserDefaults. MacSync lo aggiorna quando la finestra compare e quando l'app torna attiva; rileva quindi modifiche effettuate nelle Impostazioni di Sistema. Se serve approvazione, compare il pulsante per aprire Elementi login.
- L'avvio al login registra **l'applicazione**, non autorizza da solo copie o eliminazioni. Al login riparte il monitoraggio delle Sorgenti già configurate; nella v0.9.1, soltanto un'**ulteriore checkbox** approvata esplicitamente può abilitare copie e aggiornamenti automatici. Le cancellazioni speculari restano sempre sotto conferma manuale.
- La registrazione va effettuata aprendo il pacchetto MacSync.app, preferibilmente collocato in Applicazioni. L'eseguibile avviato direttamente con swift run non può essere registrato come app al login. Il pacchetto CI è firmato ad hoc e non notarizzato; l'autorizzazione effettiva al login richiede un test su Mac reale.
- **Controllo destinazioni (in v0.9):** era previsto ogni 30 secondi. **Dalla v0.10 il controllo avviene solo insieme alle sincronizzazioni**, alla frequenza configurata, prima di ogni trasferimento. Gli stati possibili sono non configurata, non verificata, non accessibile, volume differente e pronta. Non c'è più un pulsante per effettuare controlli separati.
- **VPN di test:** il collegamento VPN è gestito dal router di rete. MacSync non installa, avvia né configura alcun client VPN. Funziona con Wi-Fi o Ethernet quando il Mac può già raggiungere il server e macOS ha montato correttamente la condivisione SMB.
- **Riconnessione:** se macOS rimonta la stessa condivisione al percorso configurato, il monitor la riconosce e i cicli di copia già attivati potranno ritentare le operazioni in coda. Se la condivisione SMB è stata smontata completamente, questa versione non può forzarne il rimontaggio, poiché non memorizza l'URL SMB né le credenziali: potrebbe essere necessario riaprirla dal Finder.
- Durante l'assenza del volume atteso, MacSync non deve interpretare la destinazione come cartella locale sostitutiva né effettuare cancellazioni. Le copie già attivate ritentano ogni cinque minuti ma non vengono avviate automaticamente dopo un login.

**Test:** i test CI macOS verificano la sonda locale con volume pronto, cartella assente/ritornata, fingerprint diverso e symlink. La compilazione dell'interfaccia e del controller ServiceManagement viene verificata da GitHub Actions, ma l'effettiva iscrizione ad Elementi login e l'accesso SMB dopo Wi-Fi/Ethernet devono essere collaudati sull'iMac.

## MacSync v0.9.1 — ripresa automatica delle SOLE copie

Questa fase distingue due opzioni indipendenti nella sezione **Impostazioni di avvio**:

- **Avvia automaticamente MacSync al login macOS:** registra l'app tramite Apple SMAppService. Mostra lo stato reale di Elementi login. Non comporta automaticamente scritture.
- **Avvia automaticamente le copie e gli aggiornamenti:** facoltativa e **OFF di default**, richiede un'apposita conferma una tantum. Se attiva, dopo il login MacSync può eseguire **SOLO copie e sovrascritture**, anche a finestra chiusa. La modalità non può mai eseguire eliminazioni speculari o pulizia del recupero. Richiede ancora test veri prima di qualsiasi dato di produzione.

**Flusso operativo storico v0.9.1:** all'avvio veniva indicizzato l'inventario delle Sorgenti locali; in quella versione ogni 30 secondi un coordinatore verificava la presenza della destinazione. **Dalla v0.10 il controllo è legato esclusivamente al ciclo di sincronizzazione configurato.** Se una destinazione SMB manca, MacSync aspetta, senza scrivere e senza creare cartelle di ripiego. Se macOS rimonta lo stesso volume, il coordinatore può avviare una sessione di copie senza nuova finestra di conferma, perché l'utente ha già autorizzato esplicitamente questa funzione. Il worker controlla la coda SQLite agli slot della frequenza selezionata e ritenta i file non ancora copiati.

**Identità forte del volume:** oltre a filesystem e mount point, la v0.9.1 salva anche la provenienza del montaggio rilevata da macOS (`statfs.f_mntfromname`, p.es. share SMB). Profili di destinazione delle versioni precedenti non hanno questo dato: per le copie automatiche sarà necessario **riselezionare la Destinazione dal Finder una volta**, così l'automazione non si avvia su una share non verificata. I dati del server non vengono inseriti nei log.

**Ferma copie:** interrompe la modalità automatica per il resto dell'avvio corrente, anche se la checkbox è rimasta selezionata; per riattivarla subito è possibile deselezionare e riselezionare l'opzione dopo nuova conferma. Cambiare Sorgente o Destinazione disabilita le copie automatiche, evitando trasferimenti involontari su percorsi diversi.

**Cancellazioni speculari:** anche se la preferenza mirror è abilitata, la sessione automatica forza una policy senza cancellazioni. Una sessione di cancellazioni continua a richiedere il comando manuale e la conferma specifica previsti nella v0.8. Se non vuoi che MacSync modifichi file senza supervisione, lascia disabilitata la seconda checkbox.

**VPN e SMB:** il router di rete gestisce la VPN. MacSync non imposta VPN né credenziali SMB. Questa versione riconosce il ritorno del volume se **macOS lo ha già rimontato**; non invia nuove richieste di mount. L'eventuale rimontaggio automatico della share all'accesso macOS andrà configurato con il Finder/Elementi login o sviluppato solo dopo collaudo sul Mac reale.

**Collaudo automatico:** gli unit test simulano destinazioni offline/online, volumi errati, profili legacy non verificati, consenso alla copia mancante e mantenimento degli eventi DELETE; uno scenario end-to-end usa due cartelle locali temporanee, elimina e ricrea la destinazione, verifica il recupero della coda delle copie e dimostra che i file destinati alla cancellazione restano intatti. Non provano la connessione SMB, le credenziali memorizzate, il funzionamento effettivo SMAppService né 100 GB reali.

## MacSync v0.10.0 — Frequenza sincronizzazione e avvisi su disconnessione

### Programmazione selezionabile

- **Minuti:** qualsiasi intervallo da **1 a 45 minuti**.
- **Ore:** qualsiasi intervallo da **1 a 12 ore**.
- **Ogni giorno:** orario locale selezionabile (HH:mm).
- **Ogni settimana:** giorno (lunedì–domenica) e orario locale selezionabili.
- La configurazione viene memorizzata nelle preferenze; valore iniziale 5 minuti. I controlli del volume SMB sono effettuati **solo prima del ciclo programmato**, non più ogni 30 secondi né dal solo aprire la finestra. I cicli si svolgono mentre MacSync resta in esecuzione.
- Se una sincronizzazione dura a lungo o il Mac va in stop, non vengono recuperati in massa tutti gli slot saltati: il prossimo ciclo viene ripianificato in modo sicuro. Dalla v0.10.1 gli intervalli minuti/ore restano ancorati all'orario pianificato: la durata della copia non sposta gli slot successivi. Per giorno/settimana resta valido il prossimo orario locale, considerando il cambio ora legale.

### Avviso opzionale dopo prolungata indisponibilità

- Checkbox **Invia una notifica dopo una disconnessione prolungata**, OFF per impostazione predefinita.
- **Avvisa dopo:** durata configurabile da **1 a 168 ore**. Le ore decorrono dalla **prima verifica programmata** che ha riscontrato la destinazione non disponibile, non dall'istante reale (non noto) in cui la rete è caduta.
- Ad ogni successivo ciclo la destinazione viene verificata. Quando la soglia è superata, MacSync invia **una sola notifica per episodio e per cartella**, senza suoni e solo se le notifiche native sono state autorizzate. Alla prima verifica che trova la cartella nuovamente disponibile il conteggio viene azzerato.
- Il controllo non viene eseguito tra due cicli: ad esempio, se la sincronizzazione è settimanale e l'avviso è dopo 2 ore, non può arrivare prima del **successivo slot settimanale**. Le notifiche richiedono che MacSync sia in esecuzione (e i permessi macOS siano concessi).
- Le informazioni sullo stato di disconnessione sono registrate in UserDefaults, senza credenziali SMB; i contatori e le condizioni non autorizzano rimontaggi automatici o eliminazioni. Se una cartella è assente, i lavori rimangono in SQLite e vengono ripresi dopo il ritorno della stessa destinazione.

### Limitazioni

- Avvio al login e avvio delle copie rimangono preferenze separate; le cancellazioni speculari sono sempre soggette alla conferma specifica per la sessione, mai automatizzate al login.
- MacSync non monta automaticamente la condivisione, non richiede username/password e non configura la VPN. L'avviso non è obbligatorio e non viene ripetuto a ogni controllo.
- Test CI simulano calendario giornaliero/settimanale, fusi orari/cambio ora legale, intervalli min/ore, soglia di notifica, una notifica per episodio e ripristino della destinazione. Servono comunque prove sul Mac con Finder, SMB e notifiche reali.

## MacSync v0.10.1 — correzioni di pianificazione e avvisi

- **Cadenza costante:** SyncSchedule.nextSlot usa l'ultimo slot programmato come riferimento, non la fine del trasferimento. Esempio 10:00 / 10:05 / 10:10; se il primo ciclo termina alle 10:07, lo slot 10:05 viene saltato e il nuovo ciclo è alle 10:10. Nessuna esecuzione parallela e nessuna raffica di slot arretrati.
- **Unico controllo programmato della connettività:** l'attivazione manuale e automatica non esegue probe SMB. Il runtime automatico attende il monitor locale e passa al worker lo slot originale; il worker può essere armato anche se la destinazione è offline. Solo il worker, allo slot successivo, verifica tutte le destinazioni prima di permettere operazioni. Le verifiche dell'identità del volume, delle sorgenti e dei percorsi durante la creazione delle mappature e i trasferimenti rimangono obbligatorie per sicurezza.
- **Stop:** prima di ogni nuova copia viene verificato il segnale di cancellazione; un trasferimento già iniziato può terminare. I job rimanenti restano nella coda. Le callback di una sessione fermata non aggiornano la nuova sessione.
- **Avvisi:** ConnectionOutageTracker considera inviato l'avviso solo dopo l'accettazione della richiesta da parte di UNUserNotificationCenter; se il sistema rifiuta o non è autorizzato, registra lo stato e ritenta al prossimo slot, senza timer supplementari. Le callback obsolete non possono confermare un nuovo episodio; il consenso e l'episodio vengono verificati prima della richiesta. Identificativo stabile per episodio; stato persistente. Notifica silenziosa anche in primo piano quando macOS lo consente. Disabilitando l'opzione si azzera il tracker.
- Nessuna modifica a frequenze, soglia 1–168 ore, assenza di rimontaggio automatico/credenziali/VPN gestita dall'app e conferma esplicita per le cancellazioni speculari.
- Test aggiuntivi: intervalli senza deriva o slot sovrapposti, ritardi giornalieri/settimanali, errore di invio e successivo tentativo, callback tardiva, stop della coda. Il collaudo SMB e la presentazione effettiva delle notifiche richiedono ancora un Mac fisico.

## MacSync v0.11 — resilienza e sicurezza

- Verifica di identità della sorgente per la durata della mappatura e della destinazione per la durata del singolo trasferimento. Controlli di directory, volume, symlink e percorsi riservati `.macsync-*` prima delle scritture.
- Prima della pubblicazione, verifica di snapshot del sorgente, del file temporaneo e del target originale (dimensioni, inode, device, mtime, ctime). Un target comparso o modificato durante la copia viene rinviato; la copia precedente viene preservata in un backup separato prima della sostituzione. Controllo dimensione del backup e del file pubblicato. Non è una transazione distribuita né una verifica hash completa.
- ChangeJournal.uploadIsCurrent impedisce la pubblicazione di job sostituiti da eventi più recenti durante lo staging. Se la conferma SQLite non avviene dopo la pubblicazione, il retry rilegge il job e può ripetere la copia. Temporanei e backup non vengono eliminati automaticamente in caso di guasto.
- MirrorDeletionWorker sospende le cancellazioni finché esistono upload pendenti; anche il ciclo applicativo sospende la retention in tale stato. Conserva il vecchio percorso remoto durante una rinomina se la copia del nuovo fallisce. Una coda bloccata può ritardare altre cancellazioni.
- LocalScanner distingue ENOENT dagli errori di accesso/I/O e verifica l'identità della radice prima e dopo la scansione. Una scansione fallita non modifica inventario, coda o checkpoint FSEvents.
- Test deterministici tramite fault injection locale: staging interrotto, retry con nuovo worker/connessione SQLite, modifica concorrente di sorgente e target, target comparso durante staging, root sostituita, spazio esaurito, pubblicazione senza conferma, job superato, symlink, rinomina con upload fallito e subtree inaccessibile.
- Restano necessari collaudo SMB reale e verifica con file grandi/archivio rappresentativo, atomicità e durabilità su Windows Server 2016, permessi, connessione intermittente e comportamento di macOS. I test non equivalgono a prove di crash del processo o di perdita alimentazione reali. Non utilizzare ancora dati di produzione.

## MacSync v0.12 — coda e prestazioni

- Il ciclo pianificato usa MountedFolderCopyWorker.runCycle: niente limite di 50 operazioni complessive. Acquisisce MAX(id) degli upload pendenti all'inizio; elabora pagine ordinate per ID di 100 record (limite interno configurabile nel core 1–1000). Non carica tutta la coda in memoria.
- Ogni ID viene tentato al massimo una volta per ciclo. Gli eventi nuovi, con ID superiore al limite acquisito, restano al prossimo slot; i job rimandati o falliti restano persistenti. Se la coda è vuota non accede ai singoli file. Nessun polling aggiuntivo o scansione ricorsiva della destinazione.
- Il controllo della sorgente, del volume e dei percorsi sicuri resta invariato. Un errore di volume/radice interrompe il ciclo, e una generica copyFailed verifica nuovamente la mappatura per non insistere su un volume scollegato. Stop protegge la coda; nessuna fase mirror dopo ciclo interrotto. Progress UI aggiornato a ogni pagina; una sola coda seriale, nessuna sovrapposizione fra slot.
- SQLite: nuovo indice root_id, relative_path, completed, id per verificare job ancora correnti; query con limite superiore e paginazione keyset tramite indice degli upload. Salvataggio delle impostazioni e schema precedente conservati; non si azzerano dati utente.
- Test: ampio ciclo con 235 file locali, coda sintetica da 20.000 record, eventi concorrenti, retry, interruzione/ripartenza, destinazione indisponibile e file sintetico di 64 MiB con controllo SHA-256 nel test. Non misurano banda reale o RAM durante uso SMB.
- Rinomine: rimane la procedura prudente upload prima, eventuale cancellazione dopo e solo in sessione mirror esplicitamente autorizzata. Non si interpreta una coincidenza di dimensione/data come prova di identità. Rinomina server-side e rimozione/riduzione dei backup restano da validare con SMB reale; nessuna ottimizzazione distruttiva introdotta. Nessun trasferimento di recupero parziale a offset implementato.
- Il bootstrap di archivio preseeded continua a supportare verifica SHA-256 esplicita, che legge anche i dati attraverso SMB: non dichiarare gratuito in banda. Test sintetici non dimostrano prestazioni per 100 GB, affidabilità SMB, o sicurezza di un ambiente produttivo.

## v0.12.1 — backup temporanei (punti 2 e 4 approvati)

- Mantiene copia in staging, copia separata della vecchia versione e FileManager.replaceItemAt: nessuna nuova strategia atomica o rinomina remota. Non cambia le impostazioni mirror, la cartella recupero o le coppie di cartelle.
- Il worker conferma in SQLite lo specifico job UPSERT con acknowledgeUpload: solo se il record è tuttora pendente e non superato da un evento più recente. Una conferma mancata conserva il backup.
- Solo dopo conferma riuscita tenta una pulizia puntuale del backup creato nella stessa operazione. Verifica volume, identità della radice e della directory padre, percorsi sicuri e snapshot di sorgente, pubblicazione e backup. Nessuna enumerazione della share, nessuna eliminazione ricorsiva o per pattern. Se esito dubbio, lascia il backup; un fallimento di pulizia non riaccoda una copia già confermata. Log backup_start, backup_cleanup, backup_retained con riferimento al file e al nome del backup nelle segnalazioni. Il log è soggetto alla retention ordinaria.
- Dopo crash/disconnessione, backup precedenti e residui non identificati con certezza non vengono puliti automaticamente, neanche dopo un retry riuscito. Possono richiedere manutenzione manuale. Non è un sistema di versioning, non garantisce durabilità dopo perdita di alimentazione e le verifiche correnti non sono una rilettura hash completa del file remoto. Collaudo reale SMB indispensabile per atomicità, permessi e comportamento in caso di guasto; nessuna rivendicazione di sicurezza assoluta in presenza di modifiche concorrenti tra controllo e unlink.
- Rinviata a sviluppi futuri la sostituzione con backup nativo (senza copia integrale) previa prova SMB. Nessun risparmio di traffico VPN garantito per la copia di sicurezza; riduce l'accumulo delle copie di sicurezza delle operazioni confermate.
- Punti 2/4 definiti; punto 3 ripresa parziale, punti 5/6/7 cancellazioni, punto 8 statistiche restano da concordare. Riconoscimento rinomine rinviato, nessuna correlazione tra coppie.

## v0.12.2 — ripartenza da zero e temporanei (punto 3 approvato)

- Confermato: dopo un'interruzione ripartire da zero soltanto per il singolo file non confermato; la coda SQLite resta persistente, i lavori già confermati non vengono ripetuti. Nuovo UUID staging per ogni tentativo, nessuna ripresa a offset o riuso di file parziali.
- Prima della pubblicazione, se un tentativo fallisce, verifica puntualmente la radice, il volume atteso, l'identità della cartella staging e il temporaneo del tentativo corrente (percorso UUID inizialmente assente, tipo file, snapshot invariato durante il controllo). Verifica anche che il sorgente sia ancora disponibile e invariato. Solo se tutti i controlli riescono elimina il temporaneo tramite unlink, senza toccare foto definitive, backup o altri temporanei. Nessuna scansione aggiuntiva SMB.
- Se la connessione è realmente assente, il sorgente cambia, le identità non corrispondono, o è già stata tentata la pubblicazione, conserva eventuali residui e registra staging_retained; non tenta pulizia indiscriminata dopo il riavvio. La manutenzione manuale preesistente resta disponibile con anteprima e conferma esplicita (soglia 7 giorni basata su mtime), non avviata automaticamente; riservare la cartella .macsync-staging a MacSync. Una caduta di rete o crash può ancora lasciare temporanei da rimuovere manualmente quando è sicuro. Nessuna garanzia assoluta contro modifiche concorrenti tra controllo e unlink.
- Test aggiuntivi: tentativi falliti ripetuti senza accumulo se la share è accessibile, temporanei storici inalterati, file e cartella staging sostituiti prima della pulizia, pubblicazione incerta. Test locali e fault injection, non prove di disconnessione SMB reale. 
- Ripresa parziale rinviata a possibile sviluppo futuro solo se le misure reali evidenzieranno necessità e beneficio netto; verificare contenuto già trasferito, identità del file, sorgente invariato e durabilità. Nessuna modifica a backup v0.12.1, mirror o interfaccia. Punti 5, 6, 7 e 8 ancora da concordare.

## v0.12.3 — cancellazioni persistenti e protezioni configurabili (punti 5, 6 e 7)

**Questa sezione sostituisce le regole storiche di autorizzazione per sessione e anti-mass-delete delle v0.8–v0.12.2.**

- L'utente abilita esplicitamente le cancellazioni speculari nelle impostazioni; scelta OFF di default e revocabile. Non riutilizzare il vecchio booleano v0.12.2 come consenso. L'abilitazione verifica le coppie (nessuna sovrapposizione), tutte le identità root/volume, e la corrispondenza dei percorsi/tipi dell'inventario locale. La capability persistente include identità DB, sorgenti, destinazioni e cutoff ID SQLite: nessun DELETE precedente all'autorizzazione o registrato durante la disabilitazione viene autorizzato retroattivamente.
- Avvio automatico delle copie e avvio al login restano preferenze separate. Quando la sincronizzazione automatica è abilitata, il mirror usa l'autorizzazione persistente soltanto dopo convalida a ogni nuova sessione; le stesse verifiche avvengono prima di scrivere. Stop ferma le nuove operazioni (quella già iniziata può terminare); il cambio delle cartelle revoca il consenso. Un'identità non verificabile sospende il ciclo. Device/inode SMB possono cambiare anche su un remount legittimo: va collaudato sul Mac reale; potrebbe occorrere riabilitare/verificare la coppia, senza replay automatico dei vecchi eventi.
- Tre protezioni indipendenti OFF per default: soglia assoluta 1000 (1–1000000), soglia 50% (1–100%), sorgente vuota. Finestra 24 ore, selezionabile 1/6/12/24/48 h. Conteggi per coppia: tutti i DELETE pendenti autorizzati più tentativi registrati nella finestra e non più pendenti (conservativo in caso di esito incerto); percentuale rispetto a inventario corrente + elementi conteggiati, directory comprese. Un eventuale blocco persistente SQLite impedisce tutti i cicli, anche dopo restart o disattivazione di mirror/protezioni. Controllo prima delle copie, prima della fase mirror e durante le cancellazioni; il monitor locale rimane operativo. Per sbloccare fermare la sincronizzazione, verificare sorgenti/coda, modificare le soglie o disattivare la protezione se appropriato, poi confermare il pulsante di rimozione blocco. Se la condizione persiste il prossimo ciclo si blocca di nuovo.
- Protezioni tecniche non disattivabili: sorgente e destinazione montate e identificate, baseline verificata, percorsi riservati anche case-insensitive, lstat senza seguire symlink, assenza reale del sorgente e job ancora corrente, priorità globale a TUTTI gli UPSERT, rmdir solo per cartella vuota, retention manifest-owned. Non c'è transazione distribuita con SMB né garanzia contro race filesystem/power loss.
- Coda DELETE: snapshot ID massimo, pagine keyset con path più lunghi prima dei genitori, 100 elementi per pagina nell'app, nessun tetto per ciclo. Ogni ID tentato al massimo una volta nello snapshot; nuovi eventi al prossimo ciclo. Nessun elenco ricorsivo della share né probe periodico aggiuntivo. La verifica esplicita dell'autorizzazione può accedere al volume fuori dal timer perché è un'azione dell'utente. Le copie restano prioritarie per entrambe le coppie, nessun riconoscimento di rename/spostamenti.
- Impostazioni modificabili fuori sessione attiva, senza nuova procedura di configurazione iniziale. L'interfaccia prototipo usa le impostazioni esistenti; restyling/wizard dedicato solo nella fase UI. Test locali: >1000 cancellazioni, riavvio con DB riaperto e consenso serializzato, eventi storici esclusi, sostituzione root/database, protezioni numeriche/percentuali/svuotamento indipendenti, latch persistente, finestra temporale, separazione coppie e coda upload. Collaudo fisico SMB e interfaccia ancora necessario. Punto 8 statistiche resta da affrontare.

## v0.12.4 — statistiche per ciclo, avanzamento e verifica completa (prototipo in collaudo)

- Mantiene **FileManager.copyItem** e tutte le protezioni v0.12.3. Nessuna sostituzione con copyfile(), nessuna ripresa a offset introdotta. I trasferimenti di staging e i backup vengono misurati solo dopo il completamento della rispettiva copia; la velocità è media pesata in byte/secondi di copia in staging, non un valore istantaneo né una misura del traffico fisico VPN. Backup, tentativi non completati e overhead SMB non sono inclusi in tale velocità; la dimensione dei backup completati resta separata.
- Nuovo storico SQLite locale (sync_cycles_v1 e sync_cycle_events_v1): orari inizio/fine, durata monotona, esito, sessione, esiti tipizzati per percorso e coppia. Conservazione 365 giorni, indipendente dal log tecnico 90 giorni / 20.000 record. I cicli interrotti da crash restano con fine ignota; non si inventano eventi mancanti. Un errore dello storico non autorizza modifiche remote né cambia il risultato del trasferimento; lo storico può risultare incompleto.
- Eliminati = file regolari rimossi specularmente (eliminazione definitiva + spostamento nel recupero); recuperabili è un sottoinsieme. Esclusi file già assenti, directory, backup, .partial, pulizia recuperi scaduti. Nuovi/aggiornati solo dopo conferma del job; non conteggiare housekeeping come file utente. I dettagli storici consentono ricerca, filtro coppia, ordinamento delle righe caricate e apertura con app predefinita/Finder; percorsi vincolati alla coppia corrente e al volume atteso. Il file aperto è la versione attuale, non uno snapshot; può non essere disponibile.
- Pannello live: controllo connessione, analisi coda, copia, backup, verifica/pubblicazione, cancellazioni, finalizzazione; percentuale per operazioni della snapshot di ID all'inizio del ciclo, esclusi job nuovi successivi, può restare sotto il 100% se sospesa/interrotta. La percentuale è lavoro elaborato, non byte o solo successi. Inizio e tempo trascorso aggiornato con TimelineView. Nessuna stima di percentuale durante un inventario di cui non si conosce il totale. Inventario locale iniziale: file, cartelle, dimensione rilevata, file/s. Seed SHA-256: job completati rispetto al piano, letture combinate locale+SMB, velocità media e stima prudente basata sui job; il seed continua a richiedere conferma separata prima di chiudere i job.
- Verifica completa separata, manuale o pianificata (giornaliera, settimanale, mensile, giorno 1–28). OFF per default; rapida default; correzione OFF. Impostazioni persistenti, disabilitate durante sessione attiva/operazioni di manutenzione. Cambio coppie disattiva pianificazione e riallineamento. Usa la stessa coda seriale delle copie, quindi nessuna scrittura contemporanea alla verifica; il monitor locale continua a funzionare. Se un'altra manutenzione è in corso o il monitor non è pronto, lo slot viene rinviato al successivo previsto. Non richiede scansioni SMB durante i cicli incrementali ordinari.
- Rapida enumera entrambe le radici e confronta tipi, dimensioni e mtime (tolleranza 2 secondi per differenze precisione SMB); non certifica l'identità del contenuto. Approfondita confronta SHA-256 dei file di dimensioni uguali, con lstat e rilevazione modifiche; lettura massima circa 100 GB SMB + 100 GB locali per archivio da 100 GB. La verifica segnala corrispondenti, mancanti, differenti, extra e incerti/conflitti. Esclude gerarchie riservate .macsync-, non segue symlink. Le directory sono indicate separatamente per tipo. Report dell'ultimo confronto salvato in JSON locale atomico (non copia foto), consultabile con contatori cliccabili.
- Riallineamento facoltativo: dopo una scansione completata e nuova verifica locale, accoda atomicamente soltanto UPSERT mancanti/differenti non in conflitto e non già pendenti; i job del monitor prevalgono. Nessuna cancellazione aggiuntiva per file extra; nessun override mirror o blocco di sicurezza. Nessuna scrittura diretta sul server da parte dell'audit. Se la sincronizzazione non è abilitata, le riparazioni restano in coda. Annullamento prima del commit non accoda nulla. Non è uno snapshot distribuito: cambiamenti esterni durante/dopo il confronto possono invalidare il report.
- Test nuovi in ArchiveAuditAndHistoryTests: confronto, metadati identici/contenuto diverso, esclusione temporanei, riallineamento non distruttivo, annullamento, conflitti e job pendenti, programmazione, storico, conteggi e velocità. **Stato: baseline v0.12.4 convalidata in CI il 16 novembre 2026.** [Run 43874841217](https://github.com/Peppio1/MacSync-Public/actions/runs/43874841217): 129 test superati, zero errori, build release e pacchetto ad hoc generati. La prima revisione (950e79e) ha superato 129 test funzionali e il test anteprime separato, con tre warning residui e segnaposto grafici osservati. La seconda revisione, dopo la correzione del parametro AppKit isPlanar, ha superato la CI al commit 0ce838d. Non usare sui dati reali prima del collaudo macOS/SMB. Grafica definitiva rimandata a v0.13.

## Test, limiti e sicurezza

GitHub Actions macOS 15 esegue swift test, swift build -c release e prepara un pacchetto sperimentale .app, firmato ad hoc e non notarizzato. I test usano cartelle locali sintetiche; **non verificano la VPN di test, una condivisione SMB effettiva né le prestazioni con 100 GB**.

Prima della versione di produzione servono:
- login item e verifica della riconnessione/riapertura condivisione SMB tramite macOS;
- robustezza in trasferimenti di file grandi PSD via VPN: dopo un'interruzione il singolo file viene ritentato dall'inizio; test reali di atomicità delle sostituzioni SMB, controllo degli hash e rotazione dei backup;
- bootstrap sicuro per file già copiati sul server (senza riconfronti integrali a ogni ciclo);
- collaudo su SMB delle cancellazioni protette, recupero e rinomine (attualmente replica tramite nuova copia e rimozione del vecchio percorso);
- collaudo sul vero iMac/macOS Sequoia e Windows Server 2016.

**MacSync sarà una replica, non un backup storico:** mantenere backup versionati indipendenti. Non caricare foto, password, dati VPN, log sensibili o database reali nel repository.

Per proseguire con Codex leggere AGENTS.md e docs/ARCHITECTURE.md.

## Anteprime grafiche automatizzate (sperimentali)

Il workflow **macOS UI Preview** è separato dalla compilazione principale. Su un runner macOS prova a renderizzare i componenti SwiftUI effettivamente utilizzati dall'app (`FolderDropZone`, `SyncSummaryMetric`, `AuditProgressView`) tramite `NSHostingView`, finestra di test AppKit e `cacheDisplay`, con dati sintetici in tema chiaro e scuro. L'artefatto `MacSync-UI-Previews` contiene sei PNG da 1680 × 840 pixel se il workflow riesce. Avvio manuale disponibile in Actions. I test di rendering normali sono opt-in tramite `MACSYNC_UI_PREVIEW_DIR`.

Non viene avviato il runtime MacSync, non vengono lette preferenze o cartelle reali, e nessuna copia o cancellazione viene eseguita. Le immagini sono anteprime dei componenti in un contenitore di prova, non screenshot dell'intera finestra, né test interattivi. La prima CI ha prodotto sei PNG con segnaposto per controlli nativi. La revisione AppKit ha eliminato i segnaposto nelle sei immagini verificate visivamente. Collaudo su macOS reale ancora indispensabile. La baseline v0.12.4 ha superato build e test; questa revisione UI resta sperimentale.

### Revisione SHA-256 e anteprime AppKit (convalidata in CI)

Verificatore e connessione SQLite creati nella coda seriale per ciascuna fase; l'interfaccia conserva sessione immutabile Sendable e report. Prima della riapertura si verificano device/inode e identità logica SQLite. Una sostituzione invalida la sessione; non è una garanzia contro ogni sostituzione arbitraria concorrente del database. Conferma esplicita, fingerprint, transazione condizionale e protezioni precedenti restano invariate. Quattro test di regressione coprono riapertura, sostituzione DB, eventi più recenti e annullamento.

Anteprime NSHostingView e cacheDisplay in finestra di test, dati sintetici, nessun runtime MacSync. Sei PNG con verifica dimensioni, contrasto e rilevamento euristico dei segnaposto giallo/rosso. Non sono ancora immagini della finestra completa. CI e ispezione grafica dei sei PNG completate; non usare dati reali prima del collaudo SMB.

## Baseline di sviluppo v0.12.4 — 16 novembre 2026

- Commit sorgente convalidato: `0ce838dbc5f71e93518a13f9d9188fd8fc62534b`.
- [macOS CI](https://github.com/Peppio1/MacSync-Public/actions/runs/43882303897): 133 test funzionali superati, un test UI saltato intenzionalmente, zero errori, zero warning nei log; build release e pacchetto ad hoc generati.
- [macOS UI Preview](https://github.com/Peppio1/MacSync-Public/actions/runs/43882303739): test di rendering superato, sei PNG 1680 × 840 px, tema chiaro/scuro, nessun segnaposto osservato durante l'ispezione visiva. I PNG mostrano componenti di produzione con dati sintetici, non ancora la finestra completa.
- Prossimo obiettivo v0.13: concordare navigazione, layout e stati dell'interfaccia; progettare anteprime dell'intera finestra senza avviare il motore o accedere a dati reali. Preservare tutte le protezioni e i test già convalidati. Nessuna approvazione per un restyling definitivo è ancora registrata. Il collaudo reale macOS/SMB/VPN resta obbligatorio prima dell'uso in produzione.


## v0.13 — interfaccia candidata e pianificazione

Menu laterale Panoramica, Cartelle, Pianificazione, Verifica archivio, Registro attività, Impostazioni; tema automatico/chiaro/scuro. Due coppie unidirezionali, controlli reali esistenti. Intervalli 1–59 minuti, 1–23 ore, default 5 minuti; inserimento numerico, +/- e scorciatoie, input non valido non salvato. Interruzione cooperativa obbligatoria per ogni operazione lunga, senza rollback di cancellazioni effettuate o abort forzato della pubblicazione atomica. Copertura completa di interruzioni, anteprime finestra v0.13 e CI da verificare. Nessun collaudo reale SMB eseguito.


### v0.13 — revisione annullamento (candidata)

Il test storico confronta le date con tolleranza 1 ms, mantenendo tutte le verifiche sui conteggi e aggiungendo il controllo della data di fine. Inventario iniziale interrompibile cooperativamente: scan cancellato non produce nuove cancellazioni; transazione di riconciliazione della singola sorgente annullata se lo stop precede il commit. Le sorgenti già confermate restano registrate. Confronto preliminare e manutenzione temporanei ora accettano cancellazione; le rimozioni già eseguite non vengono annullate. Nessun arresto forzato di una syscall SMB bloccante. Nuovi test e CI devono confermare. Le anteprime a dimensione finestra sono composizioni sintetiche dei componenti condivisi, non screenshot integrali delle pagine runtime. Il collaudo UI interattivo e SMB reale rimane necessario.


### v0.13.1 — CI consolidation

The pre-restyling baseline c9dacb5 passed 136 functional tests, with one rendering test skipped intentionally, zero logged Swift warnings and a successful release build (run 43906964134, attempt 2). Automatic main CI now uses one macOS runner for functional tests, release packaging and the 20 PNG previews; the preview step reuses the existing debug test binary with `swift test --skip-build --filter MacSyncUIPreviewTests`. The separate macOS UI Preview workflow remains manual-only. No cache or runner architecture change. The UI revision and new combined pipeline remain candidates pending CI and inspection; the previews are synthetic fixtures, not complete runtime interaction tests.


### v0.13.2 — UI/UX audit candidate

Rollback ref `rollback-v0.13.1` preserves exact validated commit 9d3614ef9d171d1d840cf7a0e30b0c054608f201. Shared header has persistent active-operation cancellation, 24h Italian times, state-aware switch rows, the existing session totals plus deferred count, a compact native selection table over latest 300 activity entries, and measured progress visualization. UI fixture renders actual configuration views with preview-only controller initialization, no real syncing, no timer or persistent fixture settings, and temporary synthetic history. Cycle-only cancellation distinguishes the current cycle from session cancellation while retaining existing mirror worker baselines and durable queue; tests must validate the new token state. Actual user interactions and live SMB remain untested. Existing log export retains its original search/esito semantics, not the additional local filters. No SQLite schema changes. Roll back code by reverting the candidate commit or using the preserved branch, never restore an older archive over newer photos.


### v0.13.3 — compact desktop layout candidate

Rollback: `rollback-v0.13.2` at af66c5e88073c1a8b7ba381feb178214630b3576 (137 functional tests plus rendering passed). This revision changes presentation only, using a compact overview, persistent stop-all, compact metrics, horizontal companion panels, aligned states and a shorter history viewport. Scroll remains available for long messages and advanced settings; no engine, database or persisted preferences changes. UI capture now includes standard 1180×820 and compact 1020×720 canvases in both themes (32 PNGs including component fixtures). Validate actual captures before accepting visual layout. Build version metadata is aligned to 0.13.3. No real SMB or interactive UI validation yet.


### v0.13.4 — annotated interface candidate

Rollback branch `rollback-v0.13.3` points to b110533a3ed4836f3068a3178ee232374214d9a3. Common folder plan is opt-in on confirmed edits, with existing legacy pairs retained until modification, stable IDs for unchanged pairs, separate target subfolders, case-insensitive collision/overlap checks, explicit creation of missing child folders and local retirement of inactive inventory/jobs. Folder changes revoke automated copying, mirror consent and audit repair; never delete archive files on configuration changes. Save schedule drains serial copy worker first, then persists and restarts enabled automatic cadence. UI uses approved annotations; tests and native screenshots pending. **Do not downgrade after changing folder topology without disabling automatic copying and restoring matching configuration/inventory from a verified backup; the code rollback branch alone is not a data rollback.** Real SMB validation still required. Existing recovery directories remain per mapping under .macsync-recovery, not arbitrarily redirected. No implementation of destructive log clearing or fabricated period counters.

Target creation is descriptor-anchored (`mkdirat`/`openat`) and checks the saved volume before/after; no automatic target creation during ordinary sync. Old automatic preference is explicitly cleared, v2 uses a separate key. The UI keeps fallback scrolling for exceptionally long content and keeps the existing detailed event history rather than fabricated period aggregates. Folder edit cancellation leaves copying/authorizations disabled conservatively. The new root retirement, mapping and symlink/volume tests add five functional cases. No actual screenshots yet.


### v0.13.5 — unified archive verification candidate

Rollback ref `rollback-v0.13.4` keeps validated 643b3aaa7988d131b0587f6a60208545c3d11871. The complete SHA-256 audit can reuse verified source and target fingerprints for existing pending UPSERT file jobs captured before scanning; approval still uses the existing identity-checked session and atomic conditional acknowledgement, never metadata-only and never DELETE. Recognition is manual, opt-in and pauses automatic copies; scheduled checks only use audit/repair settings. No deletion of destination-only files. Existing copies and monitoring semantics remain. Settings use independent vertically stacked columns to reduce holes. Previous metadata bootstrap preview is superseded by the quick diagnostic; old implementation remains available in code. CI and real screenshots pending; no live SMB validation.


### v0.13.6 — archive screen layout

Rollback `rollback-v0.13.5` retains 0d8b99443b927c3621166dc5d45b382332b8bbf6 (145 functional tests and rendering passed). Archive view now uses one configuration panel, right-side live progress and latest result, and a full-width maintenance strip. Existing audit, recognition/confirmation, scheduling and safety behavior retained; no changes to core or database schema. Preview-only fixture now creates a small actual audit report in temporary directories to show result rows while rendering synthetic in-progress telemetry. CI still needs to validate the new layout in both themes and window sizes.


### v0.13.7 — audit layout refinements

Rollback `rollback-v0.13.6` retains d00ccf6bbd2e653f1435b38550d180da3e6d2165 (145 core tests and UI rendering passed). Audit-only compact panels, balanced columns, compact two-column report counts, file path beside the cancel action, and explicit Italian weekday names in both schedules. All result categories and confirmation actions remain; no core or database changes. Added weekday label regression and six audit screenshot fixtures, including idle standard/compact and running at 980×660, total 38 PNGs. Scroll fallback remains for unusually long states rather than hiding actions. Actual screenshot inspection and interactive/SMB validation pending.
