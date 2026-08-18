function Backup-Printers {
    # Capture printers using the least-privileged supported path first.  PrintBRM
    # is an optional elevated fallback because it can include drivers and local
    # queues that ordinary Add-Printer connections cannot recreate.
    param(
        [string]$DestinationBase
    )

    Write-Section "Backing up printers"

    $printerFolder = Join-Path $DestinationBase "Printers"
    $connectionsJson = Join-Path $printerFolder "PrinterConnections.json"
    $exportFile    = Join-Path $printerFolder "Printers.printerExport"
    $brmLog        = Join-Path $DestinationBase "Logs\printbrm_backup.log"

    # A 32-bit PowerShell host is redirected from System32 to SysWOW64.  Use
    # Sysnative first in that case so we always call the native PrintBRM tool.
    $printBrmCandidates = @()
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $printBrmCandidates += (Join-Path $env:WINDIR "Sysnative\spool\tools\PrintBrm.exe")
    }
    $printBrmCandidates += (Join-Path $env:WINDIR "System32\spool\tools\PrintBrm.exe")
    $printBrmPath = $printBrmCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    foreach ($p in @($printerFolder, (Split-Path $brmLog))) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }

    # Virtual/built-in printers we never want to carry over
    $virtualPrinters = @(
        "Microsoft Print to PDF", "Microsoft XPS Document Writer",
        "OneNote", "OneNote (Desktop)", "OneNote for Windows 10",
        "Fax", "Send To OneNote 2016", "Adobe PDF"
    )

    # ---- PRIMARY (non-admin): capture the user's network printer connections ----
    # These are \\server\printer connections stored per-user (HKCU\Printers\
    # Connections). Enumerating and re-adding them needs NO admin, as long as the
    # driver is staged or v4 on the new machine.
    $allPrinters = @(Get-Printer -ErrorAction SilentlyContinue)
    $connections = @($allPrinters | Where-Object {
        ($_.Type -eq 'Connection' -or $_.Name -like '\\*') -and
        ($virtualPrinters -notcontains $_.Name)
    })

    # Default printer (best-effort, works non-admin via CIM)
    $defaultPrinter = $null
    try {
        $defaultPrinter = (Get-CimInstance -ClassName Win32_Printer -Filter "Default = True" -ErrorAction SilentlyContinue).Name
    } catch { }

    $connData = @{
        CapturedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        DefaultPrinter = $defaultPrinter
        Connections = @($connections | ForEach-Object {
            @{ Name = $_.Name; ConnectionName = $_.Name }
        })
    }
    $connData | ConvertTo-Json -Depth 4 | Out-File $connectionsJson -Encoding UTF8

    if ($connections.Count -gt 0) {
        Write-Log "Captured $($connections.Count) network printer connection(s)" -Level Success
        Write-Status "Network printers" "OK" "$($connections.Count) connection(s), no admin needed"
        Add-Result -Category "Printers" -Item "Network Connections" -Status "Success" -Details "$($connections.Count) connection(s) captured"
    }
    else {
        Write-Log "No network printer connections found" -Level Info
        Write-Status "Network printers" "INFO" "none found"
        Add-Result -Category "Printers" -Item "Network Connections" -Status "Skipped" -Details "None found"
    }
    if ($defaultPrinter) {
        Write-KeyValue "Default printer" $defaultPrinter
    }

    # ---- PrintBRM package ----
    # PrintBRM is the only source of a real .printerExport migration file.  Do
    # not limit it to local printers: a package can also contain network queues,
    # and users expect this artifact even when the JSON connection list is enough
    # for a driverless restore.  Windows may reject the backup from a non-elevated
    # session; we still attempt it and retain the tool output in the log.
    $localPrinters = @($allPrinters | Where-Object {
        $_.Type -eq 'Local' -and $_.Name -notlike '\\*' -and
        ($virtualPrinters -notcontains $_.Name)
    })

    if ($localPrinters.Count -gt 0) {
        Write-Host "    $($Script:Theme.Glyphs.INFO) " -ForegroundColor Cyan -NoNewline
        Write-Host "$($localPrinters.Count) local/direct-IP printer(s) detected" -ForegroundColor White
    }

    if (-not $printBrmPath) {
        Write-Status "Printer migration file" "SKIP" "PrintBRM.exe not present"
        Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Skipped" -Details "PrintBRM.exe not found"
        Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $false -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Unavailable -Detail 'PrintBRM.exe was not found on the export computer.'
        return
    }

    try {
        # Do not let a stale file be mistaken for the result of this run.
        if (Test-Path -LiteralPath $exportFile) {
            Remove-Item -LiteralPath $exportFile -Force -ErrorAction Stop
        }

        $brmArgs = @("-B", "-F", $exportFile)
        if (-not $Script:Config.IncludePrinterDrivers) { $brmArgs += "-NOBIN" }
        $accessMode = if ($Script:IsAdmin) { "elevated" } else { "standard-user attempt" }
        Write-Host "    $($Script:Theme.Glyphs.INFO) Creating printer migration file (PrintBRM, $accessMode)" -ForegroundColor DarkGray
        & $printBrmPath @brmArgs *>&1 | Tee-Object -FilePath $brmLog | Out-Null
        $brmExit = $LASTEXITCODE

        if ((Test-Path $exportFile) -and ((Get-Item $exportFile).Length -gt 0)) {
            $file = Get-Item $exportFile
            Write-Log "Printer migration file created ($(Format-FileSize $file.Length)); PrintBRM exit $brmExit" -Level Success
            Write-Status "Printer migration file" "OK" "$(Format-FileSize $file.Length) (PrintBRM)"
            Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Success" -Details "$(Format-FileSize $file.Length), drivers=$($Script:Config.IncludePrinterDrivers), exit=$brmExit"
            $accessMode = if ($Script:IsAdmin) { 'administrator' } else { 'standard-user' }
            Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Succeeded -Detail "PrintBRM package created by the $accessMode export (exit $brmExit)."
        }
        else {
            $elevationHint = if ($Script:IsAdmin) { "" } else { "; Windows commonly requires an elevated session" }
            $failureDetail = "PrintBRM did not create Printers.printerExport during the $(if ($Script:IsAdmin) { 'administrator' } else { 'standard-user' }) attempt (exit $brmExit)$elevationHint."
            Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Failed -Detail $failureDetail
            if ($Script:IsAdmin) {
                Write-Log $failureDetail -Level Warning
                Write-Status "Printer migration file" "WARN" "not created (exit $brmExit)"
                Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Warning" -Details "Exit $brmExit; see printbrm_backup.log"
            }
            else {
                # The default path deliberately allows this attempt to fail
                # without turning an optional UAC choice into a handoff error.
                Write-Log "$failureDetail Administrator export is recommended but optional." -Level Info
                Write-Status "Printer migration file" "INFO" "standard-user attempt did not create it; admin is recommended"
                Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Skipped" -Details "Standard-user attempt did not create the package (exit $brmExit). Administrator export is recommended, optional; see printbrm_backup.log"
            }
        }
    }
    catch {
        Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Failed -Detail "PrintBRM attempt failed: $($_.Exception.Message)"
        if ($Script:IsAdmin) {
            Write-Status "Local printers" "FAIL" $_.Exception.Message
            Add-Result -Category "Printers" -Item "Local Printers" -Status "Error" -Details $_.Exception.Message
        }
        else {
            Write-Status "Local printers" "INFO" "standard-user attempt did not complete; admin is recommended"
            Add-Result -Category "Printers" -Item "Local Printers" -Status "Skipped" -Details "Standard-user PrintBRM attempt did not complete. Administrator export is recommended, optional; see printbrm_backup.log"
            Write-Log "Standard-user PrintBRM attempt did not complete: $($_.Exception.Message)" -Level Info
        }
    }
}

