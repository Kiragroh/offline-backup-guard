$ErrorActionPreference = "Stop"

function Test-BackupCanary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedText,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Canary missing at '$Path'. Refusing to mount backup disk."
    }

    $actualText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($actualText -ne $ExpectedText) {
        throw "Canary content mismatch at '$Path'. Refusing to mount backup disk."
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedSha256) {
        throw "Canary hash mismatch at '$Path'. Refusing to mount backup disk."
    }

    return $true
}

function Get-BackupSnapshotPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DestinationRoot,

        [Parameter(Mandatory = $true)]
        [string] $BackupName,

        [Parameter(Mandatory = $true)]
        [datetime] $Now
    )

    $snapshotName = $Now.ToString("yyyy-MM-dd_HHmmss")
    $root = $DestinationRoot.TrimEnd("\", "/")
    return "$root\$BackupName\$snapshotName"
}

function ConvertTo-BackupBoolean {
    param(
        [AllowNull()]
        [object] $Value,

        [bool] $Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    return @("1", "true", "yes", "y", "ja", "j") -contains $text.ToLowerInvariant()
}

function ConvertTo-BackupInt {
    param(
        [AllowNull()]
        [object] $Value,

        [int] $Default
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }

    return [int]$Value
}

function Get-SafeBackupFolderName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $chars = foreach ($char in $Name.ToCharArray()) {
        if ($invalidChars -contains $char) { "_" } else { $char }
    }
    $safe = (-join $chars).Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw "Backup source name cannot be converted to a folder name."
    }

    return $safe
}

function Import-BackupSourceList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Backup source list not found: $Path"
    }

    $lines = Get-Content -LiteralPath $Path |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith("#") }

    if ($lines.Count -eq 0) {
        throw "Backup source list is empty: $Path"
    }

    $rows = $lines | ConvertFrom-Csv -Delimiter ";"
    $sources = @()
    foreach ($row in $rows) {
        if (-not (ConvertTo-BackupBoolean -Value $row.Enabled -Default $true)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($row.Name)) {
            throw "Enabled backup source row is missing Name."
        }
        if ([string]::IsNullOrWhiteSpace($row.SourcePath)) {
            throw "Enabled backup source '$($row.Name)' is missing SourcePath."
        }

        $destinationSubfolder = $row.DestinationSubfolder
        if ([string]::IsNullOrWhiteSpace($destinationSubfolder)) {
            $destinationSubfolder = Get-SafeBackupFolderName -Name $row.Name
        }

        $canaryPath = $row.CanaryPath
        if ([string]::IsNullOrWhiteSpace($canaryPath)) {
            $canaryPath = Join-Path $row.SourcePath "BACKUP-CANARY.txt"
        }

        $sources += [pscustomobject]@{
            Enabled = $true
            Name = $row.Name
            SourcePath = $row.SourcePath
            DestinationSubfolder = $destinationSubfolder
            CanaryPath = $canaryPath
            CanarySha256 = ([string]$row.CanarySha256).Trim()
            CanaryRequired = ConvertTo-BackupBoolean -Value $row.CanaryRequired -Default (-not [string]::IsNullOrWhiteSpace([string]$row.CanarySha256))
            MirrorDeletes = ConvertTo-BackupBoolean -Value $row.MirrorDeletes -Default $true
            MaxDeleteCount = ConvertTo-BackupInt -Value $row.MaxDeleteCount -Default 0
            PreviousVersions = if ([string]::IsNullOrWhiteSpace([string]$row.PreviousVersions)) { $null } else { [int]$row.PreviousVersions }
            DeletedRetentionDays = if ([string]::IsNullOrWhiteSpace([string]$row.DeletedRetentionDays)) { $null } else { [int]$row.DeletedRetentionDays }
        }
    }

    return ,@($sources)
}

function Get-BackupMirrorPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DestinationRoot,

        [Parameter(Mandatory = $true)]
        [object] $Source
    )

    $root = $DestinationRoot.TrimEnd("\", "/")
    return "$root\Current\$($Source.DestinationSubfolder)"
}

function Test-BackupSourceCanary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Source
    )

    $canaryRequired = $true
    if ($Source.PSObject.Properties.Name -contains "CanaryRequired") {
        $canaryRequired = [bool]$Source.CanaryRequired
    }

    if ([string]::IsNullOrWhiteSpace($Source.CanaryPath)) {
        if (-not $canaryRequired) { return $false }
        throw "Source '$($Source.Name)' has no CanaryPath. Refusing to back it up."
    }
    if ([string]::IsNullOrWhiteSpace($Source.CanarySha256)) {
        if (-not $canaryRequired) { return $false }
        throw "Source '$($Source.Name)' has no CanarySha256. Refusing to back it up."
    }
    if (-not (Test-Path -LiteralPath $Source.CanaryPath -PathType Leaf)) {
        if (-not $canaryRequired) { return $false }
        throw "Source canary missing for '$($Source.Name)' at '$($Source.CanaryPath)'."
    }

    $actualHash = (Get-FileHash -LiteralPath $Source.CanaryPath -Algorithm SHA256).Hash
    if ($actualHash -ne $Source.CanarySha256) {
        throw "Source canary hash mismatch for '$($Source.Name)'. Refusing to mirror possible encrypted data."
    }

    return $true
}

