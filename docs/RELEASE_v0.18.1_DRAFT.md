# MacSync v0.18.1 — candidato in validazione

Base: 7851e8982f39b12148cd665594fd1fde53b660d6; rollback: rollback-before-v0.18.1-archive-and-shutdown.

- Rapida: stessa dimensione e mtime entro due secondi; nessun confronto contenuto.
- Intelligente: hash SHA-256 solo per file con stessa dimensione e date discordanti.
- Completa: confronto SHA-256 integrale dei file corrispondenti.
- Il riconoscimento manualmente avviato è applicato automaticamente alla coda, senza seconda conferma. Si possono disattivare riconoscimento e riparazioni per un audit puramente diagnostico. Le verifiche periodiche restano senza riconoscimento. Le copie sono sospese durante il riconoscimento; nessuna cancellazione o scrittura remota viene prodotta dall'allineamento. Prima del commit sono ricontrollati fingerprint, identità, job e inventario.
- Trasferimenti singoli invariati. Stima della fase di confronto separata, campione minimo e progressione del ricontrollo.
- Spegnimento finale facoltativo, disattivato per default: orario/giorni, copie automatiche preautorizzate, ciclo iniziato dopo l'orario con esito completo, nessuna coda residua, nessun errore/rinvio; avviso annullabile 60 secondi, ricontrollo locale. Richiesta ordinaria macOS mediante System Events, nessun sudo. Permessi Automazione, comportamento con altri programmi, standby e logout da verificare su Mac reale.
- Chiusura ordinaria: cancella nuovi lavori, tenta drenaggio; dopo 15 secondi risponde al sistema senza aspettare indefinitamente SMB. Non modifica percorso separato di aggiornamento Sparkle. WAL e staging sono limiti di recupero; test reali su SMB durante l'arresto restano obbligatori.

Non pubblicare senza risultati di CI verificati e approvazione esplicita. Non considerare queste funzioni validate su un Mac reale prima del collaudo.

## Accorgimenti finali approvati

- Riepilogo immutabile dell’ultima verifica, confronto sorgente/destinazione, contatori di soli file cliccabili. I candidati a cancellazione sono solo job già autorizzati e soggetti alle protezioni del worker; i file extra non generano DELETE.
- Ogni verifica manuale o pianificata riconosce i candidati e accoda le differenze sicure, senza scritture remote. Prima delle modifiche alla coda viene creato un backup SQLite verificato e conservato in audit-backups; nessuna rimozione automatica dei backup. Le due opzioni grafiche sono rimosse. Le verifiche pianificate attendono copie ferme e non forzano una copia in corso.
- Ultimo controllo destinazioni e inventario locale completo, coda e generazione monitoraggio prima dello spegnimento. Non è un blocco dei programmi esterni: rimane necessaria la prova su Mac e SMB reale.
- Benchmark opt-in con 200.000 file piccoli per lato, nessun hash nella verifica rapida. Non è una misura di latenza VPN.
