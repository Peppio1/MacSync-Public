# MacSync v0.18.4 — candidato di collaudo

Rollback: rollback-before-v0.18.4. I file di diagnosi reali non sono inclusi nel repository.

## SMB e prestazioni
- Il test delle capacità usa file tecnici esclusivi di contenuto distinto e verificato. Dopo una collisione si controllano identità, tipo, lunghezza e contenuto esatto anziché richiedere timestamp invariati. I controlli dei file reali non vengono rilassati.
- È possibile provare l'hard link anche dopo un errore di rename esclusivo, purché i file di prova siano intatti e il nome libero sia ancora assente.
- Se la prova è incerta o non supportata, il risultato vale per la coppia nel ciclo corrente; nuovi file in attesa, nessun fallback sovrascrivente.
- Eliminato un controllo ridondante della radice destinazione già svolto da mapping.verify; conservati i controlli finali su volume, identità, alias e staging. La scansione archivio resta invariata.
- La reale compatibilità SMB e la velocità di trasferimento richiedono collaudo sul Mac e sul server. I test in CI sono locali, non riproducono il server fisico.

## Rettifica dei nomi
- Selezione singola, multipla, visibili o tutti i nomi rettificabili della sorgente e conferma con anteprima.
- Rimozione di spazi e punti finali; caratteri vietati sostituiti con un trattino. Nomi riservati, conflitti, duplicati, nomi tecnici e nomi ancora non validi lasciati intatti.
- Solo sorgenti locali già inventariate e vincolate all'identità precedente. Nessun accesso in scrittura alla destinazione. Rinomina esclusiva senza sovrascrittura; prima i figli, poi i genitori. Controlli su radice, percorso esatto, tipo, identità, metadati, collisioni e collegamenti simbolici.
- Prima della rettifica si fermano copia e monitor e si attende lo svuotamento dei worker; automatico e mirror rimangono disattivati fino a esplicita riattivazione. Il monitor riparte e riconcilia il nuovo inventario. La coda non viene svuotata.
- Conteggi sorgente e destinazione separati, badge riferito alla sorgente. Un nome già corrispondente nell'archivio può comunque essere incompatibile con future scritture. L'elenco destinazione resta storico fino alla prossima verifica.

## Interfaccia e log
- Registro attività con connessione SQLite in sola lettura indipendente dal worker, aggiornamento ogni 3 secondi mentre visibile.
- Avanzamento distinto da file confermati, cartelle create, rimandati ed errori. La velocità di staging non equivale a pubblicazione confermata.
- Niente orari futuri scaduti durante un ciclo manuale. Titolo laterale dei nomi a due righe se necessario.

## Validazione
CI obbligatoria, benchmark di riconoscimento e differenze, test sintetici di integrità dei probe e rettifica senza collisioni, anteprime UI, bundle universale e laboratorio di aggiornamento. Non dichiarare stabile la compatibilità SMB prima del test reale.
