# MacSync v0.15.0 — Baseline di validazione

Pre-release per collaudo, non release stabile. MacSync replica cartelle locali verso destinazioni locali o SMB.

## Novità
- Consolidamento del codice v0.14.3 senza modifiche al motore, allo schema SQLite o alle impostazioni.
- Pacchetto universale Apple Silicon (arm64) e Intel (x86_64), firma ad hoc e checksum SHA-256.
- Documentazione italiana aggiornata.
- La pipeline di pubblicazione richiede il superamento dei test, delle build, dei controlli del bundle e delle 48 anteprime.

## Evidenze precedenti
Il workflow 43985988474 ha superato 167 test ordinari, zero fallimenti, rendering separato riuscito. I test includono 96 cicli accelerati e un inventario di 10.000 file.

## Installazione
Scaricare lo ZIP e il relativo .sha256. Verificare con `shasum -a 256 -c MacSync-v0.15.0-macOS-universal.zip.sha256` nella cartella dei download, estrarre MacSync.app e spostarla in Applicazioni. Il pacchetto non è notarizzato; non disattivare Gatekeeper globalmente. Consultare il README.

## Limiti
Test eseguiti con dati sintetici e cartelle locali. La build universale verifica la presenza delle due architetture, non certifica l'esecuzione fisica su entrambe. Il bundle non contiene un'icona dedicata approvata; resta l'icona di sistema e il simbolo della barra menu. L'applicazione installata, SMB/VPN, permessi Windows, sospensione, stabilità prolungata e consumo risorse reale devono ancora essere collaudati. Non usare su archivi di produzione.

## Rollback
Il ramo rollback-v0.14.3-validated preserva il commit 2cc398bc2c86543628460fefeb1aaecaf17e8ce8. Salvare database e preferenze prima di sostituire l'app; un rollback Git non ripristina i dati.
