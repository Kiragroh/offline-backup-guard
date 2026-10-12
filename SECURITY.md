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
launcher. The repository does not install services or request elevation itself.
