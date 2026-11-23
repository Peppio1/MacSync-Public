# MacSync v0.18.17 — Inventario locale iniziale senza accodamento massivo (collaudo)

Questa versione è un **aggiornamento di collaudo**. Non è una certificazione dell'archivio operativo su Finder SMB/Windows Server/VPN. La release precedente v0.18.16 rimane disponibile.

## Correzioni principali

- Su un **database locale nuovo**, il primo inventario di ciascuna sorgente memorizza `file_inventory` senza creare un UPSERT per ogni file e cartella. Le fotografie già presenti non vengono interpretate automaticamente come copie da effettuare. I controlli di root/binding restano transazionali.
- All'avvio, il checkpoint FSEvents viene acquisito **prima** della scansione. Le modifiche avvenute durante l'inventario e dopo l'avvio vengono riprodotte dal monitor e accodate normalmente. Le scansioni successive su sorgenti già conosciute continuano a registrare le variazioni rilevate.
- Una **verifica archivio QUICK manuale** dopo la prima configurazione confronta l'inventario locale e la destinazione SMB con una sola acquisizione remota prevista dall'audit e genera le copie necessarie esclusivamente per file/cartelle mancanti o differenti. INTELLIGENT mantiene i controlli SHA-256 selettivi sui file dubbi.
- La fase *Salvataggio operazioni nel database* mostra l'avanzamento dei job registrati e la fase *Riconciliazione coda iniziale* indica separatamente l'eventuale lavoro sui vecchi job `initial_inventory`. Questo non introduce scansioni SMB supplementari.
- La protezione dei job FSEvents, della coda storica `legacy_unknown`, delle rinomine incompatibili, dei volumi e del mirror resta invariata. Nessun file o cartella viene eliminato dal nuovo comportamento dell'inventario.

## Procedura di prova con archivio preesistente

1. **Prima del ripristino**, conserva all'esterno un backup verificato di impostazioni, log e database MacSync che ti interessa mantenere. La funzione di azzeramento elimina anche i backup interni dell'app, e le operazioni non ancora trasferite non vengono recuperate automaticamente dopo il reset.
2. Installa la v0.18.17 dall'applicazione già in uso tramite **Impostazioni → Aggiornamenti software → Controlla**. Completa l'installazione e controlla la versione `0.18.17 (197)`.
3. Con copie automatiche e mirror disattivati, seleziona **Impostazioni → Ripristino MacSync → Azzera tutti i dati…**. L'app si chiuderà e completerà il reset al successivo avvio, cancellando impostazioni, database, coda, registri e backup interni. **Non tocca fotografie/cartelle sul Mac o sul server, né le credenziali del Portachiavi**.
4. Riapri MacSync e configura le cartelle sorgenti e destinazione corrette. Attendi il completamento dell'**Inventario locale iniziale**. In assenza di modifiche FSEvents successive, la coda deve risultare **vuota** anche per sorgenti già popolose. Una coda vuota non dimostra che il server contenga già gli stessi file.
5. Avvia manualmente una **Verifica archivio rapida (QUICK)**, verifica il report e lascia che vengano accodate le effettive differenze. Possono esserci più job rispetto al conteggio dei soli file, per esempio per cartelle mancanti o eventi nuovi. Nessun numero è garantito prima del confronto.
6. Mantieni le copie e il mirror disabilitati finché non hai verificato la lista dei job, i percorsi, i permessi e il comportamento su dati di prova. La modalità QUICK conferma corrispondenza **dei metadati**, non un hash completo del contenuto.

## Test e limiti

La suite Swift/macOS, i test di migrazione SQLite, di FSEvents e di primo inventario, il benchmark sintetico locale con 200.000 file, i pacchetti universali Intel/Apple Silicon e Sparkle devono essere verificati dal relativo workflow GitHub prima del rilascio firmato. I benchmark misurano il filesystem del runner, **non** la velocità della condivisione SMB o deun archivio remoto reale.

La v0.18.17 non modifica o svuota automaticamente le code preesistenti: soltanto il ripristino completo, eseguito dall'utente dopo la conservazione dei backup necessari, ricrea il database da zero. Non ripristinare un vecchio SQLite sopra nuove operazioni.

Documentazione tecnica: [Baseline locale e coda](DEVELOPMENT_v0.18.17_INITIAL_BASELINE.md).
