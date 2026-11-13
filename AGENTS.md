# AGENTS.md — MacSync instructions for Codex

## Objective
Deliver a reliable, unattended one-way iMac to Windows Server 2016 SMB/VPN mirror. Maintain source in public GitHub repo Videomakercd/MacSync-Public.

## Non-negotiable rules
1. No installation, agent or service on the Windows server. Only an existing SMB share.
2. No paid license requirement for commercial use.
3. One-way Mac -> server. Never mirror server changes into Mac.
4. Deletions and renames must propagate, but **never interpret inaccessible source, disconnected volume or broken VPN as deletions**.
5. Avoid recursively traversing the SMB destination every five minutes; use FSEvents, local SQLite inventory and persistent queue, with occasional audited full reconciliation.
6. Avoid committing credentials, private paths, images, database contents, logs with secrets or test production data.
7. Handle interrupted transfers, partial files and retries idempotently.
8. When in doubt, skip destructive operations and report an explicit error. Require recovery validation before resuming.
9. NEVER enable production remote deletion before thorough end-to-end tests and safe initial inventory reconciliation.

## Planned components
- SwiftUI menu bar GUI and settings.
- FSEvents watcher storing event IDs; dropped-event handling; local recovery scanning.
- SQLite WAL inventory, event journal, queues with transactionality and retry states.
- Selective rclone SMB file transfers and remote delete commands only for validated tracked paths.
- Source stability checks before copying Photoshop/large files; temporary target then final commit where possible.
- Network availability checks, Keychain secrets, login-item registration, 5-minute worker and actionable error notifications.
- Mass-delete circuit breaker, dry-run mode, bootstrap non-destructive alignment.

## User defaults
Names (not absolute paths): Cartella_1, Cartella_2; SMB parent Condivisione_SMB. Exact paths and credentials must be configured locally.

## Development phases
1. SwiftPM base, SQLite, models, safety tests, macOS CI.
2. FSEvents, durable event ID, recovery after shutdown and missed events.
3. Selective SMB copy with resumable retry, no remote full traverse each cycle.
4. Rename/delete propagation with safety gates and non-destructive bootstrap.
5. Keychain, native UI, login item, logs, notification and periodic audits.
6. Real-world test with macOS Sequoia + Windows Server 2016 VPN and representative large archive.

## Definition of done
Build success on GitHub macOS runners is NOT production validation. Test initial sync and steady state, VPN loss, source unavailable, sleep/restart, delete batches, active PSD files, and interrupted transfers before release.