# Contributing

Use fictional sources, disk serials and hostnames. Never submit production PSD1/CSV
files, logs, reports, screenshots, device inventories, credentials or personal data.
The ignore rules are an additional precaution, not a privacy guarantee.

Run the PowerShell tests before a pull request. New destructive behavior must have
mocked safety tests and a documented, supervised acceptance procedure. CI must not
mount or offline real disks. Keep Windows PowerShell 5.1 compatibility and treat
unknown parser output or I/O errors conservatively.

Use small changes. Explain the failure mode, safeguards and remaining limitations.
