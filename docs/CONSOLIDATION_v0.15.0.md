# Verifica di consolidamento v0.15.0

Baseline: 2cc398b (167 test ordinari superati, 1 rendering separato; workflow 43985988474).
Rollback: rollback-v0.14.3-validated.

- Revisione statica mirata: controller di pianificazione e runtime, autorizzazioni mirror, inventario, journal e migrazione, archivio e copia. Nessun refactoring funzionale introdotto. Non costituisce audit esaustivo di ogni percorso concorrente.
- Package.swift: macOS 13, Swift tools 5.9, nessuna dipendenza Swift esterna; SQLite e framework di sistema. Nessun nuovo componente o licenza.
- Configurazione: intervalli 1–59 minuti, 1–23 ore; copie automatiche e avvio al login separati; mirror non autorizzato per default; recupero e protezioni facoltative invariati.
- Database: schema additivo v0.14 invariato, lock e backup verificato invariati. Nessuna migrazione v0.15.
- Packaging: identificativo com.macsync.prototype mantenuto per non spezzare preferenze; CFBundleShortVersionString 0.15.0, build 150; firma ad hoc, versione minima 13.0; voce barra menu invariata. Nessuna icona .icns presente nella baseline: non introdotta senza approvazione grafica.
- CI: test e build con warning Swift trattati come errori, build arm64 e x86_64, lipo, verifica firma prima/dopo estrazione, checksum, rendering 48 PNG. Pubblicazione condizionata al successo; non è test fisico Intel né verifica notarizzazione.
- Esito v0.15.0: in attesa della CI. Nessun risultato dichiarato prima del completamento.
