# Offline Backup Guard 0.5.0

**An additional offline protection layer, with a Windows setup wizard, desktop
shortcut, tray icon and clear backup diagnostics.**

## What's new

- **Copy details:** see actual copied/skipped files and the pending proportion,
  for example 1 of 1,000 (0.1%), instead of an unexplained folder-level error.
- Select a source to see execution identity, endpoints, operation and native
  Windows error evidence. Access denied is not automatically called a file lock.
- Small recognized file deferrals retry next run; the default warning threshold
  remains seven affected runs. Widespread failures and disk safety problems remain
  prominent. Raw outcomes are preserved separately from display severity.
- Reserved names such as `nul` no longer resolve to DOS devices when recording
  deferred files. Unsafe paths remain rejected.
- Selective warning colors, daily measured copy details, and clearer documentation
  of the protection workflow and recovery versions.

## Download and upgrade

Download **Setup.exe** for the normal per-user Windows app, or use
**OfflineBackupGuard-0.5.0-portable.zip** with its adjacent files intact. The source
ZIP is for developers. SHA-256 checksums are provided. Binaries are unsigned;
follow your organization's approval policy.

Close the previous tray app before installing. Desktop installation preserves
backup settings, tasks and data. Existing tasks can still point to an older
versioned runner: review the task action and use the wizard's explicit task
installation action to activate the new runner. Installation alone does not
silently replace a scheduled backup task.

Older run records are not rewritten. New measurements appear after a run with the
updated runner. All examples and screenshots are synthetic, with no institutional
configuration, network layout or operational logs included.

## Validation

The synthetic Windows test suite covers copy/retention, real temporary file locks
and catch-up, native diagnostics, measured percentages, persistent run/report
records, seven-run warnings, setup, isolated installer lifecycle and all seven GUI
tabs under Windows PowerShell 5.1 and PowerShell 7. No production disk or scheduled
backup is modified by these checks.

Taking the disk offline reduces exposure between backups. Administrators or
privileged malware can still bring an attached disk online; keep independent
recovery copies and test restores.
