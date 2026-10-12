function Invoke-GuardRetention { param($QuarantineRoot,$Source,$DestinationPath,$DefaultRetentionDays,$TrustedMountPath) [IO.File]::AppendAllText($env:GUARD_TEST_TRACE,"retention`n"); [pscustomobject]@{RemovedFiles=0;RemovedBytes=0;SkippedReason=$null} }
Export-ModuleMember -Function Invoke-GuardRetention
