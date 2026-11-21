# v0.18.15 — Stabilizzazione della rettifica SMB

**Stato: candidata di sviluppo, non distribuita.** Ramo `develop-v0.18.15-smb-rename-stability` dalla base v0.18.15 con sole modalità utente QUICK e INTELLIGENT. Riferimento conservato nel ramo `rollback-before-v0.18.15-smb-rename-stability`.

## Problema riprodotto

Su condivisione Samba temporanea, montata come `smbfs` macOS, la rinomina diretta protetta con helper SMB falliva sui file appena scritti perché l'helper via SMB leggeva un `mtime` diverso da quello ricevuto da macOS. Una rinomina di un file lasciato stabilizzare aveva avuto successo direttamente sul server; la cache delle directory del mount poteva continuare a mostrare per qualche momento il vecchio percorso.

## Correzioni circoscritte

1. `Packaging/RcloneSMBRename/macsync_rename.go`: se e solo se il controllo di `mtime` sul **file aperto** non coincide con il valore fornito dal client macOS, il codice permette al massimo 11 verifiche con 250 ms di intervallo. Ogni tentativo ripete sul medesimo oggetto aperto nella relativa chiamata `RenameNoReplace` le verifiche **esatte** di File ID, creation time, tipo di oggetto, symlink, e per i file dimensioni e timestamp. Una discordanza di ID, birth time, tipo, dimensione, permessi, collisione o un esito SMB ambiguo **non produce alcun retry**. Non è introdotta alcuna tolleranza ai timestamp.
2. `Sources/MacSyncCore/NameRectification.swift`: **soltanto dopo un successo esplicito del server**, il client attende fino a 3,5 s, mediante letture di sola verifica, che il mount macOS non mostri più il vecchio nome e mostri il nuovo, con identità del file ancora corrispondente al piano persistito. Se la visibilità non converge, il lotto resta pendente: non si effettua una seconda rinomina, copia o cancellazione.

Il motore FSEvents, SQLite, Rclone per le copie ordinarie, la scansione inventario, mirror e gli audit QUICK/INTELLIGENT restano invariati. La protezione no-overwrite `ReplaceIfExists=0` resta obbligatoria.

## Regole di validazione

- Test locale e compilazione macOS su entrambi gli arch.
- Banco di integrazione SMB reale `smbfs`, con file appena creato, verifiche del percorso sul server e client, timestamp volutamente errato (rifiuto garantito), collisione su nome già esistente e rinomina di directory con contenuto preservato.
- In caso di mancato risultato verde, NON pubblicare o modificare `main`. Valutare nuovamente la divergenza prima di allentare i controlli.
- Gli esiti Samba non equivalgono a test conclusivi di Windows Server 2016 e rete VPN.

## Limite conosciuto

La convergenza dei metadati non è garantita su tutti i server/driver. In caso di divergenza permanente è corretto **fallire chiusi** e conservare le operazioni, invece di falsare una riuscita. Nessun fallback verso operazioni POSIX native su SMB, copia+delete o retry indiscriminato di una rinomina dall'esito incerto.
