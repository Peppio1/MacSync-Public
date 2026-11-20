# MacSync v0.18.12

- La rettifica dei nomi sulla destinazione SMB usa il backend di rclone con una rinomina protetta eseguita dal server. Le collisioni lasciano le voci esistenti al loro posto.
- MacSync ricava server e condivisione dalla destinazione già selezionata. Cerca la voce SMB corrispondente nel Portachiavi e macOS può chiedere di autorizzarne l'accesso.
- Se la credenziale, l'identità della voce o l'esito della rinomina sono incerti, il lotto resta disponibile con **Riprendi rettifica**. La sincronizzazione ordinaria usa ancora il volume montato dal Finder.
- Questa build è destinata al collaudo. L'accesso alla voce del Portachiavi e la rettifica sulla configurazione SMB in uso vanno verificati sul Mac.
