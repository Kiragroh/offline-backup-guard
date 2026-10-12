# Security policy and limits

This project is a supplemental file-copy control, not ransomware detection,
immutable storage, a physical air gap, database consistency, or a certified backup
service. It cannot protect an attached disk against a compromised administrator,
kernel, firmware, trusted configuration, or a canary-aware attacker. An offline
flag is reversible. Restore availability has to be verified independently.

No sensitive data belongs in issues, screenshots, logs, configuration examples or
pull requests. Use synthetic reproductions. Local Robocopy logs and manifests can
contain filenames and paths; protect them as operational data. Public reports must
be reviewed before sharing, because source aliases can also disclose information.

Use GitHub private vulnerability reporting where available. If it is unavailable,
open an issue asking for a private contact channel without exploit details or data.
Never post secrets or patient information to obtain support.

Only the current tagged release is reviewed for fixes. There is no response-time
or clinical availability guarantee. Sign/review scripts using your local policy;
do not bypass endpoint protection, relax execution policies, or expose a web-to-shell
launcher. Desktop installation and optional per-user login startup do not register
or start a backup task. Explicit desktop actions can request Windows elevation to
test a real backup or register a scheduled backup task.

Protect the installed scripts and configuration from untrusted modification before
registering a highest-privilege task. The wizard does not establish enterprise ACLs,
sign scripts, encrypt the disk or prove access under a different scheduled identity.
Its private temporary files and journals can contain paths and error messages.
Credentials go only through the Windows credential dialog and Task Scheduler, not
configuration, request files or diagnostics. Canary pins are never silently relearned.

Viewing status never mounts the disk. A recorded successful offline transition is
historical evidence, not a statement about the current physical connection. The GUI
is not an unattended alerting service. Closing its window leaves the tray client
running; explicitly exiting the tray or signing out stops that client, not the
independently scheduled backup. Review missed jobs and stale measurements, and
retain independently recoverable copies.

The desktop executable and installer are not code-signing or enterprise deployment
solutions. Inspect the release checksums and follow local application-control
policy. Installing per user does not make executable files or configuration safe
against compromise of that same user. Do not register privileged jobs against
untrusted writable scripts. An integrity manifest is not an independent signature.
