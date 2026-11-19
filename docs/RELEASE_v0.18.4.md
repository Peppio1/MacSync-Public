# MacSync v0.18.4 — Aggiornamento di collaudo

## Novità
- Rettifica dei nomi incompatibili sulla sorgente locale: selezione singola, multipla, tutti o visibili; anteprima e conferma esplicita.
- Spazi e punti finali eliminati, caratteri vietati sostituiti con un trattino. Nomi riservati, collisioni e casi non correggibili lasciati intatti. Nessuna sovrascrittura; figli prima dei genitori.
- Prima della rettifica il programma arresta e attende i worker. Copie automatiche e cancellazioni speculari rimangono disattivate fino a nuova autorizzazione. Il monitor locale riconcilia l'inventario senza svuotare la coda.
- Prova SMB corretta: verifica identità e contenuto dei file esclusivamente tecnici, anche quando un tentativo fallito modifica i metadati. Se il metodo rimane non disponibile o incerto, non ripete la prova per tutti i nuovi file della coppia nel ciclo. Nessun indebolimento delle verifiche sui file reali.
- Eliminato un controllo ridondante dell'identità della radice. Registro attività aggiornato separatamente ogni 3 secondi quando visibile; indicatori di file confermati, cartelle, operazioni rimandate ed errori; orario prossimo ciclo e voce laterale corretti.
- Conteggi sorgente e destinazione separati; destinazione riferita all'ultima verifica d'archivio. Ottimizzazione della scansione completa e revisione grafica generale rinviate.

## Validazione
CI 44525828208, tentativo 1, commit 0e4c72b4592a54596ba865af5fe61fb5b57bb41a: 221 test ordinari eseguiti senza errori (4 opt-in non eseguiti nella suite ordinaria), entrambi i benchmark grandi archivi superati, 4 test UI dedicati, 56 anteprime, pacchetto universale e laboratorio di aggiornamento Sparkle. I nuovi test comprendono metadati SMB simulati, alterazione dei file di prova, rettifica annidata e conflitti, lettura del registro durante scritture.

Versione di collaudo, non certificata stabile per produzione. La risoluzione del POSIX 45 e le prestazioni effettive richiedono verifica sul Mac collegato al server reale. Prima di riprendere la sincronizzazione, lasciare disattivate le cancellazioni speculari. Provare prima le copie; eseguire le rettifiche su un insieme di prova limitato e verificare il risultato prima di selezionare tutto. Conservare i log localmente.

Rollback sorgente: rollback-before-v0.18.4. Nessun log diagnostico reale incluso.