function Get-RobocopyArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [Parameter(Mandatory = $true)]
        [string] $LogPath,

        [string[]] $ExtraArgs = @(),

        [switch] $MirrorDeletes
    )

    $forbidden = @("/MIR", "/PURGE")
    foreach ($arg in $ExtraArgs) {
        if ($forbidden -contains $arg.Trim().ToUpperInvariant()) {
            throw "Unsafe robocopy argument '$arg' is not allowed for ransomware-resistant snapshots."
        }
    }

    $modeArgs = if ($MirrorDeletes) { @("/MIR") } else { @("/E") }
    return @($SourcePath, $DestinationPath) + $modeArgs + $ExtraArgs + @("/LOG+:$LogPath")
}

function Get-RobocopyPreviewSummary {
    [CmdletBinding()]
    param(
        [string[]] $OutputLines
    )

    $changedLines = @($OutputLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $extraFiles = @($changedLines | Where-Object { $_ -like "*`*EXTRA*" })

    return [pscustomobject]@{
        ChangedLines = $changedLines.Count
        ExtraFiles = $extraFiles.Count
        OutputLines = $changedLines
    }
}

function Assert-RobocopyPreviewPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Source,

        [Parameter(Mandatory = $true)]
        [object] $Summary,

        [switch] $IgnoreMaxDeleteCount
    )

    $mirrorDeletes = $true
    if ($Source.PSObject.Properties.Name -contains "MirrorDeletes") {
        $mirrorDeletes = [bool]$Source.MirrorDeletes
    }

    if (-not $IgnoreMaxDeleteCount -and $mirrorDeletes -and $Source.MaxDeleteCount -gt 0 -and $Summary.ExtraFiles -gt $Source.MaxDeleteCount) {
        throw "Planned deletions exceed the configured source limit. Review the preview before changing the limit."
    }

    return $true
}

function Get-BackupQuarantineRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DestinationRoot
    )

    $root = $DestinationRoot.TrimEnd("\", "/")
    return "$root\Quarantine"
}

function Get-BackupQuarantineRunPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $QuarantineRoot,

        [Parameter(Mandatory = $true)]
        [object] $Source,

        [Parameter(Mandatory = $true)]
        [string] $RunId
    )

    $root = $QuarantineRoot.TrimEnd("\", "/")
    return "$root\$($Source.DestinationSubfolder)\$RunId"
}

function Get-BackupLastResortRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DestinationRoot
    )

    $root = $DestinationRoot.TrimEnd("\", "/")
    return "$root\LastResort"
}

function Get-BackupLastResortRunPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LastResortRoot,

        [Parameter(Mandatory = $true)]
        [object] $Source,

        [Parameter(Mandatory = $true)]
        [string] $RunId
    )

    $root = $LastResortRoot.TrimEnd("\", "/")
    return "$root\$($Source.DestinationSubfolder)\$RunId"
}

function Get-RelativeBackupPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RootPath,

        [Parameter(Mandatory = $true)]
        [string] $ChildPath
    )

    $root = [IO.Path]::GetFullPath($RootPath.TrimEnd("\", "/") + "\").TrimEnd("\", "/")
    $child = $ChildPath.Replace("/", "\").TrimEnd("\", "/")
    $rootPrefix = "$root\"

    if (-not $child.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$ChildPath' is not below root '$RootPath'."
    }

    $relativePath = $child.Substring($rootPrefix.Length)
    $relativeParts = @($relativePath -split "\\")
    if ($relativeParts.Count -eq 0 -or ($relativeParts | Where-Object { $_ -eq ".." }).Count -gt 0) {
        throw "Path '$ChildPath' cannot be converted to a safe relative backup path."
    }

    return $relativePath
}

function Test-BackupPathContainsReservedDeviceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath
    )

    $reservedNames = @(
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    )

    foreach ($part in @($RelativePath -split "[\\/]")) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }
        $normalizedPart = $part.TrimEnd(" ", ".")
        $deviceName = @($normalizedPart -split "\.")[0].ToUpperInvariant()
        if ($reservedNames -contains $deviceName) {
            return $true
        }
    }

    return $false
}

function Test-BackupFileWouldChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [IO.FileInfo] $SourceFile,

        [Parameter(Mandatory = $true)]
        [IO.FileInfo] $DestinationFile,

        [int] $TimeToleranceSeconds = 2
    )

    if ($SourceFile.Length -ne $DestinationFile.Length) {
        return $true
    }

    $delta = [math]::Abs(($SourceFile.LastWriteTimeUtc - $DestinationFile.LastWriteTimeUtc).TotalSeconds)
    return ($delta -gt $TimeToleranceSeconds)
}

function Test-BackupFileNameMatchesPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileName,

        [string[]] $Patterns = @()
    )

    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }
        if ($FileName -like $pattern) {
            return $true
        }
    }

    return $false
}

function Test-BackupRelativePathIsSafe {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $false
    }
    if ($RelativePath.IndexOf([char]0) -ge 0) {
        return $false
    }
    try {
        if ([IO.Path]::IsPathRooted($RelativePath)) {
            return $false
        }
    }
    catch {
        return $false
    }

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $parts = @($RelativePath -split "[\\/]+")
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }
        if ($part -eq "." -or $part -eq "..") {
            return $false
        }
        if ($part.IndexOfAny($invalidChars) -ge 0) {
            return $false
        }
    }

    return $true
}

