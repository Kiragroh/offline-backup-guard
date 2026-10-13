# Diagnosing incomplete backups

Start in the desktop app: check the last attempt, last success, failure duration,
task state, recorded free space, and **Deferred files**. A fresh report is not a
new backup, and a historical offline observation is not the current disk state.

## Individual files versus failed jobs

Temporary files can disappear between scanning and copying. Applications can
hold individual files open or deny access. Recognized file-copy errors are listed
for retry next run, with a default seven-run warning threshold. Directory/root
errors and unrelated native errors are not downgraded. Unknown or mixed errors
remain failures. Do not change a canary pin to make a failed run look successful.

Robocopy exceptions include deduplicated native Windows error codes. Common cases
are 112 (disk full) and 1392 (corrupt file/directory). If a multithreaded preview
fails without a native diagnostic, a serial **list-only** diagnostic is attempted;
the original failure remains a failure even if that diagnostic succeeds. Inspect
private Robocopy logs for full paths; do not publish those logs without review.

## Suspected filesystem corruption

Stop scheduling new backup starts while investigating. Do not force-stop an active
copy or run a filesystem repair concurrently with it. Wait for the runner to
finish and inspect its final offline result. Identify the dedicated backup disk
by serial number and label, not by a remembered drive letter or disk number.

Preserve logs and independent recovery copies. Obtain explicit administrator
approval for a repair of that exact backup volume: a filesystem repair may remove
damaged entries. Never apply repair commands to an original source or assume that
a software-offline disk is physically isolated. This app does not automatically
run CHKDSK, format disks, disable endpoint protection or bypass Windows approval.

After approved repair, check the repair result, volume state, a real backup result,
and the final offline transition separately. A clean repair report or successful
file copy alone is not a restore test or proof of hardware health.

## Temporary-file exclusions

Prefer a narrowly reviewed pattern for a known application's disposable atomic
write intermediates, not a blanket exclusion of all temporary or database files.
Keep the final data file included. This release adds no organization-specific
application patterns or automatic exclusion guesses. Existing database exports,
snapshots and application-consistency requirements still apply.
