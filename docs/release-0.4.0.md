# Offline Backup Guard 0.4.0

Windows desktop and tray app with a new **Deferred files** view.

- Individual unavailable files retry next run, with a visible pending count.
- Reasons, first/last occurrence and affected-run counts remain readable offline.
- The default warning threshold is seven runs; adjust it in the Schedule view.
- Recovered entries clear automatically. Recovery-file pruning waits while a
  source has pending files.
- Native Windows diagnostics are retained. Canary, directory, corruption,
  disk-full and offline-transition failures still require intervention.

Download **Setup.exe** for the per-user Windows app. Existing backup settings,
tasks and data are not changed by desktop installation. After an app upgrade,
review the task action against the new installation and use the explicit task
installation workflow if it still references an older versioned runner.

**OfflineBackupGuard-0.4.0-portable.zip** contains the app and its adjacent files.
The source archive is for administrators/developers, not the desktop installer.
SHA-256 checksums are provided separately. Binaries are unsigned; follow local
approval policies and never bypass endpoint protection.

Validation used synthetic data under Windows PowerShell 5.1 and PowerShell 7:
copy/lock/recovery, seven-run ledger behavior, task/runner diagnostics, retention,
isolated installer lifecycle, and six-tab native GUI smoke tests. No production
configuration, host identity, source paths or operational records are included.

Software-offline is not a physical air gap. An unchanged canary is not proof that
other files are safe. Maintain an independent recovery copy and test restores.