function Get-BackupRelativePathFromRobocopyPreviewLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line,

        [Parameter(Mandatory = $true)]
        [string] $RootPath
    )

    if ($Line.IndexOf([char]0) -ge 0) {
        return ""
    }

    $lineText = $Line.Replace("/", "\")
    $root = [IO.Path]::GetFullPath($RootPath.TrimEnd("\", "/") + "\").TrimEnd("\", "/")
    $index = $lineText.IndexOf($root, [StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0) {
        $root = $RootPath.Replace("/", "\").TrimEnd("\", "/")
        $index = $lineText.IndexOf($root, [StringComparison]::OrdinalIgnoreCase)
    }
    if ($index -lt 0) {
        return ""
    }

    $fullPath = $lineText.Substring($index).Trim()
    if (-not $fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }

    $relativePath = $fullPath.Substring($root.Length).TrimStart("\", "/")
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return ""
    }

    $relativeParts = @($relativePath -split "\\")
    if (($relativeParts | Where-Object { $_ -eq ".." }).Count -gt 0) {
        return ""
    }
    if (-not (Test-BackupRelativePathIsSafe -RelativePath $relativePath)) {
        return ""
    }

    return $relativePath
}

function Save-BackupDestinationRelativePathToLastResort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [Parameter(Mandatory = $true)]
        [string] $LastResortRunPath,

        [Parameter(Mandatory = $true)]
        [string] $Reason,

        [string[]] $ExcludeNames = @()
    )

    if (-not (Test-BackupRelativePathIsSafe -RelativePath $RelativePath)) {
        return [pscustomobject]@{ Archived = $false; SkippedSpecialNames = $false; SkippedMalformedPaths = $true }
    }

    $fileName = Split-Path -Leaf $RelativePath
    if (Test-BackupFileNameMatchesPattern -FileName $fileName -Patterns $ExcludeNames) {
        return [pscustomobject]@{ Archived = $false; SkippedSpecialNames = $false; SkippedMalformedPaths = $false }
    }

    if (Test-BackupPathContainsReservedDeviceName -RelativePath $RelativePath) {
        New-Item -ItemType Directory -Path $LastResortRunPath -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $LastResortRunPath "lastresort-manifest.tsv") `
            -Value ("SkippedReservedDeviceName`t{0}`t{1}" -f $RelativePath, (Get-Date).ToUniversalTime().ToString("o")) `
            -Encoding UTF8
        return [pscustomobject]@{ Archived = $false; SkippedSpecialNames = $true; SkippedMalformedPaths = $false }
    }

    $destinationFilePath = Join-Path $DestinationPath $RelativePath
    if (-not (Test-Path -LiteralPath $destinationFilePath -PathType Leaf)) {
        return [pscustomobject]@{ Archived = $false; SkippedSpecialNames = $false; SkippedMalformedPaths = $false }
    }

    $destinationFile = Get-Item -LiteralPath $destinationFilePath -Force
    $archivePath = Join-Path $LastResortRunPath $RelativePath
    $archiveDirectory = Split-Path -Parent $archivePath
    New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
    Copy-Item -LiteralPath $destinationFile.FullName -Destination $archivePath -Force
    Add-Content -LiteralPath (Join-Path $LastResortRunPath "lastresort-manifest.tsv") `
        -Value ("{0}`t{1}`t{2}" -f $Reason, $RelativePath, $destinationFile.LastWriteTimeUtc.ToString("o")) `
        -Encoding UTF8

    return [pscustomobject]@{ Archived = $true; SkippedSpecialNames = $false; SkippedMalformedPaths = $false }
}

function Remove-BackupDestinationFilesByPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [string[]] $Patterns = @()
    )

    if (@($Patterns).Count -eq 0 -or -not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
        return [pscustomobject]@{ RemovedFiles = 0 }
    }

    $root = [IO.Path]::GetFullPath($DestinationPath.TrimEnd("\", "/") + "\").TrimEnd("\", "/")
    $rootPrefix = "$root\"
    $removed = 0
    $destinationFiles = Get-ChildItem -LiteralPath $DestinationPath -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($destinationFile in $destinationFiles) {
        if (-not (Test-BackupFileNameMatchesPattern -FileName $destinationFile.Name -Patterns $Patterns)) {
            continue
        }

        $fullName = $destinationFile.FullName.Replace("/", "\")
        if (-not $fullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove excluded file outside backup destination root: $($destinationFile.FullName)"
        }

        Remove-Item -LiteralPath $destinationFile.FullName -Force -ErrorAction Stop
        $removed++
    }

    return [pscustomobject]@{ RemovedFiles = $removed }
}

function Remove-BackupDestinationDirectoriesByPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [string[]] $Patterns = @()
    )

    if (@($Patterns).Count -eq 0 -or -not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
        return [pscustomobject]@{ RemovedDirectories = 0; FailedDirectories = 0 }
    }

    $root = [IO.Path]::GetFullPath($DestinationPath.TrimEnd("\", "/") + "\").TrimEnd("\", "/")
    $rootPrefix = "$root\"
    $removed = 0
    $failed = 0
    $destinationDirectories = Get-ChildItem -LiteralPath $DestinationPath -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-BackupFileNameMatchesPattern -FileName $_.Name -Patterns $Patterns } |
        Sort-Object { $_.FullName.Length } -Descending

    foreach ($destinationDirectory in $destinationDirectories) {
        $fullName = $destinationDirectory.FullName.Replace("/", "\")
        if (-not $fullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove excluded directory outside backup destination root: $($destinationDirectory.FullName)"
        }
        if (-not (Test-Path -LiteralPath $destinationDirectory.FullName -PathType Container)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $destinationDirectory.FullName -Recurse -Force -ErrorAction Stop
            $removed++
        }
        catch {
            $failed++
        }
    }

    return [pscustomobject]@{ RemovedDirectories = $removed; FailedDirectories = $failed }
}

function Save-LastResortMirrorChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [Parameter(Mandatory = $true)]
        [string] $LastResortRunPath,

        [string[]] $ExcludeNames = @(),

        [int] $TimeToleranceSeconds = 2,

        [object] $PreviewSummary = $null,

        [string] $LogPath = "",

        [string] $SourceName = "",

        [bool] $ArchiveReplacements = $true,

        [bool] $ArchiveDeletions = $true
    )

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
        return [pscustomobject]@{
            ArchivedFiles = 0
            DeletedFromSource = 0
            WillBeReplaced = 0
            SkippedSpecialNames = 0
            SkippedMalformedPaths = 0
            LastResortRunPath = $LastResortRunPath
        }
    }

    $archived = 0
    $deletedFromSource = 0
    $willBeReplaced = 0
    $skippedSpecialNames = 0
    $skippedMalformedPaths = 0

    $previewLines = @()
    if ($null -ne $PreviewSummary -and ($PreviewSummary.PSObject.Properties.Name -contains "OutputLines")) {
        $previewLines = @($PreviewSummary.OutputLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($previewLines.Count -gt 0) {
        $archivedRelativePaths = @{}
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $label = if ([string]::IsNullOrWhiteSpace($SourceName)) { $DestinationPath } else { $SourceName }
            Write-BackupAirLog -Path $LogPath -Message ("Quarantine scan for {0}: using {1} robocopy preview lines instead of full destination tree." -f $label, $previewLines.Count)
        }

        $processed = 0
        foreach ($line in $previewLines) {
            $processed++
            $normalizedLine = $line.Replace("/", "\")
            $isFileCandidate = ($line -like "*`*EXTRA Datei*" -or $line -like "*Neue Datei*" -or $line -match "^\s*Neuer\s")
            if ($line.IndexOf([char]0) -ge 0) {
                $skippedMalformedPaths++
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($LogPath) -and ($processed % 1000 -eq 0)) {
                $label = if ([string]::IsNullOrWhiteSpace($SourceName)) { $DestinationPath } else { $SourceName }
                Write-BackupAirLog -Path $LogPath -Message ("Quarantine progress for {0}: previewLines={1}/{2}, archived={3}, skippedSpecialNames={4}, skippedMalformedPaths={5}." -f $label, $processed, $previewLines.Count, $archived, $skippedSpecialNames, $skippedMalformedPaths)
            }

            $isExtraFile = ($line -like "*`*EXTRA*")
            if ($isExtraFile) {
                if (-not $ArchiveDeletions) { continue }
                $relativePath = Get-BackupRelativePathFromRobocopyPreviewLine -Line $line -RootPath $DestinationPath
                if ([string]::IsNullOrWhiteSpace($relativePath)) {
                    if ($isFileCandidate -and $normalizedLine.IndexOf($DestinationPath.Replace("/", "\"), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $skippedMalformedPaths++
                    }
                    continue
                }

                $key = $relativePath.ToLowerInvariant()
                if ($archivedRelativePaths.ContainsKey($key)) {
                    continue
                }

                $archiveResult = Save-BackupDestinationRelativePathToLastResort `
                    -RelativePath $relativePath `
                    -DestinationPath $DestinationPath `
                    -LastResortRunPath $LastResortRunPath `
                    -Reason "DeletedFromSource" `
                    -ExcludeNames $ExcludeNames

                if ($archiveResult.Archived) {
                    $archived++
                    $deletedFromSource++
                    $archivedRelativePaths[$key] = $true
                }
                elseif ($archiveResult.SkippedSpecialNames) {
                    $skippedSpecialNames++
                    $archivedRelativePaths[$key] = $true
                }
                elseif ($archiveResult.SkippedMalformedPaths) {
                    $skippedMalformedPaths++
                    $archivedRelativePaths[$key] = $true
                }
                continue
            }

            if (-not $ArchiveReplacements) { continue }
            $relativePath = Get-BackupRelativePathFromRobocopyPreviewLine -Line $line -RootPath $SourcePath
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                if ($isFileCandidate -and $normalizedLine.IndexOf($SourcePath.Replace("/", "\"), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $skippedMalformedPaths++
                }
                continue
            }

            $key = $relativePath.ToLowerInvariant()
            if ($archivedRelativePaths.ContainsKey($key)) {
                continue
            }

            if (Test-BackupPathContainsReservedDeviceName -RelativePath $relativePath) {
                $archiveResult = Save-BackupDestinationRelativePathToLastResort `
                    -RelativePath $relativePath `
                    -DestinationPath $DestinationPath `
                    -LastResortRunPath $LastResortRunPath `
                    -Reason "WillBeReplaced" `
                    -ExcludeNames $ExcludeNames
                if ($archiveResult.SkippedSpecialNames) {
                    $skippedSpecialNames++
                    $archivedRelativePaths[$key] = $true
                }
                elseif ($archiveResult.SkippedMalformedPaths) {
                    $skippedMalformedPaths++
                    $archivedRelativePaths[$key] = $true
                }
                continue
            }

            $destinationFilePath = Join-Path $DestinationPath $relativePath
            if (-not (Test-Path -LiteralPath $destinationFilePath -PathType Leaf)) {
                continue
            }

            $sourceFilePath = Join-Path $SourcePath $relativePath
            if (-not (Test-Path -LiteralPath $sourceFilePath -PathType Leaf)) {
                continue
            }

            $sourceFile = Get-Item -LiteralPath $sourceFilePath -Force
            $destinationFile = Get-Item -LiteralPath $destinationFilePath -Force
            if (-not (Test-BackupFileWouldChange -SourceFile $sourceFile -DestinationFile $destinationFile -TimeToleranceSeconds $TimeToleranceSeconds)) {
                continue
            }

            $archiveResult = Save-BackupDestinationRelativePathToLastResort `
                -RelativePath $relativePath `
                -DestinationPath $DestinationPath `
                -LastResortRunPath $LastResortRunPath `
                -Reason "WillBeReplaced" `
                -ExcludeNames $ExcludeNames

            if ($archiveResult.Archived) {
                $archived++
                $willBeReplaced++
                $archivedRelativePaths[$key] = $true
            }
            elseif ($archiveResult.SkippedSpecialNames) {
                $skippedSpecialNames++
                $archivedRelativePaths[$key] = $true
            }
            elseif ($archiveResult.SkippedMalformedPaths) {
                $skippedMalformedPaths++
                $archivedRelativePaths[$key] = $true
            }
        }

        return [pscustomobject]@{
            ArchivedFiles = $archived
            DeletedFromSource = $deletedFromSource
            WillBeReplaced = $willBeReplaced
            SkippedSpecialNames = $skippedSpecialNames
            SkippedMalformedPaths = $skippedMalformedPaths
            LastResortRunPath = $LastResortRunPath
        }
    }

    $destinationFiles = Get-ChildItem -LiteralPath $DestinationPath -Recurse -File -Force
    foreach ($destinationFile in $destinationFiles) {
        if (Test-BackupFileNameMatchesPattern -FileName $destinationFile.Name -Patterns $ExcludeNames) {
            continue
        }

        $relativePath = Get-RelativeBackupPath -RootPath $DestinationPath -ChildPath $destinationFile.FullName
        if (Test-BackupPathContainsReservedDeviceName -RelativePath $relativePath) {
            New-Item -ItemType Directory -Path $LastResortRunPath -Force | Out-Null
            Add-Content -LiteralPath (Join-Path $LastResortRunPath "lastresort-manifest.tsv") `
                -Value ("SkippedReservedDeviceName`t{0}`t{1}" -f $relativePath, $destinationFile.LastWriteTimeUtc.ToString("o")) `
                -Encoding UTF8
            $skippedSpecialNames++
            continue
        }

        $sourceFilePath = Join-Path $SourcePath $relativePath
        $shouldArchive = $false
        $reason = ""

        if (-not (Test-Path -LiteralPath $sourceFilePath -PathType Leaf)) {
            if (-not $ArchiveDeletions) { continue }
            $shouldArchive = $true
            $reason = "DeletedFromSource"
            $deletedFromSource++
        }
        else {
            if (-not $ArchiveReplacements) { continue }
            $sourceFile = Get-Item -LiteralPath $sourceFilePath -Force
            if (Test-BackupFileWouldChange -SourceFile $sourceFile -DestinationFile $destinationFile -TimeToleranceSeconds $TimeToleranceSeconds) {
                $shouldArchive = $true
                $reason = "WillBeReplaced"
                $willBeReplaced++
            }
        }

        if ($shouldArchive) {
            $archivePath = Join-Path $LastResortRunPath $relativePath
            $archiveDirectory = Split-Path -Parent $archivePath
            New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
            Copy-Item -LiteralPath $destinationFile.FullName -Destination $archivePath -Force
            Add-Content -LiteralPath (Join-Path $LastResortRunPath "lastresort-manifest.tsv") `
                -Value ("{0}`t{1}`t{2}" -f $reason, $relativePath, $destinationFile.LastWriteTimeUtc.ToString("o")) `
                -Encoding UTF8
            $archived++
        }
    }

    return [pscustomobject]@{
        ArchivedFiles = $archived
        DeletedFromSource = $deletedFromSource
        WillBeReplaced = $willBeReplaced
        SkippedSpecialNames = $skippedSpecialNames
        SkippedMalformedPaths = $skippedMalformedPaths
        LastResortRunPath = $LastResortRunPath
    }
}

function Remove-ExpiredLastResortRuns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LastResortRoot,

        [int] $RetentionDays = 30,

        [datetime] $Now = (Get-Date)
    )

    if (-not (Test-Path -LiteralPath $LastResortRoot -PathType Container)) {
        return [pscustomobject]@{ RemovedRuns = 0; RemovedFiles = 0 }
    }

    $cutoff = $Now.AddDays(-1 * $RetentionDays)
    $removed = 0
    $removedFiles = 0L
    $resolvedRoot = [System.IO.Path]::GetFullPath($LastResortRoot).TrimEnd('\') + '\'
    $sourceDirectories = Get-ChildItem -LiteralPath $LastResortRoot -Directory -Force
    foreach ($sourceDirectory in $sourceDirectories) {
        if ($sourceDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Retention source is a reparse point. Refusing recursive deletion.'
        }
        $runDirectories = Get-ChildItem -LiteralPath $sourceDirectory.FullName -Directory -Force
        foreach ($runDirectory in $runDirectories) {
            if ($runDirectory.LastWriteTime -lt $cutoff) {
                $resolvedRun = [System.IO.Path]::GetFullPath($runDirectory.FullName)
                if (-not $resolvedRun.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                    ($runDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    throw 'Retention target is outside the quarantine root or is a reparse point.'
                }
                $links = @(Get-ChildItem -LiteralPath $resolvedRun -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
                if ($links.Count) { throw 'Retention tree contains reparse points. Refusing recursive deletion.' }
                $fileCount = @(Get-ChildItem -LiteralPath $resolvedRun -File -Force -Recurse |
                    Where-Object { $_.Name -ne 'lastresort-manifest.tsv' }).Count
                Remove-Item -LiteralPath $runDirectory.FullName -Recurse -Force
                $removed++
                $removedFiles += $fileCount
            }
        }

        if (-not (Get-ChildItem -LiteralPath $sourceDirectory.FullName -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $sourceDirectory.FullName -Force
        }
    }

    return [pscustomobject]@{ RemovedRuns = $removed; RemovedFiles = $removedFiles }
}

function Test-RobocopyExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int] $ExitCode
    )

    return ($ExitCode -ge 0 -and $ExitCode -le 7)
}

function Import-BackupAirConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    return Import-PowerShellDataFile -LiteralPath $Path
}

function Get-BackupAirDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $DiskConfig
    )

    if ([string]::IsNullOrWhiteSpace($DiskConfig.SerialNumber) -or $DiskConfig.SerialNumber -like 'REPLACE*') {
        throw 'An exact, reviewed disk serial number is required.'
    }
    $candidates = @(Get-Disk | Where-Object {
        $friendlyMatches = $true
        $serialMatches = $true
        $sizeMatches = $true

        if ($DiskConfig.ContainsKey("FriendlyName") -and $DiskConfig.FriendlyName) {
            $friendlyMatches = ($_.FriendlyName -eq $DiskConfig.FriendlyName)
        }
        if ($DiskConfig.ContainsKey("SerialNumber") -and $DiskConfig.SerialNumber) {
            $serialMatches = ($_.SerialNumber.Trim() -eq $DiskConfig.SerialNumber.Trim())
        }
        if ($DiskConfig.ContainsKey("SizeGB") -and $DiskConfig.SizeGB) {
            $sizeGB = [math]::Round($_.Size / 1GB, 2)
            $sizeMatches = ([math]::Abs($sizeGB - [double]$DiskConfig.SizeGB) -lt 2)
        }

        $friendlyMatches -and $serialMatches -and $sizeMatches
    })

    if ($candidates.Count -eq 0) {
        throw "Backup disk not found. Expected '$($DiskConfig.FriendlyName)' serial '$($DiskConfig.SerialNumber)'."
    }
    if ($candidates.Count -gt 1) {
        throw "Multiple disks match the backup disk identity. Refusing to continue."
    }

    if ($candidates[0].IsBoot -or $candidates[0].IsSystem -or [string]$candidates[0].BusType -ne 'USB') {
        throw 'Only a dedicated, non-system USB disk is supported.'
    }
    return $candidates[0]
}

function Get-BackupAirDataPartition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [uint32] $DiskNumber
    )

    $partitions = @(Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.Size -gt 1GB })
    if ($partitions.Count -ne 1) { throw 'Expected exactly one data partition larger than 1 GiB.' }
    $partition = $partitions[0]

    if ($null -eq $partition) {
        throw "No data partition found on backup disk $DiskNumber."
    }

    return $partition
}

function Get-BackupAirPreferredAccessPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $DiskConfig
    )

    if ($DiskConfig.ContainsKey("PreferredAccessPath") -and -not [string]::IsNullOrWhiteSpace([string]$DiskConfig.PreferredAccessPath)) {
        $accessPath = [string]$DiskConfig.PreferredAccessPath
        if ($accessPath -notmatch "\\$") {
            $accessPath = "$accessPath\"
        }
        return $accessPath
    }

    $preferredDriveLetter = $DiskConfig.PreferredDriveLetter
    if (-not $preferredDriveLetter) {
        throw "Backup disk config must define PreferredDriveLetter or PreferredAccessPath."
    }

    return "$preferredDriveLetter`:\"
}

function Test-BackupAirAccessPathIsDriveLetter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $AccessPath
    )

    return ($AccessPath -match "^[A-Za-z]:\\$")
}

function Assert-BackupAirMountedAccessPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $AccessPath,

        [Parameter(Mandatory = $true)]
        [hashtable] $DiskConfig
    )

    if (-not (Test-Path -LiteralPath $AccessPath)) {
        throw "Backup access path $AccessPath is not available."
    }

    if ($DiskConfig.ContainsKey("VolumeLabel") -and $DiskConfig.VolumeLabel) {
        if (Test-BackupAirAccessPathIsDriveLetter -AccessPath $AccessPath) {
            $volume = Get-Volume -DriveLetter $AccessPath.Substring(0, 1)
        }
        else {
            $volume = Get-Volume -FilePath $AccessPath
        }

        if ($volume.FileSystemLabel -ne $DiskConfig.VolumeLabel) {
            throw "Mounted backup access path $AccessPath has label '$($volume.FileSystemLabel)', expected '$($DiskConfig.VolumeLabel)'."
        }
    }

    return $true
}

function Mount-BackupAirDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $DiskConfig
    )

    $disk = Get-BackupAirDisk -DiskConfig $DiskConfig
    if ($disk.IsOffline) {
        Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
        Start-Sleep -Seconds 2
        $disk = Get-Disk -Number $disk.Number
    }
    if ($disk.IsReadOnly) {
        throw 'Backup disk is read-only; investigate before allowing writes.'
    }

    $partition = Get-BackupAirDataPartition -DiskNumber $disk.Number
    $accessPath = Get-BackupAirPreferredAccessPath -DiskConfig $DiskConfig
    $useDriveLetter = Test-BackupAirAccessPathIsDriveLetter -AccessPath $accessPath

    if ($useDriveLetter) {
        $preferredDriveLetter = $accessPath.Substring(0, 1)
        $existing = Get-Partition -DriveLetter $preferredDriveLetter -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing.DiskNumber -ne $disk.Number) {
            throw "Drive letter $preferredDriveLetter is already used by disk $($existing.DiskNumber)."
        }

        if ($partition.DriveLetter -ne $preferredDriveLetter) {
            if ([string]::IsNullOrWhiteSpace($partition.DriveLetter)) {
                Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $accessPath -ErrorAction Stop
            }
            else {
                Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $preferredDriveLetter -ErrorAction Stop
                Start-Sleep -Seconds 2
            }
        }
    }
    else {
        $mountFolder = $accessPath.TrimEnd("\")
        New-Item -ItemType Directory -Path $mountFolder -Force | Out-Null
        $existingPaths = @((Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber).AccessPaths)
        if ($existingPaths -notcontains $accessPath) {
            $folderItems = @(Get-ChildItem -LiteralPath $mountFolder -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($folderItems.Count -gt 0) {
                throw "Mount folder $mountFolder is not empty. Refusing to hide local files with backup volume mount."
            }
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $accessPath -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
    }

    for ($i = 0; $i -lt 30; $i++) {
        try {
            Assert-BackupAirMountedAccessPath -AccessPath $accessPath -DiskConfig $DiskConfig | Out-Null
            return $accessPath
        }
        catch {
            if ($i -ge 29) {
                throw
            }
        }
        Start-Sleep -Seconds 1
    }

    throw "Backup access path $accessPath did not become available."
}

function Dismount-BackupAirDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $DiskConfig
    )

    $disk = Get-BackupAirDisk -DiskConfig $DiskConfig
    if (-not $disk.IsOffline) {
        Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop
    }
}