function Test-UacElevationCancelled {
    # ERROR_CANCELLED (1223) is the stable Windows signal even when the UAC
    # dialog's localized text does not contain an English "cancel" message.
    param([System.Exception]$Exception)

    if (-not $Exception) { return $false }
    if ($Exception.Message -match '(?i)cancel|denied|aborted') { return $true }
    try { return (($Exception.HResult -band 0xFFFF) -eq 1223) }
    catch { return $false }
}

function Start-ElevatedSystemExport {
    param([string]$DestinationBase)

    $capturePower = [bool]$Script:Config.Backup.SystemSettings
    $capturePrinters = [bool]$Script:Config.Backup.Printers
    if ($Script:IsAdmin -or -not $Script:Config.Export.RequestAdministratorPrivileges -or (-not $capturePower -and -not $capturePrinters)) { return }

    # UAC receives only a completed package path. The helper has no access to
    # user-data capture routines, so profile-scoped data remains normal-user.
    $logsPath = Join-Path $DestinationBase 'Logs'
    if (-not (Test-Path -LiteralPath $logsPath)) { New-Item -ItemType Directory -Path $logsPath -Force | Out-Null }
    $helperPath = Join-Path $logsPath 'Export-SystemSettings.elevated.ps1'
    $helperScript = @'
#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [bool]$CapturePower = $true,
    [bool]$CapturePrinters = $true
)
$ErrorActionPreference = 'Continue'
$logsPath = Join-Path $PackagePath 'Logs'
$settingsPath = Join-Path $PackagePath 'Settings'
$printersPath = Join-Path $PackagePath 'Printers'
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
$logPath = Join-Path $logsPath 'AdminExportLog.txt'
function Write-Audit([string]$Message) { Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" }
function Save-JsonAtomically([string]$Path, [object]$Data) {
    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $temporaryPath = Join-Path $folder (".$([IO.Path]::GetFileName($Path)).$PID.$([guid]::NewGuid().ToString('N')).tmp")
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Data | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            try { [IO.File]::Replace($temporaryPath, $Path, $null) }
            catch {
                [IO.File]::Copy($temporaryPath, $Path, $true)
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
        else { [IO.File]::Move($temporaryPath, $Path) }
    }
    finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}
function Publish-Artifact([string]$TemporaryPath, [string]$FinalPath) {
    if (-not (Test-Path -LiteralPath $FinalPath)) {
        [IO.File]::Move($TemporaryPath, $FinalPath)
        return
    }
    $backupPath = "$FinalPath.preElevated.$PID.bak"
    try {
        [IO.File]::Replace($TemporaryPath, $FinalPath, $backupPath, $true)
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Keep the original package until the replacement is ready. If a
        # redirected drive does not support File.Replace, restore it on any
        # move failure rather than leaving no printer/power artifact behind.
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $FinalPath -Destination $backupPath -ErrorAction Stop
        try {
            Move-Item -LiteralPath $TemporaryPath -Destination $FinalPath -ErrorAction Stop
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        catch {
            if (-not (Test-Path -LiteralPath $FinalPath) -and (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $FinalPath -ErrorAction SilentlyContinue
            }
            throw
        }
    }
}
function New-ProvenanceEntry([bool]$Attempted, [bool]$CapturedWithAdministratorRights, [string]$Status, [string]$Detail) {
    return [PSCustomObject]@{
        Attempted = $Attempted
        CapturedWithAdministratorRights = $CapturedWithAdministratorRights
        Status = $Status
        Detail = $Detail
        UpdatedAt = (Get-Date).ToString('o')
    }
}
function Update-Provenance([ValidateSet('Power', 'PrintBrm')][string]$Artifact, [bool]$Attempted, [string]$Status, [string]$Detail) {
    try {
        $provenancePath = Join-Path $settingsPath 'SystemExport.json'
        $provenance = $null
        if (Test-Path -LiteralPath $provenancePath) {
            try { $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json } catch { Write-Audit "Existing system-export provenance could not be read: $($_.Exception.Message)" }
        }
        if (-not $provenance) {
            $provenance = [PSCustomObject]@{
                SchemaVersion = 1; AdminExportRequested = $true; MainExporterWasAdministrator = $false; UpdatedAt = (Get-Date).ToString('o')
                Power = New-ProvenanceEntry $false $false 'NotAttempted' 'No full power-plan export was attempted.'
                PrintBrm = New-ProvenanceEntry $false $false 'NotAttempted' 'No PrintBRM export was attempted.'
            }
        }
        foreach ($property in @(
            @{ Name = 'SchemaVersion'; Value = 1 },
            @{ Name = 'AdminExportRequested'; Value = $true },
            @{ Name = 'MainExporterWasAdministrator'; Value = $false },
            @{ Name = 'UpdatedAt'; Value = (Get-Date).ToString('o') }
        )) {
            if (-not $provenance.PSObject.Properties[$property.Name]) { $provenance | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
        }
        if (-not $provenance.PSObject.Properties[$Artifact]) {
            $provenance | Add-Member -NotePropertyName $Artifact -NotePropertyValue (New-ProvenanceEntry $false $false 'NotAttempted' "No $Artifact export was attempted.")
        }
        $provenance.AdminExportRequested = $true
        $provenance.UpdatedAt = (Get-Date).ToString('o')
        $provenance.$Artifact = New-ProvenanceEntry $Attempted $true $Status $Detail
        Save-JsonAtomically -Path $provenancePath -Data $provenance
    }
    catch { Write-Audit "Could not update $Artifact provenance: $($_.Exception.Message)" }
}

$resultPath = Join-Path $logsPath 'AdminExportResult.json'
$result = [ordered]@{
    StartedAt = (Get-Date).ToString('o')
    CompletedAt = $null
    Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Power = [ordered]@{ Requested = $CapturePower; Attempted = $false; Status = 'Skipped'; Detail = 'Not selected for elevated export.' }
    PrintBrm = [ordered]@{ Requested = $CapturePrinters; Attempted = $false; Status = 'Skipped'; Detail = 'Not selected for elevated export.' }
}

if (-not $result.Elevated) {
    $result.Power.Status = 'Denied'; $result.PrintBrm.Status = 'Denied'
    $result.Power.Detail = 'Administrator privileges were not available.'; $result.PrintBrm.Detail = 'Administrator privileges were not available.'
    $result.CompletedAt = (Get-Date).ToString('o')
    Save-JsonAtomically -Path $resultPath -Data ([PSCustomObject]$result)
    Write-Audit 'Administrator helper started without elevation; no artifacts were changed.'
    exit 1
}

if ($CapturePower) {
    $result.Power.Attempted = $true
    $temporaryPowerFile = $null
    try {
        $settingsFile = Join-Path $settingsPath 'SystemSettings.json'
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        if ($settings.PowerScheme -notmatch '([0-9a-fA-F-]{36})') { throw 'The active power-scheme GUID is missing from SystemSettings.json.' }
        $powerFile = Join-Path $settingsPath 'PowerScheme.pow'
        $temporaryPowerFile = Join-Path $settingsPath "PowerScheme.elevated.$PID.pow"
        Remove-Item -LiteralPath $temporaryPowerFile -Force -ErrorAction SilentlyContinue
        $powerOutput = & powercfg /export $temporaryPowerFile $matches[1] 2>&1
        $powerExitCode = $LASTEXITCODE
        $powerOutput | Add-Content -LiteralPath $logPath
        if ($powerExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryPowerFile) -or (Get-Item -LiteralPath $temporaryPowerFile).Length -eq 0) { throw "powercfg /export failed (exit $powerExitCode)." }
        Publish-Artifact -TemporaryPath $temporaryPowerFile -FinalPath $powerFile
        $temporaryPowerFile = $null
        $result.Power.Status = 'Succeeded'; $result.Power.Detail = "Full power plan captured with administrator rights (exit $powerExitCode)."
        Update-Provenance -Artifact Power -Attempted $true -Status Succeeded -Detail $result.Power.Detail
        Write-Audit $result.Power.Detail
    }
    catch {
        $result.Power.Status = 'Failed'; $result.Power.Detail = "Elevated power export failed: $($_.Exception.Message)"
        Update-Provenance -Artifact Power -Attempted $true -Status Failed -Detail $result.Power.Detail
        Write-Audit $result.Power.Detail
    }
    finally { if ($temporaryPowerFile) { Remove-Item -LiteralPath $temporaryPowerFile -Force -ErrorAction SilentlyContinue } }
}

if ($CapturePrinters) {
    $result.PrintBrm.Attempted = $true
    $temporaryPrinterFile = $null
    try {
        $printBrmCandidates = @()
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $printBrmCandidates += (Join-Path $env:WINDIR 'Sysnative\spool\tools\PrintBrm.exe') }
        $printBrmCandidates += (Join-Path $env:WINDIR 'System32\spool\tools\PrintBrm.exe')
        $printBrm = $printBrmCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $printBrm) { throw 'PrintBRM.exe was not found.' }
        if (-not (Test-Path -LiteralPath $printersPath)) { New-Item -ItemType Directory -Path $printersPath -Force | Out-Null }
        $printerExport = Join-Path $printersPath 'Printers.printerExport'
        $temporaryPrinterFile = Join-Path $printersPath "Printers.elevated.$PID.printerExport"
        Remove-Item -LiteralPath $temporaryPrinterFile -Force -ErrorAction SilentlyContinue
        $arguments = @('-B', '-F', $temporaryPrinterFile)
        if (-not [bool]::Parse('{INCLUDE_DRIVERS}')) { $arguments += '-NOBIN' }
        & $printBrm @arguments 2>&1 | Tee-Object -LiteralPath (Join-Path $logsPath 'printbrm_backup_elevated.log') | Out-Null
        $printBrmExitCode = $LASTEXITCODE
        if ($printBrmExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryPrinterFile) -or (Get-Item -LiteralPath $temporaryPrinterFile).Length -eq 0) { throw "PrintBRM backup failed (exit $printBrmExitCode)." }
        Publish-Artifact -TemporaryPath $temporaryPrinterFile -FinalPath $printerExport
        $temporaryPrinterFile = $null
        $result.PrintBrm.Status = 'Succeeded'; $result.PrintBrm.Detail = "PrintBRM package captured with administrator rights (exit $printBrmExitCode)."
        Update-Provenance -Artifact PrintBrm -Attempted $true -Status Succeeded -Detail $result.PrintBrm.Detail
        Write-Audit $result.PrintBrm.Detail
    }
    catch {
        $result.PrintBrm.Status = 'Failed'; $result.PrintBrm.Detail = "Elevated PrintBRM export failed: $($_.Exception.Message)"
        Update-Provenance -Artifact PrintBrm -Attempted $true -Status Failed -Detail $result.PrintBrm.Detail
        Write-Audit $result.PrintBrm.Detail
    }
    finally { if ($temporaryPrinterFile) { Remove-Item -LiteralPath $temporaryPrinterFile -Force -ErrorAction SilentlyContinue } }
}

