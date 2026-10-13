#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Tray,
    [string]$DesktopEventName,
    [switch]$SmokeTest,
    [string]$ScreenshotPath,
    [ValidateSet('Load','Save','Disks','Status','Preflight','Test','Estimate','Restore')][string]$WorkerOperation,
    [string]$RequestPath,
    [string]$ResultPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\Setup.psm1') -Force

# Workers are separate PowerShell processes. No background runspace touches controls.
if ($WorkerOperation) {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $result = @{ Success = $false; Data = $null; Message = ''; Output = '' }
    $exitCode = 1
    $resultStream = $null
    try {
        $resultParent = Split-Path ([IO.Path]::GetFullPath($ResultPath)) -Parent
        if ((Split-Path $resultParent -Leaf) -notmatch '^backup-guard-ui-[a-f0-9]{32}$' -or
            (Split-Path $ResultPath -Leaf) -notmatch '^result-[a-f0-9]{32}\.clixml$' -or
            (Split-Path ([IO.Path]::GetFullPath($RequestPath)) -Parent) -ne $resultParent) { throw 'Worker requires matching private GUI session request and result paths.' }
        Assert-GuardNoReparseAncestor $ResultPath
        Assert-GuardNoReparseAncestor $RequestPath
        $resultStream = [IO.File]::Open($ResultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        switch ($WorkerOperation) {
            'Load' { $result.Data = Read-GuardSetupConfiguration $request.ConfigPath }
            'Save' {
                $cfg = ConvertTo-GuardHashtable $request.Config
                $result.Data = Save-GuardSetupConfiguration -ConfigPath $request.ConfigPath -Config $cfg -Sources @($request.Sources) -InitializeCanary:$request.InitializeCanary -ConfirmRetentionReduction:$request.ConfirmRetentionReduction
            }
            'Disks' {
                $result.Data = @(Get-Disk -ErrorAction Stop | Where-Object { [string]$_.BusType -eq 'USB' } | ForEach-Object {
                    [pscustomobject]@{ Number=$_.Number; FriendlyName=$_.FriendlyName; SerialNumber=([string]$_.SerialNumber).Trim(); SizeGB=[math]::Round($_.Size/1GB,2); IsBoot=$_.IsBoot; IsSystem=$_.IsSystem; IsOffline=$_.IsOffline }
                })
            }
            'Status' {
                Import-Module (Join-Path $PSScriptRoot 'src\Operations.psm1') -Force
                $status = Get-GuardStatus -ConfigPath $request.ConfigPath
                $restore = Get-ChildItem -LiteralPath $status.LogRoot -Filter 'restore-drill-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
                $record = if ($restore) { Get-Content -LiteralPath $restore.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
                $result.Data = [pscustomobject]@{ Status=$status; Restore=$record }
            }
            { $_ -in @('Preflight','Test') } {
                $program = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'src\Run-Backup.ps1'),'-ConfigPath',$request.ConfigPath)
                if ($WorkerOperation -eq 'Preflight') { $arguments += '-ValidateOnly' } else { $arguments += '-AllowManualRun' }
                $ErrorActionPreference = 'Continue'
                $result.Output = (& $program @arguments 2>&1 | Out-String)
                $runnerExit = $LASTEXITCODE
                $ErrorActionPreference = 'Stop'
                $result.Data = [pscustomobject]@{ ExitCode=$runnerExit; Output=$result.Output }
                if ($runnerExit -ne 0) { throw "Runner returned exit code $runnerExit. Review captured output and diagnostics. Disk preflight may require approved administrative rights; no policy bypass is attempted." }
            }
            'Estimate' { $result.Data = @(Measure-GuardSetupSources -Sources @($request.Sources)) }
            'Restore' { $result.Data = Save-GuardRestoreRecord -ConfigPath $request.ConfigPath -Note $request.Note -ConfirmExternalRestore:$request.Confirmed }
        }
        $result.Success = $true; $exitCode = 0
    } catch { $result.Message = $_.Exception.Message }
    if ($resultStream) {
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($result))
            $resultStream.Write($bytes,0,$bytes.Length)
        } finally { $resultStream.Dispose() }
    } else { Write-Error $result.Message }
    exit $exitCode
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start with powershell.exe -NoProfile -STA -File Start-BackupGuard.ps1 (without an execution-policy bypass).' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'src\Desktop.psm1') -Force
[Windows.Forms.Application]::EnableVisualStyles()
$script:desktopSession=$null
if(-not $SmokeTest){
    $script:desktopSession=New-GuardDesktopSession -EventName $DesktopEventName
    if($script:desktopSession.FocusOnly){$script:desktopSession.Event.Dispose();exit 0}
}
if (-not $ConfigPath) { $ConfigPath = Join-Path $env:LOCALAPPDATA 'OfflineBackupGuard\config\backup.psd1' }
if ($SmokeTest) { $ConfigPath = 'C:\ExamplePrivate\backup.psd1' }
$script:config = New-GuardSetupConfiguration $ConfigPath
$script:previous = $null; $script:loadedPath = $null; $script:dirty = $true
$script:preflightPassed = $false; $script:busy = $null; $script:loading = $false; $script:sessionDirectory = $null
$script:diskRows = @(); $script:lastStatus = $null; $script:lastActivePoll=[datetime]::MinValue

