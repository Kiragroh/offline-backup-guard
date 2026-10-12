# Desktop Application Contract

The tray is a presentation and configuration client, not another backup runner.
Closing the window hides it; explicit Exit terminates the client. Windows logoff
must not be blocked by close-to-tray behavior. A repeated launch focuses the
existing instance for that user and product. Other users and products are separate.

Installation creates a native Windows entry point and shortcuts, not a scheduled
backup. Login startup is optional. Configuration remains in its private location
outside application versions and survives application upgrades and uninstall.
The installer must not replace edited private configuration with examples.

## Read-only Monitoring

Background refresh reads existing diagnostics and scheduler metadata. It never
enumerates source contents, mounts storage, starts a runner or overwrites unsaved
editor values. Capacity retains the original measurement time. A stale or
unreadable observation is not a new measurement and must not produce green health.

## Configuration

The existing setup validation remains authoritative. Saving configuration does
not register a task; applying the schedule is explicit. Running preflight does not
prove successful backup or restore. A manual backup remains a separately confirmed
operation. Closing or exiting the desktop must not force-kill an owned backup.

## Acceptance Evidence

Use synthetic settings, reports and temporary installations for lifecycle tests.
Check duplicate launch, close-to-tray, exit, startup arguments, shortcut targets,
malformed package rejection and preservation of settings. Inspect rendered GUI
views separately from parser tests. Keep build hashes, source version and compiler
identification with release artifacts. Never include operational logs, settings,
source identities or real desktop screenshots in public packages.

Unit and fixture tests do not establish hardware, scheduled-account, ransomware
detection or recovery acceptance. Those remain separate supervised checks.
