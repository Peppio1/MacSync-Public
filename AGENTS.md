# AGENTS.md — MacSync

## Stato corrente — v0.16.0 (candidata aggiornamenti)

Repository pubblico: Peppio1/MacSync-Public. Ultima pre-release v0.15.0. Ultima CI conclusa con successo: commit 56555ce, run 44066873367, 177 test, 48 PNG, installazione Sparkle e rifiuto ZIP manomesso. v0.16.0: recupero e preflight integrati su processi separati e firma della nuova build in validazione. Collaudo fisico ancora obbligatorio.

Consultare [README.md](README.md) e [architettura corrente](docs/ARCHITECTURE.md). Le istruzioni storiche sono conservate in [AGENTS_HISTORY.md](docs/AGENTS_HISTORY.md); NON applicare le vecchie specifiche al posto dei comportamenti correnti.

## Vincoli operativi

- Solo sorgenti locali, destinazioni locali o SMB accessibili da Finder. Nessun componente sul server, nessuna gestione VPN o credenziali.
- UI grafica, coppie separate, selezione/drag and drop. Nessuna sovrapposizione; validare identità persistenti e volume.
- FSEvents e SQLite; coda durevole, pagine e snapshot per ciclo. Frequenze 1–59 minuti, 1–23 ore, giornaliera e settimanale. Avvio al login distinto dal consenso adeguato.
- Zero eliminazioni per sorgenti assenti, errori, timeout, volume cambiato o percorsi non verificati. Mirror OFF di default, consenso persistente, cutoff, upload prioritari; protezioni tecniche obbligatorie, soglie quantitative facoltative OFF per default.
- Staging, verifica stabilità, pubblicazione prudente, conferma condizionale e backup protetti. Nessun resume byte per byte, nessun rename remoto intelligente; esiti incerti preservati.
- Audit rapido o approfondito, diagnostica di default, riparazioni solo UPSERT esplicite. Nessuna ricorsione SMB ad ogni ciclo. Non eliminare file extra automaticamente.
- Non falsificare statistiche, percentuali, tempi o risultati. Distinguere copie concluse, errori, rimandati, housekeeping e cancellazioni effettive.
- Prima di modifiche operative preservare un punto di rollback verificabile. Non alterare foto, archivi o preferenze reali; non considerare rollback Git come ripristino dati.
- Test su dati sintetici e CI macOS 15. Non considerare il progetto stabile prima del collaudo fisico macOS/SMB/VPN. Non introdurre segreti, percorsi o dati aziendali nel repository pubblico.
- Modifiche puramente documentali non richiedono incrementi di versione. La fase successiva è validazione candidata v0.16.0, poi icone/DMG/guida e collaudo reale; aggiornare le evidenze soltanto dopo risultati effettivi.

## Riferimenti

[Baseline convalidata](https://github.com/Peppio1/MacSync-Public/actions/runs/43985988474) · [Rollback](https://github.com/Peppio1/MacSync-Public/tree/rollback-v0.14.3-validated) · [Storico sviluppo](docs/DEVELOPMENT_HISTORY.md).

## Aggiornamenti v0.16.0
Non abilitare installazione automatica o manuale in-app senza firma Ed25519 verificata, feed e chiave pubblica incorporata, shutdown con backup verificato e rollback collaudati. Non pubblicare chiavi private nel repository o nei log. Baseline rollback-before-v0.16.0-updater.

La procedura corrente è in docs/UPDATES.md. Il secret MACSYNC_SPARKLE_PRIVATE_KEY è già configurato e verificato: non rigenerarlo. Il workflow protetto può firmare solo candidati dopo regressione verde. Non pubblicare automaticamente, non ripristinare mai un DB precedente. Rollback codice: rollback-before-v0160-integrated-recovery-signing.