$form = New-Object Windows.Forms.Form
$form.Text = 'Offline Backup Guard 0.4.0'
$form.ClientSize = New-Object Drawing.Size(1160,800)
$form.MinimumSize = New-Object Drawing.Size(1024,720)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI',9)
$form.BackColor = [Drawing.Color]::White
$form.Icon = [Drawing.SystemIcons]::Shield
$script:desktopIcons=@{}
foreach($name in @('app','unknown','success','running','warning','error')){
    $iconPath=Join-Path $PSScriptRoot ('assets\desktop\'+$name+'.ico')
    if(Test-Path -LiteralPath $iconPath){$script:desktopIcons[$name]=New-Object Drawing.Icon($iconPath)}
}
if($script:desktopIcons.app){$form.Icon=$script:desktopIcons.app}
$form.AutoScaleMode = 'Dpi'
$tooltips = New-Object Windows.Forms.ToolTip
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 4
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',38)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',40)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',34)))
$form.Controls.Add($layout)
$toolbar = New-Object Windows.Forms.ToolStrip
$toolbar.Dock = 'Fill'; $toolbar.GripStyle = 'Hidden'; $toolbar.BackColor = [Drawing.Color]::FromArgb(245,246,247)
$toolbar.ImageScalingSize = New-Object Drawing.Size(20,20)
$layout.Controls.Add($toolbar,0,0)
function Add-Tool([string]$Name, [Drawing.Icon]$Icon, [scriptblock]$Click) {
    $button = New-Object Windows.Forms.ToolStripButton
    $button.Image = $Icon.ToBitmap(); $button.DisplayStyle = 'Image'; $button.ToolTipText = $Name; $button.AccessibleName = $Name
    $button.Add_Click($Click); [void]$toolbar.Items.Add($button); return $button
}
function Show-Error([object]$ErrorValue) {
    Write-DesktopLog ([string]$ErrorValue)
    [void][Windows.Forms.MessageBox]::Show($form,[string]$ErrorValue,'Offline Backup Guard','OK','Error')
}
function Write-DesktopLog([string]$Message){
    if($SmokeTest){return}
    try{
        $directory=Join-Path $env:LOCALAPPDATA 'OfflineBackupGuard\desktop-logs'
        Assert-GuardNoReparseAncestor $directory
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::AppendAllText((Join-Path $directory ([datetime]::UtcNow.ToString('yyyy-MM-dd')+'.log')),([datetime]::UtcNow.ToString('o')+' '+$Message+"`r`n"))
    }catch{ $activity.Text='Desktop logging unavailable: '+$_.Exception.Message }
}
function Show-DesktopWindow {
    $form.Show();$form.WindowState='Normal';$form.Activate();[void]$form.BringToFront()
}
function Set-TrayHealth([string]$State){
    $icon=Get-GuardHealthIcon $State
    $notify.Icon=if($script:desktopIcons[$icon]){$script:desktopIcons[$icon]}else{[Drawing.SystemIcons]::Information}
    $notify.Text=('Offline Backup Guard: '+$State).Substring(0,[Math]::Min(63,('Offline Backup Guard: '+$State).Length))
    $trayStatus.Text=$State
}
function Confirm-Action([string]$Text) {
    return ([Windows.Forms.MessageBox]::Show($form,$Text,'Confirm action','YesNo','Warning','Button2') -eq 'Yes')
}
function Set-Dirty {
    if (-not $script:loading) { $script:dirty = $true; $script:preflightPassed = $false; $installButton.Enabled = $false; $activity.Text = 'Unsaved changes. Preflight must be repeated after saving.' }
}
$newButton = Add-Tool 'New configuration' ([Drawing.SystemIcons]::Application) {
    if ($script:dirty -and -not (Confirm-Action 'Discard unsaved changes and start a new configuration?')) { return }
    $dialog = New-Object Windows.Forms.SaveFileDialog
    $dialog.Filter = 'PowerShell data file (*.psd1)|*.psd1'; $dialog.FileName = 'backup.psd1'; $dialog.OverwritePrompt = $true
    if ($dialog.ShowDialog($form) -eq 'OK') {
        if (Test-Path -LiteralPath $dialog.FileName) { Show-Error 'Use Open for an existing configuration. New initialization cannot replace it.'; return }
        $script:previous = $null; $script:loadedPath = $null
        Set-Editor (New-GuardSetupConfiguration $dialog.FileName) @() $dialog.FileName
        $script:dirty = $true; $initialize.Checked = $false; $tabs.SelectedIndex = 0
    }
    $dialog.Dispose()
}
$openButton = Add-Tool 'Open configuration' ([Drawing.SystemIcons]::Application) {
    if ($script:dirty -and -not (Confirm-Action 'Discard unsaved changes and open another configuration?')) { return }
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = 'PowerShell data file (*.psd1)|*.psd1'
    if ($dialog.ShowDialog($form) -eq 'OK') { Start-UiOperation 'Load' @{ ConfigPath=$dialog.FileName } }
    $dialog.Dispose()
}
$saveButton = Add-Tool 'Save configuration (backs up existing files)' ([Drawing.SystemIcons]::Shield) { Save-Editor }
[void]$toolbar.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$refreshButton = Add-Tool 'Refresh recorded status (no mount or disk query)' ([Drawing.SystemIcons]::Information) { Start-Status }
$preflightButton = Add-Tool 'Run read-only preflight' ([Drawing.SystemIcons]::Information) {
    if (Assert-Saved) { Start-UiOperation 'Preflight' @{ConfigPath=$script:loadedPath} }
}
$testButton = Add-Tool 'Run explicit backup test (mounts and copies)' ([Drawing.SystemIcons]::Warning) {
    if (-not (Assert-Saved)) { return }
    if (-not $script:preflightPassed) { Show-Error 'Run and pass preflight first.'; return }
    if (Confirm-Action ('Run a real backup test on serial ' + $script:config.BackupDisk.SerialNumber + '? This mounts the disk, copies enabled sources, may mirror deletions and expire retention, then attempts to offline it. Approved administrative rights are required.')) {
        Start-UiOperation 'Test' @{ConfigPath=$script:loadedPath}
    }
}
$installButton = Add-Tool 'Install scheduled task (explicit Windows elevation)' ([Drawing.SystemIcons]::Shield) { Install-Task }
$installButton.Enabled = $false
$propertiesButton = Add-Tool 'Open Windows Task Scheduler properties' ([Drawing.SystemIcons]::Application) {
    if (-not $SmokeTest) { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\mmc.exe') -ArgumentList 'taskschd.msc' }
}
$title = New-Object Windows.Forms.ToolStripLabel('  Offline Backup Guard')
$title.Font = New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)
[void]$toolbar.Items.Add($title)
$pathRow = New-Object Windows.Forms.TableLayoutPanel
$pathRow.Dock = 'Fill'; $pathRow.ColumnCount=2
[void]$pathRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',110)))
[void]$pathRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
$pathLabel = New-Object Windows.Forms.Label; $pathLabel.Text='Configuration'; $pathLabel.Dock='Fill'; $pathLabel.TextAlign='MiddleLeft'
$configPathBox = New-Object Windows.Forms.TextBox; $configPathBox.Dock='Fill'; $configPathBox.ReadOnly=$true
$pathRow.Controls.Add($pathLabel,0,0); $pathRow.Controls.Add($configPathBox,1,0); $layout.Controls.Add($pathRow,0,1)
$tabs = New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'; $layout.Controls.Add($tabs,0,2)
$pages=@{}
foreach ($name in @('1  Disk','2  Sources','3  Schedule','4  Review','Status','Deferred files')) {
    $page=New-Object Windows.Forms.TabPage; $page.Text=$name; $page.BackColor=[Drawing.Color]::White; $page.Padding=New-Object Windows.Forms.Padding(10)
    [void]$tabs.TabPages.Add($page); $pages[$name]=$page
}
$activity = New-Object Windows.Forms.Label; $activity.Dock='Fill'; $activity.TextAlign='MiddleLeft'; $activity.Text='New configuration. No disk has been queried.'
$layout.Controls.Add($activity,0,3)
function New-Table([Windows.Forms.Control]$Parent, [int]$Rows) {
    $table=New-Object Windows.Forms.TableLayoutPanel; $table.Dock='Fill'; $table.ColumnCount=2; $table.RowCount=$Rows
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',200)))
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    $Parent.Controls.Add($table); return $table
}
function Add-Field($Table, [int]$Row, [string]$Text, [Windows.Forms.Control]$Control) {
    [void]$Table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',36)))
    $label=New-Object Windows.Forms.Label; $label.Text=$Text; $label.Dock='Fill'; $label.TextAlign='MiddleLeft'
    $Control.Dock='Fill'; $Table.Controls.Add($label,0,$Row); $Table.Controls.Add($Control,1,$Row)
    return $Control
}
function New-TextBox { $box=New-Object Windows.Forms.TextBox; $box.Add_TextChanged({Set-Dirty}); return $box }
function New-Number([int]$Min,[int]$Max) { $box=New-Object Windows.Forms.NumericUpDown; $box.Minimum=$Min; $box.Maximum=$Max; $box.Add_ValueChanged({Set-Dirty}); return $box }
function New-Command([string]$Text,[scriptblock]$Action) {
    $button=New-Object Windows.Forms.Button; $button.Text=$Text; $button.AutoSize=$true; $button.Height=30; $button.Padding=New-Object Windows.Forms.Padding(7,0,7,0); $button.Add_Click($Action); return $button
}
function New-Grid([bool]$ReadOnly) {
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Dock='Fill'; $grid.BackgroundColor=[Drawing.Color]::White; $grid.BorderStyle='FixedSingle'; $grid.RowHeadersVisible=$false
    $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.ReadOnly=$ReadOnly; $grid.AutoGenerateColumns=$false
    $grid.SelectionMode='FullRowSelect'; $grid.MultiSelect=$false; $grid.AutoSizeRowsMode='None'; $grid.RowTemplate.Height=28
    $grid.ColumnHeadersHeightSizeMode='DisableResizing'; $grid.ColumnHeadersHeight=42
    $grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(247,248,249)
    return $grid
}
function Add-Column($Grid,[string]$Name,[string]$Header,[int]$Width,[switch]$Check) {
    $column=if($Check){New-Object Windows.Forms.DataGridViewCheckBoxColumn}else{New-Object Windows.Forms.DataGridViewTextBoxColumn}
    $column.Name=$Name; $column.HeaderText=$Header; $column.Width=$Width; $column.SortMode='NotSortable'
    [void]$Grid.Columns.Add($column)
}

