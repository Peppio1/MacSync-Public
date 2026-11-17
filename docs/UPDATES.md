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
