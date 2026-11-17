# v0.18.0 — sviluppo per approvazione

Ramo develop-v0.18.0; rollback rollback-before-v0.18.0. Nessuna nuova release o firma produttiva prima dell'approvazione. Conservare DB, code, configurazione e storico; aggiunta tabella di metadati ciclo opzionale, senza cancellazioni/migrazioni distruttive. I cicli preesistenti non hanno modalità nota.

Riepilogo ultimo ciclo concluso, navigazione e dettagli per ciclo; somme non cumulative. Avanzamento unico, contatori separati, velocità dei byte SHA-256 realmente elaborati e velocità media dei trasferimenti completati; ETA stima per elementi, indisponibile prima del totale. Verifica rapida = file/s. Controlli salute in lettura quando la UI è aperta, anche periodici (30 s), su cambio configurazione e mount/wake; nessun remount, nessuna nuova autorizzazione o modifica alla copia. Log tecnico persistente dalla tabella attività con filtro/copia/esportazione. Errori di dominio e codice, senza serializzare userInfo. Registrazione login tramite SMAppService, nuovo tentativo e diagnostica, esito da verificare sul Mac reale.

Test aggiunti per contatori, byte realmente letti, isolamento cicli, modalità storiche, ETA e salute. Anteprime errori sorgente/destinazione nei due temi. Nessuna pubblicazione fino a verifica CI e approvazione utente. Compatibilità e avvio al login reali ancora da collaudare.
