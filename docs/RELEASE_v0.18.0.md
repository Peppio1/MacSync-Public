# MacSync v0.18.0 — Aggiornamento di collaudo

Release sul canale stabile GitHub per consentire l'aggiornamento dall'app v0.17.0. Non è la versione 1.0 definitiva e il collaudo su Mac fisico e SMB/VPN rimane necessario.

## Novità
- Riepilogo dell'ultima sincronizzazione, storico dei cicli individuali e dettagli; modalità manuale/automatica per i nuovi cicli.
- Operazione corrente dinamica, stime di tempo residuo, contatori sorgente/destinazione e velocità di lettura SHA-256 separate.
- Registro tecnico consultabile, copiabile ed esportabile; maggiori dettagli sugli errori e sulle cause di interruzione.
- Indicazione delle cartelle problematiche e controlli di disponibilità in sola lettura; interruttore automatico condiviso tra le schede.
- Verifica archivio in lettura durante la riconciliazione ordinaria dell'inventario. Guasti e cambi di configurazione interrompono in sicurezza; le riparazioni mantengono il controllo rigoroso.
- Miglioramenti visuali del riconoscimento dei file e diagnostica dell'avvio al login.

## Aggiornamento
Dalla v0.17.0 installata in Applicazioni: Impostazioni → Aggiornamenti software → Controlla → Prepara aggiornamento. Seguire la conferma Sparkle. L'aggiornamento prevede arresto delle operazioni e backup verificato. Dopo il riavvio verificare cartelle e impostazioni; riabilitare esplicitamente le autorizzazioni operative sospese dall'aggiornamento. Il DMG universale rimane disponibile come alternativa manuale.

Richiede macOS 13+; Intel e Apple Silicon. Bundle ad hoc, non notarizzato; ZIP e feed firmati Ed25519. Non disabilitare Gatekeeper globalmente. La firma del feed non equivale a notarizzazione Apple.

## Validazione
Build esatta: 0eddaeb1a35255546068b914df0ddbb5257af14b. [CI superata](https://github.com/Peppio1/MacSync-Public/actions/runs/44109583293): 183 test ordinari superati, 2 test opt-in eseguiti separatamente; otto fasi di recupero, installazioni isolate, rifiuto ZIP manomesso, 50 anteprime. Il laboratorio Sparkle usa versioni e chiavi dimostrative. La causa effettiva dell'interruzione osservata sul Mac, l'avvio al login e la migrazione in ambiente reale devono essere verificati con il collaudo. Non usare dati aziendali senza validazione e backup indipendente.
