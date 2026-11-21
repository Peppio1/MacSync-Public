# v0.18.15 — Correzione dei tentativi ripetuti in caso di destinazione SMB indisponibile

**Stato:** ramo di sviluppo isolato `develop-v0.18.15-smb-outage-recovery`, derivato dalla candidata `develop-v0.18.15-smb-rename-stability`. Nessun merge, firma o pubblicazione.

## Problema operativo

Durante un lotto già confermato, la perdita del mount SMB, della credenziale o un timeout possono provocare una sequenza di operazioni remote fallite sulla **stessa coppia**, con molte attese. Il piano SQLite deve restare integro; l'app non deve tentare una rinomina remota per ogni voce quando l'indisponibilità comune è già nota.

## Intervento conservativo

- `NameRectification.execute` introduce un **circuit breaker in memoria, limitato alla singola esecuzione e alla coppia destinazione**. Un primo guasto infrastrutturale riconosciuto sospende i tentativi sulle altre voci di quella stessa destinazione per il resto del lotto, mantenendole tutte pendenti. Le rettifiche della sorgente locale e delle altre coppie procedono quando sono indipendenti.
- Classificazione volutamente ristretta: mount/credenziale non disponibili, helper mancante/non avviabile, root o volume non validi, timeout oppure errori POSIX di rete noti. Non sospendere in blocco la coppia per collisione, divergenza di fingerprint, `helperFailed` generico o risposta ambigua: questi rimangono casi puntuali da verificare.
- Ogni elemento differito resta nel piano già approvato di SQLite; il primo guasto viene registrato e gli elementi successivi producono l'evento sanitizzato `name_rectification_shared_destination_deferred`. I contatori includono i nomi non verificati, anche se non si rilancia un'operazione su di essi.
- Il breaker non implementa un **retry automatico**: il ripristino rimane esplicito mediante la funzione esistente “Riprendi rettifica”. A ogni ripresa vengono rivalidate identità volume, directory, vecchio/nuovo nome e fingerprint prima di qualsiasi mutazione.
- Nessuna modifica al modulo Go `RenameNoReplace`, nessun fallback POSIX SMB, nessuna copia+delete, nessun permesso aggiuntivo. Il lotto pendente continua a sospendere per sicurezza le copie e il mirror della coppia finché non è stato riconciliato.

## Prove aggiunte

`NameRectificationTests.testDestinationOutageDefersSiblingsButLocalMoveContinuesAndResumes`: sposta fuori dal percorso una destinazione **sintetica locale** dopo il preflight persistito, verifica un solo tentativo fallito sull'intera coppia, due elementi differiti senza operazioni, rettifica della sorgente indipendente, conservazione dei dati e ripresa con un nuovo `ChangeJournal` dopo il ritorno della destinazione.

`testSharedDestinationFailureClassificationIsStrict`: tipologie infrastrutturali distinte da collisione, file in modifica e risultati ambigui.

**Limiti:** i test sintetici locali non dimostrano che Windows Server 2016/Finder SMB/VPN si riprendano correttamente da ogni guasto. Occorre collaudo mirato su mount SMB reale con disconnessione/riconnessione, timeout, Portachiavi e cache, senza foto operative. Le metriche di tempo dipendono dalle syscalls e dalla rete; non dichiarare soluzione definitiva senza CI verde e prova reale.

## Validazione

La macOS CI è configurata sul ramo in `.github/workflows/macos-ci.yml`; esiti da annotare dopo il termine della run, mai anticiparli.