$diskTable=New-Table $pages['1  Disk'] 7
$diskCommands=New-Object Windows.Forms.FlowLayoutPanel; $diskCommands.Dock='Fill'
$diskCommands.Controls.Add((New-Command 'List USB disks' { Start-UiOperation 'Disks' @{} }))
$diskCommands.Controls.Add((New-Command 'Use selected disk' {
    if (-not $diskGrid.CurrentRow) { return }
    $disk=$script:diskRows[$diskGrid.CurrentRow.Index]
    if ($disk.IsBoot -or $disk.IsSystem -or -not $disk.SerialNumber) { Show-Error 'Only a dedicated non-system USB disk with a serial number is eligible.'; return }
    if (Confirm-Action "Pin this USB identity?`r`n$($disk.FriendlyName)`r`nSerial: $($disk.SerialNumber)`r`nNo format, mount or disk-state change will be performed.") {
        $friendly.Text=$disk.FriendlyName; $serial.Text=$disk.SerialNumber; $script:config.BackupDisk.SizeGB=$disk.SizeGB; Set-Dirty
    }
}))
[void]$diskTable.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',40)))
$diskTable.Controls.Add($diskCommands,0,0); $diskTable.SetColumnSpan($diskCommands,2)
$diskGrid=New-Grid $true
foreach($column in @(@('Number','Disk',55),@('FriendlyName','USB device',250),@('SerialNumber','Exact serial',250),@('SizeGB','GB',95),@('IsOffline','Offline',80),@('IsBoot','Boot',70),@('IsSystem','System',70))) { Add-Column $diskGrid $column[0] $column[1] $column[2] }
[void]$diskTable.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
$diskTable.Controls.Add($diskGrid,0,1); $diskTable.SetColumnSpan($diskGrid,2)
$friendly=Add-Field $diskTable 2 'Pinned device name' (New-TextBox); $friendly.ReadOnly=$true
$serial=Add-Field $diskTable 3 'Pinned serial number' (New-TextBox); $serial.ReadOnly=$true
$volumeLabel=Add-Field $diskTable 4 'Expected volume label' (New-TextBox)
$mountPath=Add-Field $diskTable 5 'Dedicated mount folder' (New-TextBox)
$diskWarning=New-Object Windows.Forms.Label; $diskWarning.Dock='Fill'; $diskWarning.Text='Dedicated, already formatted USB disk only. No formatting is available. Software-offline is not a physical air gap.'
[void]$diskTable.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',45))); $diskTable.Controls.Add($diskWarning,0,6); $diskTable.SetColumnSpan($diskWarning,2)

$sourceLayout=New-Object Windows.Forms.TableLayoutPanel; $sourceLayout.Dock='Fill'; $sourceLayout.RowCount=3; $sourceLayout.ColumnCount=1
[void]$sourceLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',38)))
[void]$sourceLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$sourceLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',130)))
$pages['2  Sources'].Controls.Add($sourceLayout)
$sourceCommands=New-Object Windows.Forms.FlowLayoutPanel; $sourceCommands.Dock='Fill'; $sourceLayout.Controls.Add($sourceCommands,0,0)
$sourceCommands.Controls.Add((New-Command 'Add source' { Add-SourceRow (New-GuardSetupSource); Set-Dirty }))
$sourceCommands.Controls.Add((New-Command 'Remove selected' {
    if ($sourceGrid.CurrentRow -and (Confirm-Action 'Remove this source from the configuration? Existing backup data is not removed by setup.')) { $sourceGrid.Rows.RemoveAt($sourceGrid.CurrentRow.Index); Set-Dirty }
}))
$sourceCommands.Controls.Add((New-Command 'Choose source folder' {
    if (-not $sourceGrid.CurrentRow) { return }
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog($form) -eq 'OK') { $sourceGrid.CurrentRow.Cells['SourcePath'].Value=$dialog.SelectedPath; Set-Dirty }
    $dialog.Dispose()
}))
$sourceCommands.Controls.Add((New-Command 'Estimate source size' {
    try {
        $candidate=Read-Editor
        Test-GuardSetupConfiguration $candidate.Config $candidate.Sources $configPathBox.Text | Out-Null
        Start-UiOperation 'Estimate' @{Sources=$candidate.Sources}
    } catch { Show-Error $_.Exception.Message }
}))
$sourceGrid=New-Grid $false
Add-Column $sourceGrid 'Enabled' 'Enabled' 60 -Check
foreach($column in @(@('Name','Name',125),@('SourcePath','Source path',230),@('DestinationSubfolder','Destination alias',125),@('PreviousVersions','Previous versions',85),@('DeletedRetentionDays','Deleted retention days',100))) { Add-Column $sourceGrid $column[0] $column[1] $column[2] }
Add-Column $sourceGrid 'MirrorDeletes' 'Mirror deletes' 80 -Check
Add-Column $sourceGrid 'MaxDeleteCount' 'Max deletions' 95
Add-Column $sourceGrid 'CanaryRequired' 'Canary required' 85 -Check
Add-Column $sourceGrid 'CanaryPath' 'Source canary path' 240
Add-Column $sourceGrid 'CanarySha256' 'Pinned source canary SHA256' 300
$sourceGrid.Add_CellValueChanged({Set-Dirty})
$sourceGrid.Add_CurrentCellDirtyStateChanged({ if($sourceGrid.IsCurrentCellDirty){[void]$sourceGrid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)} })
$sourceGrid.Add_DataError({ param($sender,$eventArgs); $eventArgs.ThrowException=$false; $activity.Text='Invalid cell value. Review the source row.' })
$sourceLayout.Controls.Add($sourceGrid,0,1)
$estimateBox=New-Object Windows.Forms.TextBox; $estimateBox.Dock='Fill'; $estimateBox.Multiline=$true; $estimateBox.ReadOnly=$true; $estimateBox.ScrollBars='Vertical'
$estimateBox.Text="Previous versions: 0 = off, 1-1000 = count; blank = legacy policy. Deleted retention is independent.`r`nSource estimates exclude reparse points. Last recorded capacity is shown under Status."
$sourceLayout.Controls.Add($estimateBox,0,2)
function Add-SourceRow($Source) {
    $index=$sourceGrid.Rows.Add(); $row=$sourceGrid.Rows[$index]
    foreach ($column in $sourceGrid.Columns) {
        $value=$Source.($column.Name)
        if ($column -is [Windows.Forms.DataGridViewCheckBoxColumn]) {
            $default=if($column.Name -eq 'CanaryRequired'){ -not [string]::IsNullOrWhiteSpace([string]$Source.CanarySha256) }else{$true}
            $value=if([string]::IsNullOrWhiteSpace([string]$value)){$default}else{[string]$value -match '^(?i:true|1|yes|y|ja|j)$'}
        }
        $row.Cells[$column.Name].Value=$value
    }
}

$scheduleTable=New-Table $pages['3  Schedule'] 10
$taskName=Add-Field $scheduleTable 0 'Task name' (New-TextBox)
$taskUser=Add-Field $scheduleTable 1 'Windows account' (New-TextBox)
$logonMode=New-Object Windows.Forms.ComboBox; $logonMode.DropDownStyle='DropDownList'; [void]$logonMode.Items.AddRange(@('Interactive','Password')); $logonMode.Add_SelectedIndexChanged({Set-Dirty})
[void](Add-Field $scheduleTable 2 'Logon mode' $logonMode)
$scheduleTime=Add-Field $scheduleTable 3 'Daily start (HH:mm)' (New-TextBox)
$windowStart=Add-Field $scheduleTable 4 'Allowed start from' (New-TextBox)
$windowEnd=Add-Field $scheduleTable 5 'Allowed start until' (New-TextBox)
$threads=Add-Field $scheduleTable 6 'Copy worker count' (New-Number 1 32)
$retention=Add-Field $scheduleTable 7 'Global legacy retention days' (New-Number 1 36500)
$deferredThreshold=Add-Field $scheduleTable 8 'Deferred-file warning after runs' (New-Number 1 365)
$scheduleWarning=New-Object Windows.Forms.Label; $scheduleWarning.Dock='Fill'
$scheduleWarning.Text="Interactive: the configured user MUST stay logged in at run time.`r`nPassword: credentials are requested only in the approved Windows dialog during task installation. No passwords are saved in configuration files.`r`n`r`nA preflight pass in this session is not acceptance under the scheduled identity. Verify source access, an actual scheduled run, and a separate restore drill before relying on unattended backups."
[void]$scheduleTable.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))); $scheduleTable.Controls.Add($scheduleWarning,0,9); $scheduleTable.SetColumnSpan($scheduleWarning,2)