$result.CompletedAt = (Get-Date).ToString('o')
$failed = (($CapturePower -and $result.Power.Status -ne 'Succeeded') -or ($CapturePrinters -and $result.PrintBrm.Status -ne 'Succeeded'))
Save-JsonAtomically -Path $resultPath -Data ([PSCustomObject]$result)
Write-Audit (if ($failed) { 'Scoped administrator export completed with one or more failures.' } else { 'Scoped administrator export completed successfully.' })
exit $(if ($failed) { 1 } else { 0 })
'@
    $helperScript = $helperScript -replace '\{INCLUDE_DRIVERS\}', $Script:Config.IncludePrinterDrivers.ToString().ToLowerInvariant()
    $helperScript | Set-Content -LiteralPath $helperPath -Encoding UTF8
    try {
        $scopeLabel = switch ("$capturePower/$capturePrinters") { 'True/True' { 'PrintBRM and full power-plan capture' }; 'True/False' { 'full power-plan capture' }; default { 'PrintBRM capture' } }
        Write-Host "    Requesting administrator approval for $scopeLabel..." -ForegroundColor Cyan
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`" -PackagePath `"$DestinationBase`" -CapturePower:$($capturePower.ToString().ToLowerInvariant()) -CapturePrinters:$($capturePrinters.ToString().ToLowerInvariant())"
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $arguments -ErrorAction Stop
        if ($process.ExitCode -ne 0) { throw "Elevated helper exited with code $($process.ExitCode). Review Logs\\AdminExportLog.txt." }
        if ($capturePower) { Add-Result -Category 'Settings' -Item 'Power Scheme (elevated)' -Status 'Success' -Details 'Complete plan captured by scoped elevated helper' }
        if ($capturePrinters) {
            Add-Result -Category 'Printers' -Item 'Printer Migration File (elevated)' -Status 'Success' -Details 'Created by scoped elevated helper; see printbrm_backup_elevated.log'
            Write-Status 'Printer migration file' 'OK' 'created by elevated helper'
        }
        Write-Log "Scoped elevated $scopeLabel completed." -Level Success
    }
    catch {
        if (Test-UacElevationCancelled -Exception $_.Exception) {
            # The requested UAC retry did not run, but the normal user-context
            # export remains valid. Surface a real error without preventing the
            # remaining package artifacts, report, and import helpers from
            # being generated.
            $cancelledMessage = "Administrator printer and power export was enabled, but UAC elevation was cancelled. The export will continue with the standard-user artifacts."
            Write-Log "$cancelledMessage $($_.Exception.Message)" -Level Error
            Add-Result -Category 'System Export' -Item "Elevated $scopeLabel" -Status 'Error' -Details $cancelledMessage
            Write-Error -Message $cancelledMessage -ErrorAction Continue
        }
        else {
            Write-Log "Scoped elevated export did not complete: $($_.Exception.Message)" -Level Warning
            Add-Result -Category 'System Export' -Item "Elevated $scopeLabel" -Status 'Warning' -Details $_.Exception.Message
        }
    }
    finally { Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue }
}
