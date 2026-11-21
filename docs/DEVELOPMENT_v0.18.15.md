# MacSync v0.18.15 — rettifica nomi: ottimizzazione e coordinamento

**Stato:** candidata di sviluppo in `develop-v0.18.15-name-rectification-performance`, derivata dalla candidata v0.18.14 documentata. Nessun merge, rilascio o firma di produzione. Il riferimento distribuito resta v0.18.13; v0.18.14 non è stata pubblicata.

## Modifiche circoscritte

1. **Preflight meno costoso.** La verifica preparatoria riutilizza `AuditDirectoryListingCache` per leggere una sola volta l'elenco dei figli di una directory invariata, fino ai limiti di cache già previsti, invece di enumerarlo da zero per ogni candidato. La cache controlla identità e timestamp della directory, si invalida sulle modifiche e non autorizza mai direttamente una scrittura.
2. **Verifica esclusiva intatta.** La rinomina effettiva continua a controllare dal vivo la directory, il nome vecchio, le collisioni e l'identità dell'oggetto. La sorgente e le destinazioni locali continuano a usare `renameatx_np(RENAME_EXCL)`. Il lato SMB utilizza soltanto l'helper Rclone dedicato; **nessun fallback alla rinomina nativa remota**.
3. **Dipendenze per lato.** L'indice delle rettifiche differite usa coppia, lato e antenati del percorso: una rinomina fallita sulla destinazione non rinvia automaticamente la rinomina della sorgente *allo stesso percorso*. I figli e i genitori realmente dipendenti dello stesso lato restano coordinati. Un lotto incompleto rimane persistente in SQLite e impedisce il normale ciclo di sincronizzazione fino alla riconciliazione.
4. **Metriche di lentezza.** Il registro registra solo le fasi superiori a 500 ms come `metric_name_rectification_phase`, distinguendo preparazione, listing esecutivo, rinomina nativa/SMB con verifica finale, scrittura SQLite e durata complessiva. Nessuna credenziale viene registrata.

## Test

- Nuova regressione `testDeferredDestinationAtSamePathDoesNotBlockLocalSourceAndCanResume`: collisione destinazione indotta **dopo** il preflight; la sorgente deve essere rinominata, il lotto deve restare pendente e la ripresa deve completare soltanto l'operazione remota restante.
- Nuova regressione `testPreflightCacheKeepsSiblingListingAndInvalidatesOnCollision`: 200 nomi in una directory invariata provocano una sola enumerazione preparatoria; una collisione aggiunta successivamente obbliga un refresh e impedisce la rinomina.
- Benchmark locale `testLocalNameRectificationBenchmark100` incluso nella suite ordinaria; prova da 1.000 file attivata esplicitamente sul ramo da GitHub Actions; prova da 10.000 file disponibile soltanto su richiesta mediante `MACSYNC_STRESS_NAME_RENAMES=1`.

Questi test sono sintetici e locali. **Non dimostrano che l'helper SMB Rclone sia già stato validato su Windows Server reale**; mancano ancora tempi rilevati attraverso Finder/SMB e verifica del comportamento con VPN, disconnessioni, credenziali, collisioni e interruzioni.

## Compatibilità e limiti

- Non cambiano FSEvents, coda ordinaria di trasferimento, mirror, controllo volumi, firma o reset.
- Le verifiche costose *prima* della mutazione non vengono eliminate: si evita soltanto di enumerare nuovamente gli stessi fratelli durante il preflight. La validazione finale rimane live, perciò il beneficio totale dipende dal numero di file per directory.
- Un errore SMB durante il preflight di una controparte può ancora bloccare la preparazione della coppia: non viene modificato questo vincolo senza una riprogettazione del piano persistente che garantisca l'assenza di percorsi orfani.
- La serializzazione del piano residuo SQLite in presenza di molti errori differiti e l'avvio di un processo helper per ogni rename SMB richiedono misure e un intervento successivo, non una semplificazione cieca.

## Gate prima di promozione

CI macOS completa e benchmark locali senza regressioni; poi prova su cartelle **sintetiche** local/Finder SMB e Windows Server con tempi per fase, documentazione dei risultati, conferma di nessun overwrite, ripresa e stop sicuri. Nessuna release senza autorizzazione.
