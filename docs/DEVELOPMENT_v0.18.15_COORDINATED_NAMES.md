# MacSync v0.18.15 — Riconciliazione dei nomi e isolamento delle rettifiche pendenti

**Candidato non pubblicato** sul ramo `develop-v0.18.15-coordinated-name-reconciliation`. Baseline `develop-v0.18.15-smb-outage-recovery`; rollback `rollback-before-v0.18.15-coordinated-name-reconciliation`. Nessuna firma o release automatica.

## Contesto operativo

Un lotto di rinomine approvate può essere completato sul lato sorgente ma ancora pendente sul lato SMB. In passato, `MountedFolderCopyWorker.prepareCycle` rifiutava **l'intero** ciclo per qualunque piano pendente. Audit e mirror non consultavano direttamente la corrispondenza vecchio/nuovo nome prima di classificare mancanti/extra o procedere a cancellazioni.

## Intervento

- `NameRectification.pendingProtection(journal:)` decodifica il **piano approvato già persistente** nella tabella SQLite `name_rectification_batch`, rispettando `next_move`. Non deduce una relazione da dimensione/timestamp. In caso di piano corrotto, blocca con errore invece di rimuovere la protezione.
- La proiezione in memoria indicizza vecchio e nuovo percorso per coppia, inclusi gli antenati e i discendenti. Preparazione O(N × profondità), consultazione per percorso O(profondità): non confronta in maniera lineare ogni job con tutti gli N nomi pendenti.
- `MountedFolderCopyWorker` ammette i job **indipendenti** ma differisce quelli nel piano pendente. Non esegue Rclone, letture SHA-256 o ricopie per quei percorsi; il trasferimento rimane in SQLite. Resta globale il blocco di integrità DB, coda e identità volume.
- `ArchiveAudit` riconosce il percorso protetto **prima** di determinare missing/extra o eseguire SHA-256 intelligente: lo segnala come `uncertain` con dettaglio “Rettifica nomi registrata e ancora pendente”, senza accodare riparazioni. Una seconda lettura SQLite prima dell'enqueue evita che una nuova rettifica venga ignorata nella fase finale. QUICK e INTELLIGENT restano invariate per i file non protetti, DEEP non ricompare nell'interfaccia.
- `MirrorDeletionWorker` salta i vecchi/nuovi nomi protetti e ricontrolla il piano prima di ogni operazione. Le copie non protette in coda continuano a bloccare le eliminazioni; le sole copie protette possono essere ignorate dal gate globale senza derogare alla protezione dei percorsi. Un nuovo upload durante il ciclo riattiva il gate.
- Il registro SQLite `name_rectification_batch` conserva piano, offset e selezione dei lati approvati. La migrazione additiva `progress` conserva la compatibilità con i database precedenti. `name_rectification_completed` è un piccolo indice transazionale per le **sole conferme dei lati**, non un secondo piano con identità o fingerprint. Lo stato già esistente in `progress` rimane decodificabile. La conferma lato, la posizione nel piano e la protezione della destinazione sono aggiornate nella stessa transazione SQLite. Non serve SHA per registrare la rinomina.
- L'interfaccia Nomi incompatibili mostra conteggi locali e remoti completati/pendenti; la cache nomi non viene sostituita. L'app consente copie manuali o automatiche su percorsi indipendenti anche con una rettifica aperta. Dopo manutenzione può essere ripristinato **solo il consenso alle copie automatiche già dato in precedenza**, senza autorizzare automaticamente nuove cancellazioni mirror.

## Sicurezza non negoziabile

- Niente fallback nativo SMB, né `copy+delete`, `sync` o scansioni SMB ricorsive nel ciclo ordinario; rimane l'helper `RenameNoReplace` con controllo di identità, montaggio e collisioni.
- Una rettifica non confermata non autorizza alcuna copia, ACK o DELETE sul vecchio/nuovo percorso, né sui relativi discendenti e genitori.
- L'associazione tra nomi è valida **solo** per piani esplicitamente approvati e identificati. Non costituisce una prova generale che due contenuti siano identici su due volumi; fuori da questo percorso, la sincronizzazione dei contenuti continua a usare le normali verifiche protette. Non promuovere questa logica a rename remoto di normali spostamenti dell'utente.
- Il mirror mantiene la necessità di autorizzazione persistente, i limiti di sicurezza e la priorità generale degli upload non protetti.

## Test aggiunti o estesi

- Rettifica locale riuscita, collisione remota dopo preflight, persistenza del lato completato dopo riapertura del journal, completamento successivo.
- QUICK e INTELLIGENT con mismatch di percorso del piano: `uncertain`, zero SHA causati dalla rettifica, nessun UPSERT di riparazione.
- Un file non coinvolto viene copiato mentre il batch della rinomina è ancora aperto; byte originali e collisione preservati.
- Mirror con pending di rinomina e upload protetto: non cancella il vecchio/nuovo nome, ma può elaborare un delete indipendente autorizzato.
- 5.001 relazioni/20.000 query di indice in test sintetico, con verifica di antenati/descendenti e isolamento fra coppie.
- Test precedenti dell'helper SMB, collisioni, interruzioni, ripresa, e migrazione QUICK/INTELLIGENT rimangono obbligatori.

## Limiti e gate

Ancora necessari prima di qualsiasi pubblicazione: test finali CI macOS sul commit esatto, test d'integrazione su reale `smbfs` con guasti/interruzioni e profilo con Portachiavi, verifica su Windows Server 2016 e VPN con dati sintetici, casi di rinomina cartella contenente molti oggetti, benchmark sul carico reale e confronto del percorso post-rename con i contenuti già riconosciuti. I test locali e Samba loopback **non** dimostrano da soli la compatibilità Windows/VPN. In presenza di una rinomina completata ma senza prova di identità/contenuto precedentemente validata su entrambi i lati, **non** eliminare i controlli del motore di trasferimento per evitare una copia: è un limite di sicurezza da risolvere senza inferenze da sola dimensione/data. Anche la ripresa automatica su riconnessione senza azione dell'operatore rimane un'area da collaudare: il recupero già approvato dall'interfaccia resta disponibile, senza retry remoto indiscriminato.

Nessun percorso o dato reale nei test pubblici.
