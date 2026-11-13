# MacSync — prototipo v0.4.0

App macOS per futura replica unidirezionale iMac -> Windows Server 2016 via SMB/VPN, senza installare nulla sul server.

**IMPORTANTE:** questa versione NON è pronta per i 100 GB di produzione e non replica le eliminazioni. Le COPIE sono disponibili solo su attivazione esplicita e solo dentro la sottocartella MacSync_TEST_ONLY della condivisione scelta. Le operazioni sulla cartella principale di produzione restano esclusivamente di LETTURA.

## Cosa è implementato

- App SwiftUI nella barra dei menu macOS, selezione delle due cartelle locali Cartella_1 e Cartella_2.
- Monitoraggio ricorsivo con FSEvents, inventario SQLite e coda persistente delle modifiche.
- Scansioni locali mirate sui singoli file o sottoalberi interessati; riconciliazione locale all'avvio, dopo errori/eventi persi, e periodicamente.
- Coda dei trasferimenti selettivi con retry per errori di copia e file sorgente ancora in modifica. Non viene usato rclone sync per l'intero archivio ogni 5 minuti.
- Trasferimento rclone SMB di un singolo file in una posizione temporanea remota .macsync-staging, verifica successiva dei metadati locali e pubblicazione tramite moveto.
- Nessuna propagazione di cancellazioni al server, nessun purge, nessuna pulizia automatica di file temporanei remoti.
- Credenziali SMB: password nel Portachiavi macOS (Keychain), host/utente/dominio/nome condivisione nelle preferenze locali non segrete. La configurazione rclone viene creata per i singoli processi tramite variabili d'ambiente; non è necessario scrivere una password in rclone.conf.
- Pannello di test con attivazione manuale e temporanea delle copie ogni 5 minuti.
- Anteprima iniziale in SOLA LETTURA della condivisione vera: rclone lsjson ricorsivo solo su richiesta, confronto con scansione locale, differenze, file presenti solo sul server, nomi che collidono su Windows, residui di staging.
- Compilazione e test automatici su GitHub Actions macOS 15, con pacchetto sperimentale .app ad hoc NON notarizzato.

## Sicurezza delle operazioni

- Le copie di test sono SEMPRE indirizzate a macsync_smb:NOME_CONDIVISIONE/MacSync_TEST_ONLY/Cartella_1 e macsync_smb:NOME_CONDIVISIONE/MacSync_TEST_ONLY/Cartella_2. NON eseguono scritture nelle sottocartelle Cartella_1 o Cartella_2 di produzione.
- L'anteprima iniziale legge invece le vere sottocartelle di produzione con rclone lsjson: non modifica né marca come sincronizzati i file.
- Un match tra dimensione e timestamp è soltanto una CORRISPONDENZA PRESUNTA, non una verifica byte-per-byte. Non abilita automaticamente salti di copia né cancellazioni.
- I file temporanei caricati su server possono rimanere in .macsync-staging dopo un errore. La pulizia automatica è da sviluppare e testare; NON eliminare manualmente cartelle di altri utenti.
- rclone moveto può SOVRASCRIVERE un file già esistente nella cartella di test; comportamento di rinomina e atomicità deve essere verificato realmente contro Windows Server 2016.
- Condivisione SMB interrotta, dati locali assenti e altre anomalie devono lasciare operazioni in coda. La politica di mirror con eliminazioni rimane disabilitata.
- Tenere un backup versionato indipendente: MacSync è progettato come copia speculare, non come archivio storico.

## Configurazione SOLO PER TEST su un Mac disponibile

1. Installare rclone solo sull'iMac. Windows Server non richiede programmi aggiuntivi.
2. Aprire MacSync, selezionare due cartelle locali di prova con file sintetici.
3. Inserire host/IP VPN SMB, nome utente, dominio (di default WORKGROUP), nome della condivisione Windows, password e percorso dell'eseguibile rclone (di norma /opt/homebrew/bin/rclone su Mac Apple Silicon o /usr/local/bin/rclone su Mac Intel).
4. Premere Salva: password nel Keychain, nessun rclone config manuale richiesto.
5. Premere Anteprima iniziale (sola lettura) per confrontare le cartelle reali del server: operazione potenzialmente lunga, da fare solo quando necessario; non parte ogni 5 minuti.
6. Premere Attiva copie di prova e confermare l'avviso: MacSync scriverà soltanto in MacSync_TEST_ONLY all'interno della share, senza cancellare o modificare file nelle vere cartelle di produzione.
7. Premere Ferma copie per bloccare nuovi cicli. Un upload già iniziato può terminare.

**Attenzione:** il primo giro registra nella coda SQLite tutti i file locali. Per ora il sistema NON riconcilia automaticamente le copie manuali già presenti sul server senza ritrasferirle. È un requisito di produzione ancora da implementare dopo verifica dell'anteprima.

## Limitazioni e attività aperte

- I test GitHub Actions confermano compilazione, logica della coda, simulazioni del motore rclone e test nativi FSEvents. Non verificano autenticazione reale, Keychain sbloccato su un Mac di test o copie reali sulla VPN.
- Manca collaudo su SMB reale, prestazioni e semantica della rinomina verso Windows Server 2016; la pubblicazione atomica non è garantita fino al test.
- Manca pulizia controllata dei file temporanei, bootstrap sicuro senza ricopiare i file già seminati sul server, gestione delle cancellazioni/rinomine remote e protezioni contro cancellazioni di massa.
- Manca avvio automatico al login, distribuzione di rclone insieme all'app, notifiche degli errori, interfaccia separata delle impostazioni, notarizzazione Apple e collaudo di lungo periodo.
- Il passaggio a funzionamento completamente autonomo sarà consentito solo dopo test end-to-end su macOS Sequoia e VPN.

Per gli sviluppatori e Codex: leggere AGENTS.md e docs/ARCHITECTURE.md. Tutto il codice è destinato all'uso commerciale gratuito; non caricare foto, credenziali, indirizzi VPN, log o database reali nel repository.