function Get-RobocopyLockOnlyCount {
    param([string[]] $OutputLines, [int] $ExitCode)
    if ($ExitCode -lt 8 -or $ExitCode -ge 16) { return 0 }
    $errors = @($OutputLines | Where-Object { $_ -match '(?i)\b(?:ERROR|FEHLER)\s+\d+\s+\(0x[0-9a-f]+\)' })
    if ($errors.Count -eq 0) { return 0 }
    $paths = @{}
    foreach ($line in $errors) {
        # Only file sharing/lock violations qualify; directory and other I/O errors remain fatal.
        if ($line -notmatch '(?i)\b(?:ERROR|FEHLER)\s+(?:32|33)\s+\(0x0000002[01]\)\s+(?:Copying File|Folgende Datei wird kopiert|Kopieren der Datei)\s+(.+)$') { return 0 }
        $paths[$Matches[1].Trim()] = $true
    }
    return $paths.Count
}

function Invoke-RobocopyChecked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        [object] $PreviewSummary = $null,
        [switch] $PassThruResult
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $excluded = @()
    if ($null -ne $PreviewSummary -and $PreviewSummary.PSObject.Properties.Name -contains 'LockedPaths') {
        $excluded = @($PreviewSummary.LockedPaths)
        if ($excluded.Count) { $Arguments = $Arguments + @('/XF') + $excluded }
    }
    # Stream verbose output rather than retaining a potentially multi-million-file listing.
    & robocopy.exe @Arguments /R:0 /W:0 /TEE | ForEach-Object {
        if ($_ -match '(?i)\b(?:ERROR|FEHLER)\s+\d+\s+\(0x[0-9a-f]+\)') { $errors.Add([string]$_) }
    }
    $exitCode = $LASTEXITCODE
    $actualExitCode = $exitCode
    $locked = 0
    if (-not (Test-RobocopyExitCode -ExitCode $exitCode)) {
        $locked = Get-RobocopyLockOnlyCount -OutputLines $errors.ToArray() -ExitCode $exitCode
        if ($locked -eq 0) { throw "Robocopy failed with exit code $exitCode." }
        $exitCode = $exitCode -band 7
    }
    $lockedAtCopy = $locked
    $lockedAtPreflight = [int]($excluded.Count / 2)
    $locked += $lockedAtPreflight
    $logArg = @($Arguments | Where-Object { $_ -match '^/LOG\+?:' } | Select-Object -Last 1)
    if ($locked -gt 0 -and $logArg.Count) {
        Write-BackupAirLog -Path ($logArg[0] -replace '^/LOG\+?:', '') -Message "WARNING: Robocopy locked files skipped: count=$locked; retry=next-run."
    }

    if ($PassThruResult) {
        return [pscustomobject]@{ ExitCode=$actualExitCode; NormalizedExitCode=$exitCode; LockedAtCopy=$lockedAtCopy; LockedAtPreflight=$lockedAtPreflight }
    }
    return $exitCode
}

