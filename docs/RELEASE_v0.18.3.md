# MacSync v0.18.3 — Aggiornamento di collaudo

## Novità
- Sezione Nomi incompatibili: cartelle e file separati, ricerca, filtro per posizione, contatore, percorso e motivo; apertura Finder con selezione dell'elemento.
- Rinomina esclusivamente manuale. I percorsi non validi conservano la coda e non vengono trasferiti tramite metodi insicuri.
- L'elenco sorgente usa l'inventario locale; l'elenco destinazione si aggiorna dopo una verifica archivio.
- Diagnostica SMB migliorata: verifica delle capacità di pubblicazione esclusiva, registrazione degli errori delle singole operazioni. Se tali capacità non sono disponibili, i nuovi file restano in attesa; nessun fallback che sovrascriva un file indipendente.
- Scansione SMB e revisione grafica generale rinviate.

## Validazione
CI 44512329136, tentativo 2, commit 9f95d3664cb00cc8d769459bf3af81c4998d824c: 216 test ordinari eseguiti senza errori (4 test opt-in esclusi dalla suite ordinaria), benchmark 200.000 file per lato e 50.000 differenze, pacchetto universale, test Sparkle e recupero, 56 anteprime UI. Il primo tentativo è stato interrotto da un crash del processo Swift prima del benchmark, non da un'asserzione del programma.

Versione di collaudo, non dichiarata stabile per produzione. La compatibilità SMB reale richiede una verifica sul Mac con un server effettivo: non è ancora confermata la risoluzione del POSIX 45. Dopo l'aggiornamento, verificare un nuovo file e un aggiornamento con cancellazioni speculari disattivate. Conservare log e database localmente.

Rollback sorgente: rollback-before-v0.18.3. Nessun dato diagnostico reale incluso.
