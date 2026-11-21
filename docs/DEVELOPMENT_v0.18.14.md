# MacSync v0.18.14 — candidato: prestazioni della verifica archivio

**Stato al 21 novembre 2026:** codice candidato verificato dalla CI macOS, **non rilasciato né incorporato in `main`**. I benchmark disponibili sono **locali e sintetici**; il collaudo su Finder/SMB/VPN reale resta necessario.

- Ramo: [`develop-v0.18.14-audit-performance`](https://github.com/Peppio1/MacSync-Public/tree/develop-v0.18.14-audit-performance)
- Baseline e punto di rollback del codice: `79f71d07216baf3de0f5d3e1bc0c3e8ea26d86dc` (v0.18.13 pubblicata).
- Ultimo commit funzionale sottoposto a CI: `bfc6aee97f56390f7044225562301857968686ff`.
- [GitHub Actions — CI completa, run 44905111203](https://github.com/Peppio1/MacSync-Public/actions/runs/44905111203).

## Scopo e perimetro

Ridurre le richieste ripetute di metadati e i controlli dei percorsi durante la **verifica archivio rapida**, soprattutto quando esistono molte operazioni da riconoscere nella coda SQLite. L'obiettivo operativo di completare la verifica entro un'ora **non è ancora verificato sulla rete SMB reale**.

Non cambia il normale ciclo incrementale: FSEvents e coda SQLite rimangono attivi; Rclone continua a elaborare i trasferimenti puntuali; nessuna nuova scansione completa della destinazione viene aggiunta al ciclo ordinario. Nessuna modifica alla politica di cancellazione speculare, alla gestione delle credenziali o al motore di copia.

## Modifiche tecniche

1. **Riutilizzo dei fingerprint della scansione.** `LocalScanner` conserva, solo durante l'inventario, i metadati ottenuti tramite `lstat` senza seguire symlink. `ArchiveAudit` li riutilizza nella modalità rapida per file e directory candidati al riconoscimento, riducendo letture duplicate e ripetizioni di controlli sui percorsi.
2. **Approvazione in gruppi limitati.** La verifica finale usa lotti di 32 candidati, con directory genitrici ancorate a descrittori aperti senza seguire collegamenti simbolici e controlli puntuali dei singoli file tramite `fstatat`. Identità di radici e genitori vengono ricontrollate; elementi mutati, incerti o non verificabili rimangono in coda. Il numero di descrittori temporaneamente mantenuti è limitato.
3. **Compatibilità di sola lettura.** Solo se alcuni controlli sui descrittori non sono supportati dal filesystem è previsto il ritorno alla precedente verifica esatta dei percorsi. Non è un fallback del trasferimento Rclone alle operazioni native SMB.
4. **SQLite e annullamento.** Il riconoscimento non marca come completate operazioni di cancellazione; la conferma delle corrispondenze continua a essere condizionata dai controlli finali e dall'operazione transazionale. L'annullamento non deve produrre riconoscimenti parziali.
5. **Fingerprint transitorio escluso dalla rilevazione delle modifiche.** Il nuovo campo `TrackedItem.verificationFingerprint` non viene salvato in SQLite: il confronto `TrackedItem.==` è quindi esplicito e considera soltanto `relativePath`, `kind`, `size`, `modifiedAt` e `changeStamp`. Un secondo inventario di file invariati non deve creare nuovi job. Correzione: `50e89800`; test dedicato: `bfc6aee9`.
6. **Telemetria.** La durata della fase di riconoscimento viene registrata anche in presenza di errore o annullamento.

**Precisazione sulla modalità rapida:** dimensione e timestamp coerenti non dimostrano l'identità dei byte. Le modalità SHA-256 intelligente e completa restano distinte e non vanno descritte come equivalenti alla verifica rapida.

## Evidenze automatizzate

Il primo candidato, `e6f85b9`, aveva fallito la CI [44903800448](https://github.com/Peppio1/MacSync-Public/actions/runs/44903800448) con 9 asserzioni non soddisfatte in 5 casi di test: il fingerprint transitorio partecipava erroneamente al confronto con i record persistiti. Dopo la correzione e il test aggiuntivo, la CI [44905111203](https://github.com/Peppio1/MacSync-Public/actions/runs/44905111203) è risultata **verde**.

| Verifica | Risultato rilevato |
|---|---|
| Suite Swift | 248 test, 4 saltati, 0 fallimenti |
| Regressioni del riconoscimento (fingerprint temporaneo, file modificato, symlink genitore) | Superate |
| Benchmark con 200.000 file per lato e 48.000 directory per lato | Superato; file di contenuto letti: 0 byte nella modalità rapida |
| Fase di confronto del benchmark precedente | 147,254 s |
| Fase di riconoscimento/conferma nello stesso benchmark | 48,601 s |
| Esecuzione complessiva riportata dal benchmark, inclusa preparazione dei dati | 368,908 s (il solo caso di test è riportato in circa 418,5 s) |
| Test di 50.000 differenze reali dopo azzeramento coda | Superato; circa 185,938 s per il test; fase di accodamento riportata in 108,535 s; nessuna scrittura nella destinazione |
| Build universale Intel/Apple Silicon, DMG/ZIP, test Sparkle con chiavi temporanee e anteprime UI | Superati |
| Firma definitiva di produzione e pubblicazione release | **Non eseguite** per il ramo di sviluppo |

Le durate dipendono dall'hardware e dal filesystem del runner macOS; **non costituiscono una previsione affidabile dei tempi su SMB/VPN**. Gli artefatti caricati da GitHub Actions sono temporanei, destinati alla validazione e non corrispondono a una release firmata per la distribuzione.

## Validazioni ancora necessarie

- Prova su Mac fisico con **dati di test** e destinazione SMB già montata da Finder, senza utilizzare l'archivio operativo.
- Misurazione distinta di scansione sorgente, scansione destinazione, confronto e approvazione finale; confronto ripetibile con la v0.18.13.
- Verifica con latenza e interruzione della rete, volume rimontato/sostituito, file modificati durante la scansione, cartelle spostate o sostituite da symlink e nomi incompatibili.
- Controllo che nessun file venga confermato erroneamente nella coda, che le cancellazioni restino protette e che annullamento e ripresa non provochino effetti indesiderati.
- Test di compatibilità effettiva di `openat`/`fstatat` sul filesystem SMB target. Il fallback di sola lettura può essere più lento, ma non deve ridurre le protezioni.
- Solo dopo misure e test reali decidere se modificare ulteriormente il motore di inventario, promuovere il ramo e preparare una nuova release.

## Regole di promozione

La v0.18.13 pubblicata e il relativo commit restano il punto di rollback del **codice**, non un ripristino degli archivi o del database. Non fare merge su `main`, non firmare né pubblicare v0.18.14 senza verifica del candidato esatto, collaudo richiesto e autorizzazione esplicita. Non aggiungere log reali, dati privati o segreti al repository pubblico.
