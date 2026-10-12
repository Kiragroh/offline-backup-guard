# Changelog

## 0.3.0 - 2026-10-12

- Native Windows application and standalone per-user installer, with a dedicated
  multi-resolution icon, desktop/Start-menu shortcuts and selectable login startup.
- Close-to-tray, explicit exit and per-user single-instance focus; background status
  refresh leaves unsaved configuration edits untouched and never mounts storage.
- Verified versioned installation, interrupted-install recovery, integration
  ownership checks, downgrade protection and persistent launcher diagnostics.
- Uninstall removes desktop integration but retains versioned runners, scheduled
  tasks, private configuration and backup data.
- Isolated native installation/lifecycle tests, GUI smoke views and a read-only
  installation verifier. Artifacts are unsigned; local application policy applies.

## 0.2.0 - 2026-10-12

- English native Windows setup wizard and read-only health dashboard.
- Explicit task registration, protected canary initialization and backed-up edits.
- Durable per-attempt journals, early failure reasons, failure streaks, missed and
  interrupted runs, scheduler drift, timestamped capacity and private log access.
- Per-source replacement-version counts (new default: one), independently retained
  deleted files, legacy-policy preservation and confirmation before reductions.
- Synthetic lifecycle/retention/status/setup tests and native GUI smoke checks.
- No change to the software-offline threat boundary; hardware, account and restore
  acceptance remain operator responsibilities.

## 0.1.0 - 2026-10-12

- Initial generic public reference implementation with a fresh history.
- Editable sources, pinned canaries, exact USB identity, incremental Robocopy and quarantine.
- Daily offline-readable reports and remaining-space history.
- Synthetic tests, safe example configuration and operational/BCM guidance.
- Generated README banner. No production configuration or institutional integration.
