# Setup and health implementation plan

Approved scope: an English native Windows setup wizard and read-only status view,
durable diagnostics for missed/failed/interrupted runs, and per-source versions.
Production installations outside this public repository are out of scope.

## Architecture

- `Start-BackupGuard.ps1`: Windows Forms wizard and dashboard; no web server.
- `src/Setup.psm1` and `src/Configure-Task.ps1`: validated configuration persistence,
  explicit canary initialization, task creation via Windows credentials/UAC.
- `src/Operations.psm1`: append-only run events, active run identity, history and
  scheduler inspection; the dashboard never mounts or queries the backup volume.
- `src/Versioning.psm1`: per-file previous version limits and deleted-file retention.
- `src/Run-Backup.ps1`: instrument preflight through final offline result; integrate
  version policy without masking copy errors or cleaning up after a failed source.

## Contracts

`Get-GuardStatus -ConfigPath <path>` returns `State`, `LastAttempt`, `LastSuccess`,
`NextRun`, `ConsecutiveFailures`, `ProblemSince`, `Problem`, `TaskState`, `Drift`,
`Storage`, `History`, `Active`, `ReportRoot`, `LogRoot`. Storage contains the original
`measured_at`, `capacity_bytes`, `used_bytes`, `free_bytes`, plus `stale`.
History entries include `id`, `started_at`, `finished_at`, `status`, `phase`,
`error`, `log_path`, `event_path`, `sources`. No missing run is fabricated as a run.

New settings: `TaskName`, `ScheduleTime` (HH:mm), `TaskUser`, `TaskLogonType`
(`Interactive` or `Password`). Saved task action points to the installed runner
with the absolute config path, IgnoreNew and highest privileges. No passwords
are stored in project/config/log files. No automatic task start at registration.

New CSV fields: `PreviousVersions` (blank=legacy, 0=off, >=1=count) and
`DeletedRetentionDays` (blank=global RetentionDays). New wizard sources default
to one previous version and 30 days for deleted files. A disabled version policy
does not disable deleted-file retention. Changes require confirmation; cleanup
occurs only after a successful copy, with path/reparse-point guards.

## Work and verification

- [x] Add version policy and synthetic tests for 0/1/N, legacy, deleted expiry,
  and deletion safety. Never exercise real disk operations in automated tests.
- [x] Add run journal and status tests for preflight failure, warning, missed run,
  interruption, configuration drift, failure streak and stale daily storage.
- [x] Add wizard (disk, source grid, schedule, review) and dashboard. Keep slow
  validation/test operations out of the UI thread. Add GUI construction smoke
  tests; do not install a real task or mount a real disk during tests.
- [x] Integrate runner and reporting. Run all tests on PowerShell 5.1 and 7.
- [ ] Review privacy and safety, document behavior, update release notes, commit,
  publish and verify GitHub Actions. Record hardware/UI acceptance boundaries.

## Safety and release criteria

No source folders, task names, real hardware identities, credentials, reports or
screenshots from an operational environment may enter Git. Early malformed-config
failures go to a sibling diagnostics directory, without trusting arbitrary config
log paths. Reports distinguish last confirmed offline state from current state.
The GUI must not imply a successful copy proves recoverability or ransomware absence.
Task credential/access validation must run in the actual scheduled identity before
claiming unattended readiness. The user explicitly starts hardware tests.