$reviewTable=New-Table $pages['4  Review'] 10
$sourceListPath=Add-Field $reviewTable 0 'Source CSV' (New-TextBox)
$stateRoot=Add-Field $reviewTable 1 'State folder' (New-TextBox)
$logRoot=Add-Field $reviewTable 2 'Robocopy logs folder' (New-TextBox)
$reportRoot=Add-Field $reviewTable 3 'Reports folder' (New-TextBox)
$canaryPath=Add-Field $reviewTable 4 'Host canary' (New-TextBox); $canaryPath.ReadOnly=$true
$initialize=New-Object Windows.Forms.CheckBox; $initialize.Text='Initialize a NEW canary at first save only'; $initialize.Add_CheckedChanged({Set-Dirty})
[void](Add-Field $reviewTable 5 'New installation' $initialize)
$ready=New-Object Windows.Forms.CheckBox; $ready.Text='I reviewed this configuration and approve it for runner use'; $ready.Add_CheckedChanged({Set-Dirty})
[void](Add-Field $reviewTable 6 'Ready for use' $ready)
$reviewText=New-Object Windows.Forms.TextBox; $reviewText.Dock='Fill'; $reviewText.Multiline=$true; $reviewText.ReadOnly=$true; $reviewText.ScrollBars='Vertical'
[void]$reviewTable.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))); $reviewTable.Controls.Add($reviewText,0,7); $reviewTable.SetColumnSpan($reviewText,2)
$reviewCommands=New-Object Windows.Forms.FlowLayoutPanel; $reviewCommands.Dock='Fill'
$reviewCommands.Controls.Add((New-Command 'Save configuration' {Save-Editor}))
$reviewCommands.Controls.Add((New-Command 'Run preflight' {if(Assert-Saved){Start-UiOperation 'Preflight' @{ConfigPath=$script:loadedPath}}}))
$reviewCommands.Controls.Add((New-Command 'Install task...' {Install-Task}))
[void]$reviewTable.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',40))); $reviewTable.Controls.Add($reviewCommands,0,8); $reviewTable.SetColumnSpan($reviewCommands,2)
$reviewWarning=New-Object Windows.Forms.Label; $reviewWarning.Dock='Fill'; $reviewWarning.Text='A canary is a change signal, not proof of ransomware absence. Keep an independent offline or immutable backup and test restores.'
[void]$reviewTable.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',45))); $reviewTable.Controls.Add($reviewWarning,0,9); $reviewTable.SetColumnSpan($reviewWarning,2)

$statusLayout=New-Object Windows.Forms.TableLayoutPanel; $statusLayout.Dock='Fill'; $statusLayout.ColumnCount=1; $statusLayout.RowCount=6
foreach($height in @(42,145,68)) {[void]$statusLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
[void]$statusLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$statusLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',60)))
[void]$statusLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',105)))
$pages['Status'].Controls.Add($statusLayout)
$statusHeading=New-Object Windows.Forms.Label; $statusHeading.Dock='Fill'; $statusHeading.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold); $statusHeading.Text='Not loaded'
$statusHeader=New-Object Windows.Forms.TableLayoutPanel; $statusHeader.Dock='Fill'; $statusHeader.ColumnCount=3
[void]$statusHeader.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$statusHeader.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',140)))
[void]$statusHeader.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',160)))
$statusHeader.Controls.Add($statusHeading,0,0)
$statusHeader.Controls.Add((New-Command 'Storage history' { Show-StatusDetail 'Storage' }),1,0)
$statusHeader.Controls.Add((New-Command 'Run source details' { Show-StatusDetail 'Sources' }),2,0)
$statusLayout.Controls.Add($statusHeader,0,0)
$statusDetails=New-Object Windows.Forms.TextBox; $statusDetails.Multiline=$true; $statusDetails.ReadOnly=$true; $statusDetails.Dock='Fill'; $statusDetails.ScrollBars='Vertical'; $statusDetails.BackColor=[Drawing.Color]::White
$statusLayout.Controls.Add($statusDetails,0,1)
$storageDetails=New-Object Windows.Forms.Label; $storageDetails.Dock='Fill'; $storageDetails.Text='No capacity measurement loaded. Current disk state is unknown.'; $statusLayout.Controls.Add($storageDetails,0,2)
$historyGrid=New-Grid $true
foreach($column in @(@('started_at','Attempt started',170),@('status','Status',100),@('phase','Phase',145),@('offline','Confirmed offline at end',110),@('error','Recorded error',360),@('log_path','Journal log',240),@('robocopy_log_path','Robocopy log',240))) { Add-Column $historyGrid $column[0] $column[1] $column[2] }
$statusLayout.Controls.Add($historyGrid,0,3)
$restorePanel=New-Object Windows.Forms.TableLayoutPanel; $restorePanel.Dock='Fill'; $restorePanel.ColumnCount=2
[void]$restorePanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$restorePanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',185)))
$restoreNote=New-Object Windows.Forms.TextBox; $restoreNote.Dock='Fill'; $restoreNote.AccessibleName='Separate restore drill operator note'
$restoreButton=New-Command 'Record restore drill...' {
    if (-not (Assert-Saved)) { return }
    if ([string]::IsNullOrWhiteSpace($restoreNote.Text)) { Show-Error 'Enter a note about the separately performed restore drill.'; return }
    if (Confirm-Action 'Record your statement about a separately performed restore drill? This does not perform or verify a restore and does not accept the scheduled account.') {
        Start-UiOperation 'Restore' @{ConfigPath=$script:loadedPath;Note=$restoreNote.Text;Confirmed=$true}
    }
}
$restorePanel.Controls.Add($restoreNote,0,0); $restorePanel.Controls.Add($restoreButton,1,0)
$restoreLabel=New-Object Windows.Forms.Label; $restoreLabel.Text='Restore drill: no operator record loaded. Recoverability is not verified.'; $restoreLabel.Dock='Fill'
$restorePanel.Controls.Add($restoreLabel,0,1); $restorePanel.SetColumnSpan($restoreLabel,2); $statusLayout.Controls.Add($restorePanel,0,4)
$outputBox=New-Object Windows.Forms.TextBox; $outputBox.Multiline=$true; $outputBox.ReadOnly=$true; $outputBox.ScrollBars='Both'; $outputBox.Dock='Fill'; $outputBox.WordWrap=$false
$statusLayout.Controls.Add($outputBox,0,5)

$deferredPage=$pages['Deferred files'];$deferredPage.Text='Deferred files (0)'
$deferredLayout=New-Object Windows.Forms.TableLayoutPanel;$deferredLayout.Dock='Fill';$deferredLayout.ColumnCount=1;$deferredLayout.RowCount=3
[void]$deferredLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',45)))
[void]$deferredLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$deferredLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',95)))
$deferredPage.Controls.Add($deferredLayout)
$deferredHeading=New-Object Windows.Forms.Label;$deferredHeading.Dock='Fill';$deferredHeading.Font=New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)
$deferredLayout.Controls.Add($deferredHeading,0,0)
$deferredGrid=New-Grid $true
foreach($column in @(@('SourceName','Source',150),@('RelativePath','File',280),@('Reason','Reason',220),@('ConsecutiveRuns','Affected runs',95),@('FirstSeen','First seen',180),@('LastSeen','Last seen',180))){Add-Column $deferredGrid $column[0] $column[1] $column[2]}
$deferredLayout.Controls.Add($deferredGrid,0,1)
$deferredDetail=New-Object Windows.Forms.TextBox;$deferredDetail.Dock='Fill';$deferredDetail.Multiline=$true;$deferredDetail.ReadOnly=$true;$deferredDetail.ScrollBars='Both'
$deferredLayout.Controls.Add($deferredDetail,0,2)
$deferredGrid.Add_SelectionChanged({
    $deferredDetail.Text=''
    if($deferredGrid.SelectedRows.Count){$item=$deferredGrid.SelectedRows[0].Tag;if($item){$deferredDetail.Text="$($item.SourceName)`r`n$($item.RelativePath)`r`n$($item.Reason) | Windows error $($item.ErrorCode) | Runs: $($item.ConsecutiveRuns)`r`nFirst: $($item.FirstSeen) | Last: $($item.LastSeen)"}}
})

