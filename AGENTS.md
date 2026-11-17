# AGENTS.md — MacSync

## Stato corrente — v0.15.0 (consolidamento)

Repository pubblico: Peppio1/MacSync-Public. App nativa Swift/SwiftUI, sincronizzazione unidirezionale locale Mac → locale/SMB già montato. Baseline verificata 2cc398b, workflow 43985988474: 167 test ordinari superati, nessun fallimento, rendering separato e 48 PNG. Durata accelerata, inventario sintetico e telemetria CI superati; regressione v0.15.0, risorse reali e collaudo fisico restano da completare. Nessuna modifica funzionale non richiesta.

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
- Modifiche puramente documentali non richiedono incrementi di versione. La fase successiva è consolidamento e verifica del pacchetto universale; aggiornare le evidenze soltanto dopo risultati effettivi.

## Riferimenti

[Baseline convalidata](https://github.com/Peppio1/MacSync-Public/actions/runs/43985988474) · [Rollback](https://github.com/Peppio1/MacSync-Public/tree/rollback-v0.14.3-validated) · [Storico sviluppo](docs/DEVELOPMENT_HISTORY.md).

## Aggiornamenti v0.16.0
Non abilitare installazione automatica o manuale in-app senza firma Ed25519 verificata, feed e chiave pubblica incorporata, shutdown con backup verificato e rollback collaudati. Non pubblicare chiavi private nel repository o nei log. Baseline rollback-before-v0.16.0-updater.
