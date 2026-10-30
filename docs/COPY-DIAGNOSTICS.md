# Copy diagnostics

The desktop app reads saved diagnostics while the backup disk is offline. Select
a run and source in **Copy details**. Pending retry candidates are also listed in
**Deferred files (count)**, with first/last occurrence and affected-run count.

## What the numbers mean

- **Copied:** files Robocopy reports copied in the actual copy stage, not a preview.
- **Unchanged / excluded:** Robocopy's skipped count; it includes explicit exclusions
  and does not mean every skipped file is identical or up to date.
- **Not updated / total:** failed copies plus individual files excluded during
  preflight. Copy-stage failures are counted once, not again from the retry ledger.
  The denominator is the files enumerated by this copy invocation, not all data
  anywhere on the source volume. Intentional exclusions are not missing files.
- **Extent unknown:** no complete supported summary, directory traversal failure,
  deletion/metadata error, fatal Robocopy result or unexplained failing exit.
  Zero enumerated files is shown separately, without an invented percentage.
- These are file counts, not a content-hash verification or a byte-weighted measure
  of clinical/business importance. A single important file can need attention.

For example, 1 of 1,000 files not updated is **0.1%**; 500 of 1,000 is **50%**.
If a directory cannot be enumerated, no percentage is claimed for the hidden files.

## Concrete error evidence

Local run JSON includes `sources[].measurement` and `sources[].copy_details`.
Diagnostics identify execution account, source/destination, stage, timestamp,
Robocopy exit code, native Windows error and operation. The embedded list is limited
to 256 native error lines of 4,096 characters each; truncation is explicitly marked.
The full Robocopy log remains linked from the run.

Windows error **5** means access denied, not proof of a sharing lock. **32/33**
identify sharing/lock violations. A directory operation can identify the failing
endpoint; a generic file-copy error may implicate either endpoint. The app states
that ambiguity instead of guessing which server or permission rule rejected it.
Reserved Windows filenames such as `nul` are recorded literally with a specific
reason; they are not opened as DOS devices or described as temporary locks.

Reports can contain private paths, usernames and filenames. Keep them local or
redact them before sharing a public issue. No diagnostic upload is built in.

## Health rules

| Health | Rule |
| --- | --- |
| Green | Completed job with offline confirmation; recognized individual deferrals can remain green before their configured threshold (default seven affected runs) |
| Yellow | Persistent deferrals, capacity/retention warnings, or measured file-copy failures affecting fewer than half the sources and fewer than half the enumerated files in each affected source |
| Red | At least 50% pending in any measured source, at least half the source jobs failed, unknown failure extent, canary/preflight/retention failure, disk-full/corruption/I/O failure, failure to offline, or global runner/report failure |

The assessment is separate from the raw `success`, `status` and process exit code.
An amber partial failure still has a failed raw job result and remains in the
failure history; a more reassuring color never fabricates successful recovery.
Scheduler drift, missed jobs, interrupted workers and unreadable diagnostics remain
independent signals. Historical records without measurements are not reclassified.

Recognized individual file errors (2, 3, 5, 32, 33) are deferred; other sources
continue. No rapid retry loop is added. A later successful source run removes
resolved entries. Version pruning is postponed for affected sources. Missing
source roots and unsafe preview results are never interpreted as permission to
mirror an empty source or bypass retention capture.

## Repeatable checks

`tests/Test-CopyDiagnostics.ps1` exercises 0.1% versus 50%, incomplete inventories,
English/German summaries, diagnostic privacy/bounds and health separation.
`tests/Test-DeferredFiles.ps1` exercises a real temporary sharing lock, next-run
catch-up, reserved names, path rejection and the seven-run ledger. All data is
synthetic; no real backup disk is mounted by these tests.
