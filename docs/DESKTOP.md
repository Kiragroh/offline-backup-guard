# Desktop setup and health

## Deployment boundary

The desktop is a local Windows Forms application using Windows PowerShell 5.1.
No browser, web listener, cloud service or continuously running agent is required.
The backup runner remains usable without the GUI. The GUI refuses normal closure
while one of its operations is active; closing an idle GUI does not cancel Windows
scheduled jobs. Never force-stop a runner without an offline recovery procedure.

Keep scripts, private configuration and canary pins in approved locations protected
against modification by untrusted users. Elevated scheduled tasks execute those
scripts: do not use an untrusted writable download or shared folder for deployment.
Signing, task rights, ACLs, encryption and credential policy remain administrative
responsibilities. A successful wizard is not a security certification.

## Setup sequence

1. Start `Start-BackupGuard.ps1` in an STA Windows PowerShell session. Select a new
   private configuration path, or load an existing PSD1/CSV setup.
2. Select a dedicated USB disk by serial and reviewed label. No disk is formatted.
   A system/boot disk is never a supported destination.
3. Add enabled source folders and unique destination aliases. Review mirroring,
   canary pins, deletion limits, previous versions and deleted-file retention.
4. Choose a daily time within the start window and the approved Windows account.
   Interactive mode needs that user signed in; Password mode uses Windows Task
   Scheduler credentials for unattended execution. No password goes into a file.
5. Review and save. New host canaries require explicit initialization; missing or
   changed existing canaries are not automatically repaired or relearned. Existing
   configuration files get timestamped backups before replacement.
6. Run read-only preflight. A passed preflight is not a backup or a restore test.
7. Explicitly test using disposable source data and a dedicated test disk. This
   operation can mirror/delete destination files and expire recovery versions.
8. Register the task only after reviewing account, time and paths. UAC/elevation is
   requested only by an explicit action. Replacing an existing task needs consent.
   Registration does not automatically start a job.
9. Confirm a real run in the scheduled identity and perform a separate restore
   drill. Record what was restored, hashes/application validation and operator.
   A recorded operator statement is not verification performed by this software.

Configuration saving is serialized with backup execution. Do not hand-edit files
during a run. Reducing retention requires confirmation and affects later cleanup;
it never triggers disk mounting or pruning from the GUI itself.

## Reading health

| Signal | Interpretation |
| --- | --- |
| Succeeded | Runner completed and confirmed disk offline at that time, not a restore guarantee |
| Warning | Copy completed with skipped locks, low free space or deferred retention; review details |
| Failed | Recorded error; the source/stage and message explain where it failed |
| Interrupted | An unfinished record has no matching PID and process-start time; offline state is unconfirmed |
| Missed | No start for the expected daily run after a two-hour grace period |
| Needs attention | Task drift, an unmatched scheduler failure or an overlong runner needs investigation |
| Unknown | Unreadable configuration/history prevents a reliable assessment |

The failure streak counts recorded failed/interrupted attempts since the last
completed successful backup. Missed executions are inferred separately, not
invented as run records. Manual validation never resets that streak. The history
view reads up to the latest 2,000 records; older files remain on disk. Monitoring
happens while the GUI is open; this version does not send alerts while it is closed.

Task comparison covers the runner/config paths, account/logon mode, daily trigger,
elevation, enabled state, overlap protection, missed-start behavior and forced
timeout. It cannot prove source access under a different identity. A Windows job
that cannot start PowerShell cannot write a runner log; inspect the scheduler
result and Task Scheduler Operational history for credentials or policy errors.

## Logs and reports

`<configuration-basename>-diagnostics/` beside the PSD1 contains:

- `runs/<run-id>.json`: one persistent record per attempt, with source results.
- `<run-id>.events.jsonl`: structured time, severity, phase, source and reason.
- `<run-id>.log`: readable runner events.
- `active.json`: latest active snapshot; process identity is checked before calling
  it alive. This file alone is not a heartbeat or proof of liveness.

The configured `LogRoot` contains the full Robocopy output, linked from each run.
`ReportRoot` contains the latest/day JSON and Markdown reports plus daily storage
history. A failure before configuration validation stays in the bootstrap journal
instead of overwriting a report at an untrusted path.

These files may contain private filenames and error details. Do not upload them
unreviewed to public issues. They are not automatically deleted; apply an approved
diagnostic archival policy and watch the system volume as well as the backup disk.
GUI operation output is private temporary data and may also include filenames.

## Capacity and version budget

Capacity is measured during a backup while the disk is already mounted. Storage
history takes at most one real sample per day, up to 366 days. The GUI marks a
sample older than 36 hours stale instead of pretending it was refreshed. Used
space refers to the whole volume, including any content outside this toolkit.

The optional source-size scan is a point-in-time estimate and can be slow on large
shares. It skips reparse points and reports access errors/incompleteness. It does
not account exactly for changing files, filesystem allocation, compression, deleted
files or historical versions. Budget for the current data, retained versions,
deleted-file recovery and working headroom. Low capacity (less than 10 percent
free) is a warning, not permission to delete recovery data to force success.

## Validation boundary

Automated checks use synthetic files, mocked disk lifecycle and GUI construction.
They do not mount a real disk, install a task, submit credentials or prove recovery
on your hardware. Initial installation and account-specific acceptance require a
supervised test and restore drill. Software-offline remains weaker than a physically
disconnected or independently immutable backup.