function Invoke-RobocopyPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,

        [Parameter(Mandatory = $true)]
        [string] $LogPath,

        [switch] $SuppressDetailedOutput
    )

    $previewArgs = @($Arguments | Where-Object {
        $_ -notlike "/LOG:*" -and
        $_ -notlike "/LOG+:*" -and
        $_.Trim().ToUpperInvariant() -ne "/NFL"
    }) +
        @("/L", "/NDL", "/NJH", "/NJS", "/NP", "/BYTES")

    $output = @(& robocopy.exe @previewArgs /R:0 /W:0)
    $exitCode = $LASTEXITCODE

    Add-Content -LiteralPath $LogPath -Value "----- ROBOCOPY PREVIEW START -----" -Encoding UTF8
    if ($output.Count -gt 0 -and -not $SuppressDetailedOutput) {
        Add-Content -LiteralPath $LogPath -Value $output -Encoding UTF8
    }
    elseif ($SuppressDetailedOutput) {
        $summary = Get-RobocopyPreviewSummary -OutputLines $output
        Add-Content -LiteralPath $LogPath -Value ("Robocopy preview details suppressed; changedLines={0}; extraFiles={1}." -f $summary.ChangedLines, $summary.ExtraFiles) -Encoding UTF8
    }
    Add-Content -LiteralPath $LogPath -Value "Robocopy preview exit code: $exitCode" -Encoding UTF8
    Add-Content -LiteralPath $LogPath -Value "----- ROBOCOPY PREVIEW END -----" -Encoding UTF8

    if (-not (Test-RobocopyExitCode -ExitCode $exitCode)) {
        $locked = Get-RobocopyLockOnlyCount -OutputLines $output -ExitCode $exitCode
        if ($locked -eq 0) { throw "Robocopy preview failed with exit code $exitCode." }
        Write-BackupAirLog -Path $LogPath -Message "WARNING: Robocopy preview contains $locked locked files; unlocked files will continue."
    }

    $lockedPaths = [System.Collections.Generic.List[string]]::new()
    $checkedPaths = @{}
    $usable = foreach ($line in $output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $relative = Get-BackupRelativePathFromRobocopyPreviewLine -Line $line -RootPath $Arguments[0]
        if ($relative -and -not (Test-BackupPathContainsReservedDeviceName -RelativePath $relative)) {
            $path = Join-Path $Arguments[0] $relative
            if (-not $checkedPaths.ContainsKey($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $checkedPaths[$path] = $true
                try {
                    $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                    $reader.Dispose()
                }
                catch {
                    $exception = $_.Exception
                    while ($exception.InnerException) { $exception = $exception.InnerException }
                    if (($exception.HResult -band 65535) -notin @(32, 33)) { throw }
                    $lockedPaths.Add($path)
                    $lockedPaths.Add((Join-Path $Arguments[1] $relative))
                }
            }
            if ($lockedPaths.Contains($path)) { continue }
        }
        $line
    }
    $summary = Get-RobocopyPreviewSummary -OutputLines @($usable)
    $summary | Add-Member -NotePropertyName LockedPaths -NotePropertyValue $lockedPaths.ToArray()
    return $summary
}

