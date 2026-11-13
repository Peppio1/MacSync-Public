# MacSync

MacSync is a **work-in-progress** native macOS app for one-way mirroring of local folders to an existing SMB share on Windows Server 2016 through a VPN. No software may be installed on the server.

**Current state: early non-destructive prototype. No remote copies or deletions are enabled yet. Do not use on production photo archives.**

## Requirements
- macOS Sequoia, configurable local source folders Cartella_1 and Cartella_2.
- SMB destination contains corresponding subfolders under Condivisione_SMB.
- Unidirectional Mac-to-server copying, updates, renames and **deletions**.
- Approximately 5-minute unattended sync, without a full destination SMB scan every cycle.
- Durable SQLite queue/inventory, FSEvents monitoring, recovery after sleep/VPN outage.
- No paid commercial-use dependencies, no server-side agent.
- Preflight and mass-deletion protection.

## Design
Swift/SwiftUI MenuBarExtra, macOS FSEvents, SQLite, and eventually rclone SMB. Credentials must live in the local macOS Keychain and must never be committed.

The current initial package contains a menu-bar prototype, SQLite event queue, initial safety policy, unit tests and GitHub Actions build. **FSEvents monitoring, selective SMB sync, deletion propagation, Keychain integration and autostart are planned, not yet implemented.**

Run tests on a Mac with Swift 5.9+: swift test; build: swift build -c release. GitHub Actions also tests/builds on macOS.

See AGENTS.md and docs/ARCHITECTURE.md.

Do not commit real photographs, client data, server names/IPs, VPN data, passwords or live databases.