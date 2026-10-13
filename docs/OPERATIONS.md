# Operations and recovery

## First deployment

Use a disposable disk and synthetic files first. Confirm the exact serial number,
volume label and mount folder. The toolkit never formats disks. Keep configuration,
canaries, logs and reports on a protected local system volume, outside every source
tree and outside the backup disk. Prevent ordinary users from modifying the scripts,
configuration or trusted hashes. The backup account should read sources but have
write access only to the required destination and reporting locations.

Windows disk management needs elevation. Use an approved task identity with both
disk-management rights and source access, or implement a separately reviewed
privileged mount service plus unprivileged copy process. Never assume that SYSTEM
inherits a user's network-drive mappings. Use UNC paths, not mapped letters, for
network sources; enter credentials through approved Windows/enterprise tooling,
not in a PSD1, CSV or Git repository.

## Scheduling

Create a daily task in **Windows Task Scheduler** after successful manual acceptance:

- Program: your approved `powershell.exe` or `pwsh.exe`.
- Arguments: `-NoProfile -NonInteractive -File "C:\BackupGuard\src\Run-Backup.ps1" -ConfigPath "C:\BackupGuard\config\backup.psd1"`.
- Start in: your trusted installation directory.
- Trigger: once a night, for example 02:30, inside the configured start window.
- Identity: approved account with required source access and disk-management rights.
- Multiple instances: do not start another instance. A named mutex also prevents overlap.
- Use your approved script signing policy; no execution-policy bypass is needed or supplied.
- An interactive task requires the user to stay signed in. For unattended use, configure
  the appropriate Windows logon type and credentials explicitly with your IT owner.

The window limits **when a job may start**, not how long it can run. A hard Task
Scheduler timeout, power loss, forced process termination or OS crash can prevent
`finally` from running and leave the disk online. Monitor the offline result and
have an operator recovery procedure. This is a major limit of software offlining.
Do not force-stop a copy simply to meet a clock deadline.

The report is written at run completion; dashboards may read the saved JSON each
morning. There is only one storage-history measurement per day. Do not create a
second high-frequency job that brings the disk online merely to measure capacity.

## Canary failure

Do not update the reference hash to silence the failure. Preserve evidence and ask
the incident owner to review the source and host. No mount is attempted after a
failed global preflight. An unchanged canary does not certify any other file.

## Deferred files and failed sources

Sharing locks detected on changed source files are excluded only for that run,
including their corresponding target paths. Their older backup copy is retained.
The next run tries again. Recognized individual file-copy errors 2/3 (disappeared),
5 (file access denied), and 32/33 (sharing/locking) are recorded in the private
`StateRoot/deferred-files.json`. A mixed diagnostic set containing other errors,
directory/root failures, unknown diagnostics or fatal Robocopy codes stays fatal.
The raw Robocopy exit code remains in each source result.

Each unresolved file records first/last occurrence and consecutive affected runs.
An otherwise completed run stays green below `DeferredWarningAfterRuns` (default
7, permitted range 1-365). At the threshold, the run/status becomes yellow.
Retries within one run do not increment the count. Successful catch-up clears the
entry; a failed component does not clear unobserved pending entries. An unreadable
ledger blocks preflight and is never reported as an empty healthy list. A green
run with pending files is not a claim that every file has been updated.

A partial source failure does not prevent unrelated sources from being
attempted, but the overall run returns exit code 1. All canaries are rechecked per
source; a changing source can still be inconsistent without a snapshot or export.

## Retention and space

The current mirror and previous versions share the same disk and failure domain.
Changed destination files are copied into quarantine before replacement when
replacement versioning is enabled. New sources default to one previous version
in addition to the current mirror. CSV `PreviousVersions` can be 0 (off), 1 or a
higher count up to 1,000. A blank value keeps the legacy age-based `RetentionDays`
policy; it is not automatically changed to the new default.

Deleted destination files are retained separately when mirroring is enabled.
`DeletedRetentionDays` controls their lifetime (blank inherits `RetentionDays`).
Deletion archives do not consume replacement-version slots. Recent deletion
history protects older recovery copies of a now-absent file until that protection
expires; timestamp ties and uncertain metadata may retain additional copies.
There is no promise that total disk usage equals exactly N versions per file.

Retention cleanup runs only after a successful source pass without deferred
files. Reparse points other than the explicitly validated volume mount, unknown
timestamps, unindexed files and malformed manifests defer cleanup with a visible
warning. Do not modify quarantine/manifests manually. Reducing a policy can remove
previously retained files on a later successful run; the wizard requires consent.
Keep enough free capacity for old versions and incoming data. Disk-full errors
remain failures; the tool does not discard recovery copies to force success.

`MaxDeleteCount` is per source. A value of 0 disables that count limit. Start with a
positive limit and review unexpected mass changes; do not habitually raise limits
to hide unexplained deletions. Count guards and canaries cannot detect all attacks.

## Restore drill

1. Select representative **non-sensitive test data**, including one updated and one
   deleted file. Record a trusted SHA-256 before backup.
2. Run the job, confirm the report and disk offline state.
3. In a supervised recovery window, bring only the identified disk online using
   approved Windows disk-management tools. Do not launch a mirror during recovery.
4. Copy the selected current or quarantined files to a separate recovery folder.
   Do not overwrite the original source and do not delete quarantine.
5. Compare hashes; open the files in the intended application. For database exports,
   test a vendor-supported restore in an isolated environment.
6. Record elapsed time, responsible person, completeness, known exclusions and
   whether the recovery objectives were met. Offline/disconnect the disk afterward.

Regularly rotate a physically disconnected or independently immutable copy. Protect
recovery instructions and encryption recovery keys separately from the affected host.
