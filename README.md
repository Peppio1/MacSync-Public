# MacSync

App macOS per la futura sincronizzazione unidirezionale iMac -> Windows Server 2016 tramite SMB/VPN.

**Stato: v0.3.0 sperimentale. NON utilizzare sulla condivisione di produzione.** Le copie di prova sono facoltative e devono essere esplicitamente abilitate ogni volta che si avvia l'app. Nessuna cancellazione remota è disponibile.

## Requisiti definitivi
- Nessuna installazione o servizio sul server Windows, soltanto SMB.
- Gratuito anche per uso commerciale.
- Due cartelle locali configurabili: Cartella_1, Cartella_2.
- Replica unidirezionale Mac -> server con nuove copie, modifiche, rinomine ed eliminazioni.
- Obiettivo: ogni 5 minuti, evitando ricontrolli ricorsivi SMB dell'archivio intero.
- Database SQLite, FSEvents, ripristino operazioni pendenti e controllo interruzioni VPN.

## Implementato e testato con GitHub Actions macOS 15
- App SwiftUI nella barra dei menu e monitoraggio FSEvents.
- Inventario locale SQLite, coda persistente e scansioni locali mirate.
- Controllo completo solo locale all'avvio, ogni 24 ore o se si perdono eventi.
- Motore selettivo rclone: comando copyto di UN file, mkdir di UNA cartella; non lancia sync e non enumera l'intera destinazione a ogni ciclo.
- Convalida delle destinazioni e dei percorsi, controllo file sorgente con lstat prima/dopo il trasferimento, rinvio file in scrittura.
- Retry delle operazioni fallite, senza chiudere indebitamente una voce della coda.
- I job di cancellazione locale sono memorizzati ma NON elaborati dal motore SMB.
- Pannello di configurazione sperimentale, attivazione manuale per sessione e controlli ogni 5 minuti.
- Test su file cambiati durante la copia, retry, symlink, path traversal, cartelle vuote, coda SQLite, eventi FSEvents.

## Procedura SOLO PER PROVE con dati sintetici
1. Installare rclone soltanto sul Mac.
2. Creare sul Mac un remote rclone di tipo SMB mediante il comando rclone config. Credenziali e host VPN restano in locale e non sono condivisi su GitHub.
3. Nell'app scegliere cartelle locali di TEST, non cartelle di produzione.
4. Nel pannello SMB inserire il remote e la share di TEST, per esempio: macsync_smb:CondivisioneDiProva. L'app aggiunge le due sottocartelle Cartella_1 e Cartella_2.
5. Indicare il percorso di rclone, normalmente /opt/homebrew/bin/rclone sui Mac Apple Silicon oppure /usr/local/bin/rclone sui Mac Intel.
6. Premere Salva, poi Attiva copie di prova e confermare. Prima esecuzione dopo circa 10 secondi, successivamente ogni 5 minuti. Nessuna cancellazione è possibile.
7. Il pulsante Ferma copie impedisce nuove esecuzioni; un trasferimento in corso potrebbe terminare.

La configurazione rclone è privata e rimane soltanto sul Mac. L'oscuramento della password nel file rclone.conf NON equivale a crittografia forte: il rilascio finale richiederà il Keychain.

## Limiti aperti
- Nessun collaudo su SMB reale, VPN e Windows Server 2016; test del comando rclone effettuati con esecutore simulato.
- Mancano: cancellazioni e rinomine remote sicure, bootstrap verificato dei 100 GB già presenti, copie temporanee/rename atomico dei file PSD, Keychain, binario rclone incluso, avvio automatico al login, notifiche.
- Non è stato verificato l'uso prolungato su iMac Sequoia o la velocità reale.
- Il pacchetto GitHub Actions è firmato ad hoc ma NON notarizzato.
- Una copia speculare non sostituisce un backup versionato.

Vedi AGENTS.md e docs/ARCHITECTURE.md per le istruzioni di sviluppo e le protezioni obbligatorie. Non caricare fotografie, credenziali, configurazioni private, database SQLite o log sensibili nel repository.