function Show-StatusDetail([string]$Kind) {
    if(-not $script:lastStatus){Show-Error 'Refresh recorded status first.';return}
    $dialog=New-Object Windows.Forms.Form; $dialog.Text=if($Kind -eq 'Storage'){'Recorded daily storage history'}else{'Recorded source results'}
    $dialog.Size=New-Object Drawing.Size(900,500); $dialog.MinimumSize=New-Object Drawing.Size(650,350); $dialog.StartPosition='CenterParent'; $dialog.Font=$form.Font
    if($Kind -eq 'Storage'){
        $grid=New-Grid $true
        foreach($column in @(@('Date','Measured at (original timestamp)',270),@('Capacity','Capacity GiB',150),@('Used','Used GiB',150),@('Free','Free GiB',150))){Add-Column $grid $column[0] $column[1] $column[2]}
        foreach($sample in @($script:lastStatus.StorageHistory|Where-Object {$_})){
            [void]$grid.Rows.Add([string]$sample.measured_at,('{0:N2}' -f ($sample.capacity_bytes/1GB)),('{0:N2}' -f ($sample.used_bytes/1GB)),('{0:N2}' -f ($sample.free_bytes/1GB)))
        }
        $dialog.Controls.Add($grid)
    }else{
        if(-not $historyGrid.CurrentRow){$dialog.Dispose();Show-Error 'Select a recorded run first.';return}
        $run=@($script:lastStatus.History)[$historyGrid.CurrentRow.Index]
        $text=New-Object Windows.Forms.TextBox; $text.Dock='Fill'; $text.Multiline=$true; $text.ReadOnly=$true; $text.ScrollBars='Both'; $text.WordWrap=$false
        $text.Text=ConvertTo-Json -InputObject @($run.sources) -Depth 12; $dialog.Controls.Add($text)
    }
    try{[void]$dialog.ShowDialog($form)}finally{$dialog.Dispose()}
}

