@{
    ReadyForUse = $false
    SourceListPath = 'C:\BackupGuard\config\sources.csv'
    StateRoot = 'C:\BackupGuard\state'
    LogRoot = 'C:\BackupGuard\logs'
    ReportRoot = 'C:\BackupGuard\reports'
    WindowStart = '02:00'
    WindowEnd = '06:00'
    TaskName = 'OfflineBackupGuard-Nightly'
    ScheduleTime = '02:30'
    TaskUser = 'REPLACE_WITH_APPROVED_WINDOWS_ACCOUNT'
    TaskLogonType = 'Interactive'
    Canary = @{
        Path = 'C:\BackupGuard\canary.txt'
        ExpectedText = 'Backup integrity sentinel. Do not edit.'
        ExpectedSha256 = 'REPLACE_WITH_TRUSTED_SHA256'
    }
    BackupDisk = @{
        FriendlyName = 'REPLACE_WITH_EXACT_DEVICE_NAME'
        SerialNumber = 'REPLACE_WITH_EXACT_DEVICE_SERIAL'
        VolumeLabel = 'OFFLINE_BACKUP'
        PreferredAccessPath = 'C:\OfflineBackup'
    }
    RetentionDays = 30
    Threads = 8
}