function Write-BackupAirLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $line = "{0} {1}" -f (Get-Date).ToString("s"), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function ConvertTo-BackupStringArray {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value)
    }

    $items = @()
    foreach ($item in @($Value)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
            $items += [string]$item
        }
    }
    return ,@($items)
}

Export-ModuleMember -Function 'Test-BackupCanary', 'Get-BackupSnapshotPath', 'ConvertTo-BackupBoolean', 'ConvertTo-BackupInt', 'Get-SafeBackupFolderName', 'Import-BackupSourceList', 'Get-BackupMirrorPath', 'Test-BackupSourceCanary', 'Get-RobocopyArguments', 'Get-RobocopyPreviewSummary', 'Assert-RobocopyPreviewPolicy', 'Get-BackupQuarantineRoot', 'Get-BackupQuarantineRunPath', 'Get-BackupLastResortRoot', 'Get-BackupLastResortRunPath', 'Get-RelativeBackupPath', 'Test-BackupPathContainsReservedDeviceName', 'Test-BackupFileWouldChange', 'Test-BackupFileNameMatchesPattern', 'Test-BackupRelativePathIsSafe', 'Get-BackupRelativePathFromRobocopyPreviewLine', 'Save-BackupDestinationRelativePathToLastResort', 'Remove-BackupDestinationFilesByPattern', 'Remove-BackupDestinationDirectoriesByPattern', 'Save-LastResortMirrorChanges', 'Remove-ExpiredLastResortRuns', 'Test-RobocopyExitCode', 'Import-BackupAirConfig', 'Get-BackupAirDisk', 'Get-BackupAirDataPartition', 'Get-BackupAirPreferredAccessPath', 'Test-BackupAirAccessPathIsDriveLetter', 'Assert-BackupAirMountedAccessPath', 'Mount-BackupAirDisk', 'Dismount-BackupAirDisk', 'Get-RobocopyLockOnlyCount', 'Invoke-RobocopyChecked', 'Invoke-RobocopyPreview', 'Write-BackupAirLog', 'ConvertTo-BackupStringArray'