function Set-Editor($Config, [object[]]$Sources, [string]$Path) {
    $script:loading=$true
    try {
        $script:config=ConvertTo-GuardHashtable $Config
        $configPathBox.Text=$Path
        $friendly.Text=$Config.BackupDisk.FriendlyName; $serial.Text=$Config.BackupDisk.SerialNumber
        $volumeLabel.Text=$Config.BackupDisk.VolumeLabel; $mountPath.Text=$Config.BackupDisk.PreferredAccessPath
        $taskName.Text=$Config.TaskName; $taskUser.Text=$Config.TaskUser; $logonMode.SelectedItem=$Config.TaskLogonType
        $scheduleTime.Text=$Config.ScheduleTime; $windowStart.Text=$Config.WindowStart; $windowEnd.Text=$Config.WindowEnd
        $threads.Value=[decimal]$Config.Threads; $retention.Value=[decimal]$Config.RetentionDays
        $deferredThreshold.Value=if($Config.ContainsKey('DeferredWarningAfterRuns')){[decimal]$Config.DeferredWarningAfterRuns}else{7}
        $sourceListPath.Text=$Config.SourceListPath; $stateRoot.Text=$Config.StateRoot; $logRoot.Text=$Config.LogRoot; $reportRoot.Text=$Config.ReportRoot
        $canaryPath.Text=$Config.Canary.Path; $ready.Checked=[bool]$Config.ReadyForUse
        $initialize.Checked=$false; $initialize.Enabled=($null -eq $script:previous)
        $sourceGrid.Rows.Clear(); foreach($source in $Sources){Add-SourceRow $source}
        $script:preflightPassed=$false; $installButton.Enabled=$false
    } finally {$script:loading=$false}
}
function Read-Editor {
    [void]$sourceGrid.EndEdit()
    $cfg=ConvertTo-GuardHashtable $script:config
    $cfg.BackupDisk.FriendlyName=$friendly.Text.Trim(); $cfg.BackupDisk.SerialNumber=$serial.Text.Trim()
    $cfg.BackupDisk.VolumeLabel=$volumeLabel.Text.Trim(); $cfg.BackupDisk.PreferredAccessPath=$mountPath.Text.Trim()
    $cfg.TaskName=$taskName.Text.Trim(); $cfg.TaskUser=$taskUser.Text.Trim(); $cfg.TaskLogonType=[string]$logonMode.SelectedItem
    $cfg.ScheduleTime=$scheduleTime.Text.Trim(); $cfg.WindowStart=$windowStart.Text.Trim(); $cfg.WindowEnd=$windowEnd.Text.Trim()
    $cfg.Threads=[int]$threads.Value; $cfg.RetentionDays=[int]$retention.Value
    $cfg.DeferredWarningAfterRuns=[int]$deferredThreshold.Value
    $cfg.SourceListPath=$sourceListPath.Text.Trim(); $cfg.StateRoot=$stateRoot.Text.Trim(); $cfg.LogRoot=$logRoot.Text.Trim(); $cfg.ReportRoot=$reportRoot.Text.Trim()
    $cfg.ReadyForUse=$ready.Checked
    $sources=@(foreach($row in $sourceGrid.Rows) {
        $value=[ordered]@{}
        foreach($column in $sourceGrid.Columns){$value[$column.Name]=$row.Cells[$column.Name].Value}
        [pscustomobject]$value
    })
    [pscustomobject]@{Config=$cfg;Sources=$sources}
}
function Assert-Saved {
    if ($script:dirty -or -not $script:loadedPath) {Show-Error 'Save the reviewed configuration before this operation.'; return $false}
    return $true
}
function Save-Editor {
    try {
        $candidate=Read-Editor
        Test-GuardSetupConfiguration $candidate.Config $candidate.Sources $configPathBox.Text | Out-Null
        $changes=Get-GuardRetentionReductions $candidate.Config $candidate.Sources $script:previous
        $confirmed=$false
        if($changes.Count){$confirmed=Confirm-Action (($changes -join "`r`n") + "`r`nThis reduces recovery history. Expiry can permanently delete older copies after successful backups. Continue?"); if(-not $confirmed){return}}
        if($initialize.Checked -and -not (Confirm-Action 'Create the pinned host canary once for this NEW installation? An existing or missing previously configured canary will never be recreated or relearned.')){return}
        Start-UiOperation 'Save' @{ConfigPath=$configPathBox.Text;Config=$candidate.Config;Sources=$candidate.Sources;InitializeCanary=$initialize.Checked;ConfirmRetentionReduction=$confirmed}
    }catch{Show-Error $_.Exception.Message}
}
function Start-Status([switch]$Passive) {
    if(-not $script:loadedPath){Show-Error 'Open or save a configuration first.';return}
    Start-UiOperation 'Status' @{ConfigPath=$script:loadedPath;Passive=[bool]$Passive}
}
function Set-StatusView($Data) {
    $s=$Data.Status; $script:lastStatus=$s
    Set-TrayHealth ([string]$s.State)
    $statusHeading.Text=[string]$s.State
    $statusHeading.ForeColor=switch($s.State){'Succeeded'{[Drawing.Color]::FromArgb(26,110,67)} 'Running'{[Drawing.Color]::Black} {$_ -in @('Warning','Needs attention','Missed')}{[Drawing.Color]::DarkGoldenrod} default{[Drawing.Color]::FromArgb(164,39,39)}}
    $d=$s.Deferred;$count=if($d -and -not $d.Valid){'?'}elseif($d){[string]$d.Count}else{'0'}
    $deferredPage.Text="Deferred files ($count)";$deferredHeading.Text="$count pending files"
    if($d){$deferredHeading.Text+=" | $($d.OverdueCount) affected for at least $($d.WarningAfterRuns) runs";if(-not $d.Valid){$deferredHeading.Text=$d.Error}}
    $statusHeading.Text+=" | $count deferred"
    $deferredGrid.Rows.Clear()
    foreach($item in @($d.Entries | Where-Object {$_} | Sort-Object ConsecutiveRuns -Descending)){
        $i=$deferredGrid.Rows.Add();$deferredGrid.Rows[$i].Tag=$item
        foreach($column in $deferredGrid.Columns){$deferredGrid.Rows[$i].Cells[$column.Name].Value=[string]$item.($column.Name)}
    }
    if($deferredGrid.Rows.Count){$deferredGrid.ClearSelection();$deferredGrid.Rows[0].Selected=$true}
    $latest=@($s.History | Select-Object -First 1)
    $offline='Unknown; no completed confirmation'
    if($latest.Count -and $null -ne $latest[0].offline){$offline="Recorded $($latest[0].offline) at $($latest[0].finished_at)"}
    $statusDetails.Text="Last attempt: $($s.LastAttempt)    Last success: $($s.LastSuccess)`r`nNext scheduled run: $($s.NextRun)    Task: $($s.TaskState)    Last task result: $($s.LastTaskResult)`r`nFailure streak: $($s.ConsecutiveFailures)    Warning streak: $($s.ConsecutiveWarnings)    Problem since: $($s.ProblemSince)    Overdue: $($s.Overdue)`r`nProblem: $($s.Problem)`r`nDrift: $(@($s.Drift) -join '; ')`r`nLast recorded offline result: $offline. Current disk state is UNKNOWN (not polled).`r`nActive phase: $($s.Active.phase)    Journal: $($s.LogRoot)"
    if($s.Storage){
        $stale=if($s.Storage.stale){'STALE'}else{'Recorded sample'}
        $storageDetails.Text=('{0}: measured {1} | capacity {2:N2} GiB | used {3:N2} GiB | free {4:N2} GiB' -f $stale,$s.Storage.measured_at,($s.Storage.capacity_bytes/1GB),($s.Storage.used_bytes/1GB),($s.Storage.free_bytes/1GB)) + "`r`nLast-known measurement only; no live disk query. Retained versions also consume capacity."
        $storageDetails.ForeColor=if($s.Storage.stale){[Drawing.Color]::FromArgb(164,39,39)}else{[Drawing.Color]::FromArgb(50,60,55)}
    }else{$storageDetails.Text='No recorded capacity measurement. Current disk state is unknown.'}
    $historyGrid.Rows.Clear()
    foreach($item in @($s.History)){
        $index=$historyGrid.Rows.Add(); foreach($column in $historyGrid.Columns){$historyGrid.Rows[$index].Cells[$column.Name].Value=[string]$item.($column.Name)}
    }
    $restoreLabel.Text=if($Data.Restore){"Restore drill operator record: $($Data.Restore.recorded_at). Not verified by the tool; scheduled identity not accepted."}else{'Restore drill: no operator record. Perform a separate restore; recoverability is not verified.'}
}
function Set-Busy([bool]$Busy) {
    foreach($page in $tabs.TabPages){$page.Enabled=(-not $Busy -or $page.Text -eq 'Status' -or $page -eq $deferredPage)}
    $restoreButton.Enabled=-not $Busy
    foreach($item in $toolbar.Items){if($item -is [Windows.Forms.ToolStripButton]){$item.Enabled=-not $Busy}}
    $installButton.Enabled=(-not $Busy -and $script:preflightPassed -and -not $script:dirty)
}
function Get-SessionDirectory {
    if(-not $script:sessionDirectory){
        $script:sessionDirectory=Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-ui-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:sessionDirectory)
    }
    return $script:sessionDirectory
}
function Start-UiOperation([string]$Operation, [hashtable]$Request) {
    if($SmokeTest){throw 'Smoke mode cannot start operations.'}
    if($script:busy){Show-Error 'An operation is already running.';return}
    try{
        $directory=Get-SessionDirectory; $id=[guid]::NewGuid().ToString('N')
        $requestFile=Join-Path $directory "request-$id.json"; $resultFile=Join-Path $directory "result-$id.clixml"
        [IO.File]::WriteAllText($requestFile,($Request|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
        $arguments='-NoProfile -NonInteractive -File "{0}" -WorkerOperation {1} -RequestPath "{2}" -ResultPath "{3}"' -f $PSCommandPath,$Operation,$requestFile,$resultFile
        if($Operation -eq 'Test'){
            $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
            $script:busy=@{Process=$process;Operation=$Operation;Request=$Request;RequestFile=$requestFile;ResultFile=$resultFile;Started=[datetime]::Now}
            Set-Busy $true; $tabs.SelectedIndex=4
            Set-TrayHealth 'Running'
            $outputBox.Text='Explicit elevated backup test started. Captured runner output is available on completion; current journal progress appears below.'
            return
        }
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info.Arguments=$arguments
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.Encoding]::UTF8; $info.StandardErrorEncoding=[Text.Encoding]::UTF8
        $process=New-Object Diagnostics.Process; $process.StartInfo=$info; [void]$process.Start()
        $script:busy=@{Process=$process;Operation=$Operation;Request=$Request;RequestFile=$requestFile;ResultFile=$resultFile;Out=$process.StandardOutput.ReadToEndAsync();Err=$process.StandardError.ReadToEndAsync();Started=[datetime]::Now}
        if($Operation -ne 'Status'){Set-Busy $true}
        if($Operation -eq 'Preflight' -or ($Operation -eq 'Status' -and -not $Request.Passive)){$tabs.SelectedIndex=4}
    }catch{
        if($Operation -eq 'Status' -and $Request.Passive){Set-TrayHealth 'Unknown';Write-DesktopLog $_.Exception.Message}
        else{Show-Error $_.Exception.Message}
    }
}
function Install-Task {
    if(-not (Assert-Saved)){return}
    if(-not $script:preflightPassed){Show-Error 'A passed ValidateOnly preflight is required before task installation.';return}
    if(-not (Confirm-Action "Request Windows elevation and register the configured daily task?`r`nThe helper reruns ValidateOnly. This is NOT scheduled-identity acceptance. Verify a scheduled run and a separate restore drill.`r`nInteractive mode requires the configured user to stay logged in.")){return}
    $replace=Confirm-Action 'Allow replacement if a task with this exact name already exists? Choose No to refuse overwriting an existing task.'
    try{
        $directory=Get-SessionDirectory; $resultFile=Join-Path $directory ('result-'+[guid]::NewGuid().ToString('N')+'.clixml')
        $args='-NoProfile -STA -File "{0}" -ConfigPath "{1}" -Install -AcknowledgeIdentityAcceptancePending -ResultPath "{2}"' -f (Join-Path $PSScriptRoot 'src\Configure-Task.ps1'),$script:loadedPath,$resultFile
        if($replace){$args+=' -ReplaceExisting'}
        $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -Verb RunAs -WindowStyle Hidden -PassThru
        $script:busy=@{Process=$process;Operation='Install';ResultFile=$resultFile;Started=[datetime]::Now}
        Set-Busy $true
    }catch{Show-Error ('Task installation not started: '+$_.Exception.Message)}
}
$timer=New-Object Windows.Forms.Timer; $timer.Interval=250
$timer.Add_Tick({
    if($script:desktopSession -and $script:desktopSession.Event.WaitOne(0)){Show-DesktopWindow}
    if(-not $script:busy){return}
    $job=$script:busy
    $activity.Text='{0} | process {1} | {2:N0} s' -f $job.Operation,$job.Process.Id,([datetime]::Now-$job.Started).TotalSeconds
    if(-not $job.Process.HasExited){
        if($job.Operation -eq 'Test' -and ([datetime]::Now-$script:lastActivePoll).TotalSeconds -ge 2){
            $script:lastActivePoll=[datetime]::Now
            # One bounded local journal read, never scheduler/account resolution or disk polling.
            $cfgPath=$job.Request.ConfigPath
            if($cfgPath -match '^[a-zA-Z]:\\'){
                $diag=Join-Path (Split-Path $cfgPath -Parent) ([IO.Path]::GetFileNameWithoutExtension($cfgPath)+'-diagnostics')
                try{
                    $activePath=Join-Path $diag 'active.json'
                    if((Test-Path -LiteralPath $activePath) -and (Get-Item -LiteralPath $activePath).Length -le 1MB){
                        $active=Get-Content -LiteralPath $activePath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $activity.Text += " | phase: $($active.phase) | source: $($active.source) | runner PID: $($active.pid)"
                        $statusHeading.Text='Backup test running'
                    }
                }catch{ $activity.Text+=' | journal temporarily unavailable' }
            }
        }
        return
    }
    try{
        $captured=''
        if($job.Out){$captured=$job.Out.GetAwaiter().GetResult()+$job.Err.GetAwaiter().GetResult()}
        if(-not (Test-Path -LiteralPath $job.ResultFile)){throw 'Child process ended without a result. Review execution policy and permissions; no bypass was attempted.'}
        $result=Import-Clixml -LiteralPath $job.ResultFile
        if($result.Output){$captured += $result.Output}
        $outputBox.Text=($captured + "`r`n" + $result.Message).Trim()
        if(-not $result.Success){throw $result.Message}
        switch($job.Operation){
            'Load'{ $script:previous=$result.Data; $script:loadedPath=$job.Request.ConfigPath; Set-Editor $result.Data.Config @($result.Data.Sources) $script:loadedPath; $script:dirty=$false }
            'Save'{ $script:previous=[pscustomobject]@{Config=$job.Request.Config;Sources=$job.Request.Sources}; $script:config=$job.Request.Config; $script:loadedPath=$job.Request.ConfigPath; $script:dirty=$false; $script:preflightPassed=$false; $script:loading=$true; $initialize.Checked=$false; $initialize.Enabled=$false; $script:loading=$false }
            'Disks'{ $script:diskRows=@($result.Data); $diskGrid.Rows.Clear(); foreach($disk in $script:diskRows){$index=$diskGrid.Rows.Add();foreach($column in $diskGrid.Columns){$diskGrid.Rows[$index].Cells[$column.Name].Value=[string]$disk.($column.Name)}} }
            'Status'{Set-StatusView $result.Data; if(-not $job.Request.Passive){$tabs.SelectedIndex=4}}
            'Preflight'{$script:preflightPassed=$true; $outputBox.AppendText("`r`nValidateOnly passed. Scheduled identity and restore acceptance remain unverified.");$tabs.SelectedIndex=4}
            'Estimate'{ $estimateBox.Text=(@($result.Data|ForEach-Object{'{0}: {1:N2} GiB, {2} files; complete={3}; errors={4}; skipped reparse points={5}; {6}' -f $_.Name,($_.Bytes/1GB),$_.Files,$_.Complete,$_.Errors,$_.SkippedReparsePoints,$_.MeasuredAt}) -join "`r`n")+"`r`nEstimate only, not a snapshot or capacity guarantee. Version history needs additional space." }
            'Restore'{$restoreLabel.Text="Operator restore note recorded at $($result.Data.recorded_at). Not independently verified."}
            'Install'{$tabs.SelectedIndex=4}
            'Test'{$tabs.SelectedIndex=4; $outputBox.AppendText("`r`nRefresh recorded status, inspect the offline result and perform a separate restore drill.")}
        }
        $activity.Text=$job.Operation+' completed.'
    }catch{
        if($job.Operation -eq 'Preflight'){$script:preflightPassed=$false}
        $activity.Text=$job.Operation+' failed: '+$_.Exception.Message
        $outputBox.AppendText("`r`n"+$_.Exception.Message)
        if($job.Operation -eq 'Status'){
            Set-TrayHealth 'Unknown';$statusHeading.Text='Unknown';$statusDetails.Text=$_.Exception.Message
            Write-DesktopLog $_.Exception.Message
            if(-not $job.Request.Passive){Show-Error $_.Exception.Message}
        }else{Show-Error $_.Exception.Message}
    }finally{
        $job.Process.Dispose(); $script:busy=$null; Set-Busy $false
        foreach($file in @($job.RequestFile,$job.ResultFile)){if($file -and (Test-Path -LiteralPath $file)){Remove-Item -LiteralPath $file -Force}}
        if($job.Operation -in @('Load','Save','Test') -and $script:loadedPath){Start-Status -Passive}
    }
})
$tabs.Add_SelectedIndexChanged({
    if($tabs.SelectedIndex -eq 3){
        try{$candidate=Read-Editor;$reviewText.Text="Pinned USB: $($candidate.Config.BackupDisk.FriendlyName)`r`nSerial: $($candidate.Config.BackupDisk.SerialNumber)`r`nSources: $($candidate.Sources.Count) | Task: $($candidate.Config.TaskName) | Daily: $($candidate.Config.ScheduleTime)`r`nAccount: $($candidate.Config.TaskUser) | Logon: $($candidate.Config.TaskLogonType)`r`nCanary SHA256: $($candidate.Config.Canary.ExpectedSha256)`r`n`r`n"+(@($candidate.Sources|ForEach-Object{"$($_.Name): previous versions=$($_.PreviousVersions); deleted days=$($_.DeletedRetentionDays); mirror deletes=$($_.MirrorDeletes)"})-join "`r`n")}catch{Show-Error $_.Exception.Message}
    }
})
$script:explicitExit=$false
$notify=New-Object Windows.Forms.NotifyIcon
$notify.Icon=$form.Icon;$notify.Text='Offline Backup Guard: Unknown'
$trayMenu=New-Object Windows.Forms.ContextMenuStrip
$trayStatus=New-Object Windows.Forms.ToolStripMenuItem('Unknown');$trayStatus.Enabled=$false
[void]$trayMenu.Items.Add($trayStatus)
$showItem=New-Object Windows.Forms.ToolStripMenuItem('Open Offline Backup Guard');$showItem.Add_Click({Show-DesktopWindow});[void]$trayMenu.Items.Add($showItem)
$pendingItem=New-Object Windows.Forms.ToolStripMenuItem('Deferred files');$pendingItem.Add_Click({$tabs.SelectedTab=$deferredPage;Show-DesktopWindow});[void]$trayMenu.Items.Add($pendingItem)
$refreshItem=New-Object Windows.Forms.ToolStripMenuItem('Refresh recorded status');$refreshItem.Add_Click({if(-not $script:busy -and $script:loadedPath){Start-Status -Passive}});[void]$trayMenu.Items.Add($refreshItem)
[void]$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$exitItem=New-Object Windows.Forms.ToolStripMenuItem('Exit');$exitItem.Add_Click({$script:explicitExit=$true;$form.Close()});[void]$trayMenu.Items.Add($exitItem)
$notify.ContextMenuStrip=$trayMenu;$notify.Add_DoubleClick({Show-DesktopWindow});$notify.Visible=$true
Set-TrayHealth 'Unknown'
$statusTimer=New-Object Windows.Forms.Timer;$statusTimer.Interval=30000
$statusTimer.Add_Tick({if(-not $script:busy -and $script:loadedPath){Start-Status -Passive}})
$form.Add_FormClosing({param($sender,$eventArgs)
    $action=Get-GuardCloseAction ([string]$eventArgs.CloseReason) $script:explicitExit ([bool]$script:busy)
    if($action -eq 'Hide'){$eventArgs.Cancel=$true;$form.Hide();return}
    if($action -eq 'Wait'){$eventArgs.Cancel=$true;$script:explicitExit=$false;Show-Error 'An operation is active. Wait for it to finish; no worker will be stopped.';return}
    if($eventArgs.CloseReason -eq 'UserClosing' -and -not $SmokeTest -and $script:dirty -and -not (Confirm-Action 'Exit and discard unsaved changes?')){$eventArgs.Cancel=$true;$script:explicitExit=$false}
})
Set-Editor $script:config @() $ConfigPath

if($SmokeTest){
    $mock=New-GuardSetupConfiguration $ConfigPath -TaskUser 'EXAMPLE\backup-operator'
    $mock.BackupDisk.FriendlyName='Example dedicated USB'; $mock.BackupDisk.SerialNumber='SYNTHETIC-USB-001'; $mock.ReadyForUse=$true
    $one=New-GuardSetupSource; $one.Name='Example documents'; $one.SourcePath='C:\ExampleData\Documents'; $one.DestinationSubfolder='documents'
    $many=New-GuardSetupSource; $many.Name='Example shared files'; $many.SourcePath='\\fileserver.example.invalid\research'; $many.DestinationSubfolder='research'; $many.PreviousVersions=5
    $zero=New-GuardSetupSource; $zero.Name='Example exports'; $zero.SourcePath='C:\ExampleData\Exports'; $zero.DestinationSubfolder='exports'; $zero.PreviousVersions=0
    Set-Editor $mock @($one,$many,$zero) $ConfigPath
    $script:diskRows=@([pscustomobject]@{Number=9;FriendlyName=$mock.BackupDisk.FriendlyName;SerialNumber=$mock.BackupDisk.SerialNumber;SizeGB=500;IsOffline=$true;IsBoot=$false;IsSystem=$false})
    $index=$diskGrid.Rows.Add(); foreach($column in $diskGrid.Columns){$diskGrid.Rows[$index].Cells[$column.Name].Value=[string]$script:diskRows[0].($column.Name)}
    $history=@([pscustomobject]@{started_at='2026-01-05T02:00:00';finished_at='2026-01-05T02:03:00';status='Failed';phase='Source copy';offline=$true;error='Example source unavailable; access denied.';log_path='C:\ExamplePrivate\backup-diagnostics\run.log';robocopy_log_path='C:\ExamplePrivate\logs\copy.log'},[pscustomobject]@{started_at='2026-01-04T02:00:00';finished_at='2026-01-04T02:20:00';status='Warning';phase='Offline';offline=$true;error='Example locked file deferred.'})
    Set-StatusView ([pscustomobject]@{Status=[pscustomobject]@{State='Needs attention';LastAttempt=$history[0].started_at;LastSuccess='2026-01-03T02:20:00';NextRun='2026-01-06T02:00:00';ConsecutiveFailures=2;ProblemSince='2026-01-04T02:00:00';Problem=$history[0].error;TaskState='Ready';LastTaskResult=1;Overdue=$false;Drift=@('Example task account differs');History=$history;Active=$null;LogRoot='C:\ExamplePrivate\backup-diagnostics';Storage=[pscustomobject]@{measured_at='2026-01-03T02:19:00';capacity_bytes=500GB;used_bytes=320GB;free_bytes=180GB;stale=$true}};Restore=$null})
    $script:lastStatus | Add-Member -NotePropertyName StorageHistory -NotePropertyValue @($script:lastStatus.Storage)
    $script:lastStatus | Add-Member -NotePropertyName ConsecutiveWarnings -NotePropertyValue 1
    $history[0] | Add-Member -NotePropertyName sources -NotePropertyValue @([pscustomobject]@{name='Example documents';success=$false;archived_files=3;locked_at_preflight=1;pruned_files=0;error='Example source unavailable'})
    Set-StatusView ([pscustomobject]@{Status=$script:lastStatus;Restore=$null})
    $entry=[pscustomobject]@{SourceName='Example documents';RelativePath='analysis\measurements.csv';Reason='File is locked by another process';ErrorCode=32;ConsecutiveRuns=6;FirstSeen='2026-01-01T02:00:00';LastSeen='2026-01-06T02:00:00'}
    $script:lastStatus | Add-Member -NotePropertyName Deferred -NotePropertyValue ([pscustomobject]@{Valid=$true;Count=1;OverdueCount=0;WarningAfterRuns=7;Entries=@($entry)})
    $script:lastStatus.State='Succeeded'
    Set-StatusView ([pscustomobject]@{Status=$script:lastStatus;Restore=$null})
    if($deferredPage.Text -ne 'Deferred files (1)' -or $deferredGrid.Rows.Count -ne 1 -or $statusHeading.ForeColor -ne [Drawing.Color]::FromArgb(26,110,67)){throw 'Pending file count or green status not rendered.'}
    $entry.ConsecutiveRuns=7;$script:lastStatus.Deferred.OverdueCount=1;$script:lastStatus.State='Warning'
    $script:lastStatus.Drift=@();$script:lastStatus.ConsecutiveFailures=0;$script:lastStatus.LastTaskResult=0
    $script:lastStatus.Problem='One individual file has remained pending for seven affected runs.'
    $script:lastStatus.LastAttempt='2026-01-06T02:00:00';$script:lastStatus.LastSuccess='2026-01-06T02:20:00'
    $history[0].status='Warning';$history[0].phase='Offline';$history[0].error='';$history[0].started_at='2026-01-06T02:00:00';$history[0].finished_at='2026-01-06T02:20:00'
    $script:lastStatus.Storage.measured_at='2026-01-06T02:19:00';$script:lastStatus.Storage.stale=$false
    Set-StatusView ([pscustomobject]@{Status=$script:lastStatus;Restore=$null})
    if($statusHeading.ForeColor -ne [Drawing.Color]::DarkGoldenrod -or $deferredDetail.Text -notmatch 'measurements.csv'){throw 'Seven-run warning or full file details not rendered.'}
    if((Read-Editor).Config.DeferredWarningAfterRuns -ne 7){throw 'Deferred threshold did not round trip through the editor.'}
    $outputBox.Text='SYNTHETIC SMOKE DATA. No disk enumeration, mount, runner invocation, task change or configuration write.'
    $activity.Text='Smoke test: rendered controls with synthetic data only.'
    if(-not $ScreenshotPath){$ScreenshotPath=Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-smoke-'+[guid]::NewGuid().ToString('N')+'.png')}
    $ScreenshotPath=[IO.Path]::GetFullPath($ScreenshotPath)
    if(-not (Test-Path -LiteralPath (Split-Path $ScreenshotPath -Parent) -PathType Container)){throw 'Screenshot parent directory must already exist.'}
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    foreach($index in @(0,1,2,3,4,5)){
        $tabs.SelectedIndex=$index; $form.Refresh(); [Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try{
            $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
            $path=if($index -eq 4){$ScreenshotPath}else{[IO.Path]::ChangeExtension($ScreenshotPath, "tab$index.png")}
            $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png); Write-Output "Smoke screenshot: $path"
        }finally{$bitmap.Dispose()}
    }
    $before=(Read-Editor|ConvertTo-Json -Depth 12 -Compress);$script:dirty=$true
    $trayMenu.Show($form,(New-Object Drawing.Point(30,60)));[Windows.Forms.Application]::DoEvents()
    $trayBitmap=New-Object Drawing.Bitmap($trayMenu.Width,$trayMenu.Height)
    try{$trayMenu.DrawToBitmap($trayBitmap,(New-Object Drawing.Rectangle(0,0,$trayMenu.Width,$trayMenu.Height)));$trayBitmap.Save(([IO.Path]::ChangeExtension($ScreenshotPath,'tray.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$trayBitmap.Dispose();$trayMenu.Hide()}
    $form.Close();[Windows.Forms.Application]::DoEvents()
    if($form.IsDisposed -or $form.Visible -or -not $notify.Visible){throw 'Window close did not hide to tray.'}
    Show-DesktopWindow
    Set-StatusView ([pscustomobject]@{Status=$script:lastStatus;Restore=$null})
    if(-not $script:dirty -or (Read-Editor|ConvertTo-Json -Depth 12 -Compress) -cne $before){throw 'Hide/focus/status changed the unsaved editor.'}
    $script:explicitExit=$true;$form.Close();[Windows.Forms.Application]::DoEvents()
    if(-not $form.IsDisposed){throw 'Explicit exit did not dispose the editor.'}
    $notify.Visible=$false;$notify.Dispose();$trayMenu.Dispose();$statusTimer.Dispose()
    $form.Dispose();$timer.Dispose();$tooltips.Dispose()
    foreach($icon in $script:desktopIcons.Values){$icon.Dispose()}
    Write-Output 'PASS actual form hide, focus, unsaved status refresh and explicit exit lifecycle'
    exit 0
}
$form.Add_Shown({
    $timer.Start()
    $statusTimer.Start()
    if($Tray){[void]$form.BeginInvoke([Action]{$form.Hide()})}
    if(Test-Path -LiteralPath $ConfigPath -PathType Leaf){Start-UiOperation 'Load' @{ConfigPath=$ConfigPath}}
})
try{[Windows.Forms.Application]::Run($form)}finally{
    $notify.Visible=$false;$notify.Dispose();$trayMenu.Dispose();$statusTimer.Stop();$statusTimer.Dispose()
    $timer.Stop();$timer.Dispose();$tooltips.Dispose();$form.Dispose()
    foreach($icon in $script:desktopIcons.Values){$icon.Dispose()}
    if($script:desktopSession){$script:desktopSession.Event.Dispose();if($script:desktopSession.Mutex){$script:desktopSession.Mutex.ReleaseMutex();$script:desktopSession.Mutex.Dispose()}}
    if($script:sessionDirectory -and -not $script:busy){
        $resolved=[IO.Path]::GetFullPath($script:sessionDirectory)
        $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^backup-guard-ui-[a-f0-9]{32}$') {Remove-Item -LiteralPath $resolved -Recurse -Force}
    }
}
