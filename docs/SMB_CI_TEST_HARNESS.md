# MacSync — banco di test SMB reale, separato dalla release

**Stato:** sviluppo sperimentale sul ramo `develop-smb-integration-harness`, derivato da `develop-v0.18.15-name-rectification-performance`. Non incorporato in `main`, nessuna release o firma.

## Principio e confini

L'obiettivo è creare test automatizzati **attraverso il client SMB nativo di macOS**, non soltanto emulazioni con directory locali. Il workflow [macOS SMB Integration](../.github/workflows/macos-smb-integration.yml) utilizza un runner `macos-15` (Apple Silicon), installa Samba temporaneo con Homebrew e avvia una condivisione accessibile **esclusivamente da `127.0.0.1`**, con account e password generati per il job. La condivisione viene montata tramite `mount_smbfs` e riconosciuta dal kernel come `smbfs`. Tutti i dati sono sintetici, non usa mai credenziali né server aziendali, e una fase `always()` smonta e rimuove la fixture.

**Questo ambiente non equivale a Windows Server 2016 o a una rete VPN reale**. Le differenze nella semantica ACL, file ID, timestamp, Unicode, nomi vietati, latenza e interruzioni remote richiedono ulteriori test. Non abilitare fallback di produzione per far passare i test.

## Test introdotti

In `Tests/MacSyncCoreTests/SMBIntegrationTests.swift`:
- Prova di montaggio reale `smbfs`, creazione e rilettura di contenuti sulla share.
- Operazioni `MountedFolderCopyWorker` tramite Rclone `rcloneDirect` verso destinazione montata: nuovo file, aggiornamento, byte e coda SQLite.
- Test diretto dell'helper `rclone-smb-rename`: rinomina con controllo dell'identità del file; rifiuto della collisione, nessuna sovrascrittura.

I test sono **opt-in**, attivi solo con `MACSYNC_TEST_SMB_*`; per le suite ordinarie senza fixture producono uno skip esplicito. I test realmente riusciti e quelli falliti devono essere distinti consultando i log del run, non dedotti dalla sola compilazione.

## Metriche e confronto onesto

Il workflow cronometra con `scripts/ci/record-duration.py`: installazione Samba, montaggio, preparazione Rclone, compilazione helper, compilazione test Swift, test Rclone locale, test SMB. `scripts/ci/report-smb-benchmarks.py` genera un report in GitHub Step Summary e un artefatto di soli **dati temporali**, senza configurazioni o password. La pulizia non archivia config, dump o dati della fixture.

**Riferimenti storici verificati dai log GitHub Actions:**

| Riferimento | Runner | Durata registrata | Confrontabilità |
|---|---|---:|---|
| CI v0.18.14, 248 test, 4 saltati, 0 errori, run 44905111203 | macos-15-intel | 101,780 s | Durata suite su fixture locali |
| CI v0.18.15, 254 test, 6 saltati, 0 errori, run 44917066447 | macos-15-intel | 81,895 s | Suite differente e runner fisico non identico |
| Rinomina locale v0.18.15, 1.000 nomi, run 44917066447 | macos-15-intel | 5,292 s | Fixture locale, non SMB |

**Non usare queste differenze per affermare un guadagno prestazionale controllato.** I test SMB usano hardware ARM64 e percorsi di rete loopback; il confronto più utile è fra tempi di test locale e SMB nello stesso job, indicando sempre tipo/dimensione dei file. Neppure tale rapporto equivale a tempi di una VPN.

## Problemi di compatibilità individuati nella prima implementazione

- GitHub job `env` non ammette `runner.temp`: occorre valorizzare `$GITHUB_ENV` da uno step.
- macOS `stat -f '%T'` non identifica il tipo del filesystem: usare la tabella mount del kernel.
- `mount_smbfs -N` non ha recuperato la password da una configurazione temporanea; la fixture ha utilizzato una credenziale casuale mascherata e mai persistita nel repository.
- Samba e il client macOS possono gestire in modo diverso ACL e diritti di scrittura: il controllo di autenticazione e la scrittura con `smbclient` **non** sostituiscono una prova di scrittura attraverso il mount `smbfs`. La configurazione della fixture disabilita la mappatura NT ACL di Samba per il solo banco di test, preservando le protezioni implementate nell'app.
- Il workflow deve rifiutare con errore qualsiasi mount non `smbfs` o una share che non permetta di creare e rimuovere una cartella di test. **Non saltare silenziosamente i test SMB in caso di errore setup.**

## Da sviluppare in seguito

Se il primo banco è verde: (1) test audit rapido e profondo su SMB, (2) errori/timeout, collisioni e file modificati durante una copia, (3) test mirati nomi incompatibili e semantica Windows, (4) metriche dei roundtrip `stat` e delle directory, (5) stress opt-in con 1k–100k file, (6) test UI comportamentali, (7) compatibilità finale Windows Server fisico su dataset sintetico. La CI di pubblicazione e la firma restano indipendenti.
