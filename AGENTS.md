# AGENTS.md — MacSync

## v0.18.5 — candidato Rclone

Ramo develop-v0.18.5, rollback rollback-before-v0.18.5-rclone (release v0.18.4).
Rclone 1.76.0 incorporato come helper universale, copia esclusivamente nello staging MacSync. Il motore nativo resta disponibile internamente, nessuna impostazione o cambio automatico dopo errore. Protezioni, pubblicazione esclusiva, backup, SQLite, mirror e audit restano invariati. CI e collaudo SMB necessari; non promuovere a stabile. Consultare docs/DEVELOPMENT_v0.18.5.md.

## v0.18.4 — candidato

Sviluppo sul ramo develop-v0.18.4; rollback rollback-before-v0.18.4. Pubblicazione solo dopo CI verde, firma e verifica del pacchetto; il collaudo SMB reale resta necessario. Vedere docs/DEVELOPMENT_v0.18.4.md. Nessun dato dei log reali deve essere committato.

## v0.18.3 — sviluppo candidato

Ramo develop-v0.18.3; rollback rollback-before-v0.18.3. Non pubblicare prima di CI verde e verifica della strategia SMB. Nessun log o dato aziendale reale nel repository. Vedere docs/DEVELOPMENT_v0.18.3.md.

## Sviluppo v0.18.2 (non pubblicato)

Ramo `develop-v0.18.2`; rollback `rollback-before-v0.18.2` sulla v0.18.1. Le indicazioni storiche sotto non rappresentano lo stato attuale. Consultare `docs/DEVELOPMENT_v0.18.2.md`. Non pubblicare senza esiti effettivi CI, collaudo SMB reale e approvazione esplicita.

## Stato corrente — v0.17.0 (branding e DMG)

Repository pubblico: Peppio1/MacSync-Public. Pre-release attuale v0.17.0 pubblicata il 17 novembre 2026: https://github.com/Peppio1/MacSync-Public/releases/tag/v0.17.0. Commit del pacchetto 2fe7037cf135f2cbd0051343885875a50aa6c015, CI 44072456998 (177 test ordinari, 2 opt-in separati, 48 PNG, originale verificato, DMG, installazione e recupero Sparkle, firma Ed25519), pubblicazione 44074982577 completata. v0.16.0 validata ma non pubblicata separatamente. Prossima fase: collaudo fisico con dati sintetici, poi 1.0.0-rc.1. Non sostituire il PNG approvato. Non dichiarare stabilità prima della validazione reale.

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
- Modifiche puramente documentali non richiedono incrementi di versione. La fase successiva è collaudo fisico v0.17.0; preparare 1.0.0-rc.1 solo in base agli esiti; aggiornare le evidenze soltanto dopo risultati effettivi.

## Riferimenti

[Baseline convalidata](https://github.com/Peppio1/MacSync-Public/actions/runs/43985988474) · [Rollback](https://github.com/Peppio1/MacSync-Public/tree/rollback-v0.14.3-validated) · [Storico sviluppo](docs/DEVELOPMENT_HISTORY.md).

## Aggiornamenti v0.16.0
Non abilitare installazione automatica o manuale in-app senza firma Ed25519 verificata, feed e chiave pubblica incorporata, shutdown con backup verificato e rollback collaudati. Non pubblicare chiavi private nel repository o nei log. Baseline rollback-before-v0.16.0-updater.

La procedura corrente è in docs/UPDATES.md. Il secret MACSYNC_SPARKLE_PRIVATE_KEY è già configurato e verificato: non rigenerarlo. Il workflow protetto può firmare solo candidati dopo regressione verde. Non pubblicare automaticamente, non ripristinare mai un DB precedente. Rollback codice: rollback-before-v0160-integrated-recovery-signing.

## v0.17.0
Vedere docs/INSTALLATION.md e Packaging/Branding/README.md. Rollback della v0.16.0: rollback-v0.16.0-validated-before-v0.17.0. Non modificare il motore o i percorsi dati per interventi grafici. Firma solo dopo originale verificato e CI verde. Non pubblicare automaticamente.

## Pubblicazione v0.17.0
Release e 8 asset verificati; tag sul commit testato 2fe7037cf135f2cbd0051343885875a50aa6c015. Rollback: rollback-v0.17.0-validated-before-prerelease. Non sovrascrivere gli asset/tag pubblicati, non promuovere la pre-release a stabile. Per le correzioni usare una nuova versione e rispettare la sicurezza del feed. Documentazione successiva alla compilazione non modifica i pacchetti.
