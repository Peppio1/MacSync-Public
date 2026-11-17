# Aggiornamenti software — v0.16.0 in sviluppo

## Prima fase
Interfaccia approvata: pannello sopra Informazioni, versione, data/ora ultimo tentativo, Controlla, toggle automatico (default attivo), indicazione di stato. Nessun selettore canale. Verifica interna ogni 24 ore; menu-bar accessibile anche senza finestra. Solo GitHub releases/latest: pre-release escluse, nessun downgrade, confronto numerico e URL fisso del repository. Errori di rete non equivalgono a versione aggiornata; una 404 indica assenza di una release stabile o servizio non raggiungibile per quella risorsa. Preview non usa rete o preferenze. Nessuna installazione automatica; pulsante apre la release nel browser.

## Snapshot
UpdateRecoverySnapshot prepara copia autonoma verificata SQLite, sole preferenze MacSync e copia del bundle precedente, in cartella privata univoca; nessun ripristino automatico. Il chiamante futuro deve detenere il lock archivio e fermare tutte le operazioni. Test con dati sintetici, non ancora invocato dalla UI.

## Blocco di sicurezza prima di abilitare l'installazione
1. Provisionare chiavi Ed25519 Sparkle (generate_keys) in ambiente fidato. Solo chiave pubblica nel bundle; privata conservata in segreto del proprietario, mai in Git, log o chat.
2. Configurare la libreria Sparkle 2 con versione fissata, framework e helper nel bundle universale, appcast HTTPS contenente solo release stabili firmate; testare la compatibilità ad hoc/non notarizzata e Gatekeeper.
3. Verificare firma prima di qualunque sostituzione. La conferma precede download/installazione; niente installazioni silenziose o al quit generico.
4. Arrestare nuovi cicli, drenare worker e watcher, impedire scritture concorrenti; snapshot verificato prima di autorizzare l'installatore. Disabilitare il passaggio in caso di qualsiasi errore.
5. Conservare bundle precedente con metadata e proteggere il backup dati. Marcatore di transazione e preflight al riavvio; ripresa copie solo dopo validazione. Non ripristinare un vecchio database su nuove modifiche; rollback esplicito e coordinato.
6. Testare aggiornamento reale, firma errata, pacchetto alterato, riavvio fallito, backup non possibile, interruzione e rollback su Mac reale. La CI non sostituisce tale collaudo.

Nessuna chiave privata o Secrets scritti con il connettore attuale. Nessuna promessa che Sparkle funzioni con la firma ad hoc senza collaudo. Fino al completamento dei punti sopra l'installer in-app resta indisponibile.

## Seconda fase — comportamento e laboratorio firma

Il comando esplicito "Prepara aggiornamento" dalla finestra di avviso usa il normale shutdown del runtime: interrompe pianificazione e worker, attende la fine delle scritture e del monitor, conserva il lock archivio e crea uno snapshot in update-backups. Solo dopo il backup apre la release e chiude MacSync. Se il backup fallisce, nessuna release viene aperta; il runtime rimane fermo e l'utente deve uscire e riavviare. Nessun ripristino automatico, nessun installatore in-app. Il pannello mantiene la struttura approvata, con una nota veritiera sull'installazione manuale.

Packaging/test-sparkle-signing.sh scarica la distribuzione ufficiale Sparkle 2.10.0 con SHA-256 fissato, compila una sonda universale e verifica il caricamento della libreria ad hoc senza avviare l'updater. Usa chiavi effimere soltanto per firmare il pacchetto e un feed di prova, verificando il rifiuto di file alterati e chiave errata. Non produce appcast pubblico o chiavi persistenti. La sonda non è MacSync, non dimostra un aggiornamento reale.

Per la produzione il proprietario deve generare e custodire la chiave su un dispositivo fidato. Seguire https://sparkle-project.org/documentation/ usando la distribuzione ufficiale 2.10.0 verificata: bin/generate_keys --account macsync-release; acquisire solo la chiave pubblica tramite bin/generate_keys --account macsync-release -p. Non inviare o incollare la privata in chat; conservarla in Keychain e in backup protetto. Se si automatizza la pubblicazione, configurare un ambiente GitHub protetto con secret dedicato e approvazione manuale; non consegnare la chiave a workflow su pull request. Abilitare SUVerifyUpdateBeforeExtraction e SURequireSignedFeed, disabilitare SUAllowsAutomaticUpdates, pubblicare solo feed stabile firmato. L'integrazione in-app resta bloccata fino alla gestione della chiave, implementazione preflight/rollback e collaudo reale.
