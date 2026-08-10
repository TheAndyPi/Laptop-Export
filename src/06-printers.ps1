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
        }
        else {
            $elevationHint = if ($Script:IsAdmin) { "" } else { "; Windows commonly requires an elevated session" }
            Write-Log "PrintBRM did not create Printers.printerExport (exit $brmExit)$elevationHint" -Level Warning
            Write-Status "Printer migration file" "WARN" "not created (exit $brmExit)"
            Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Warning" -Details "Exit $brmExit$elevationHint; see printbrm_backup.log"
            if (-not $Script:IsAdmin -and -not $Script:Config.Export.RequestAdministratorPrivileges) {
                Add-ManualTask -Task "Create PrintBRM printer migration file" -Reason "PrintBRM did not allow the standard-user export" -Instructions "Re-run Export-LaptopData.ps1 and select Y at the administrator prompt. The failed PrintBRM output is in Logs\\printbrm_backup.log."
            }
            elseif (-not $Script:IsAdmin) {
                Write-Log "PrintBRM will be retried by the scoped elevated helper after normal export capture finishes." -Level Info
            }
        }
    }
    catch {
        Write-Status "Local printers" "FAIL" $_.Exception.Message
        Add-Result -Category "Printers" -Item "Local Printers" -Status "Error" -Details $_.Exception.Message
    }
}

function Start-ElevatedSystemExport {
    param([string]$DestinationBase)

    if ($Script:IsAdmin -or -not $Script:Config.Export.RequestAdministratorPrivileges) { return }

    # UAC receives only a completed package path. The helper has no access to
    # user-data capture routines, so profile-scoped data remains normal-user.
    $logsPath = Join-Path $DestinationBase 'Logs'
    $helperPath = Join-Path $logsPath 'Export-SystemSettings.elevated.ps1'
    $helperScript = @'
#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$PackagePath)
$ErrorActionPreference = 'Continue'
$logsPath = Join-Path $PackagePath 'Logs'
$logPath = Join-Path $logsPath 'AdminExportLog.txt'
function Write-Audit([string]$Message) { Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" }
$failed = $false
$settingsFile = Join-Path $PackagePath 'Settings\SystemSettings.json'
try {
    $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    if ($settings.PowerScheme -match '([0-9a-fA-F-]{36})') {
        $powerFile = Join-Path $PackagePath 'Settings\PowerScheme.pow'
        if (Test-Path -LiteralPath $powerFile) { Remove-Item -LiteralPath $powerFile -Force }
        & powercfg /export $powerFile $matches[1] 2>&1 | Add-Content -LiteralPath $logPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $powerFile)) { throw "powercfg /export failed (exit $LASTEXITCODE)." }
        Write-Audit 'Full power plan exported.'
    }
} catch { $failed = $true; Write-Audit "Power export failed: $($_.Exception.Message)" }
try {
    $printBrm = Join-Path $env:WINDIR 'System32\spool\tools\PrintBrm.exe'
    if (-not (Test-Path -LiteralPath $printBrm)) { throw 'PrintBRM.exe was not found.' }
    $printerExport = Join-Path $PackagePath 'Printers\Printers.printerExport'
    if (Test-Path -LiteralPath $printerExport) { Remove-Item -LiteralPath $printerExport -Force }
    $arguments = @('-B', '-F', $printerExport)
    if (-not {INCLUDE_DRIVERS}) { $arguments += '-NOBIN' }
    & $printBrm @arguments 2>&1 | Tee-Object -LiteralPath (Join-Path $logsPath 'printbrm_backup_elevated.log') | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $printerExport) -or (Get-Item -LiteralPath $printerExport).Length -eq 0) { throw "PrintBRM backup failed (exit $LASTEXITCODE)." }
    Write-Audit 'PrintBRM package created.'
} catch { $failed = $true; Write-Audit "PrintBRM export failed: $($_.Exception.Message)" }
exit $(if ($failed) { 1 } else { 0 })
'@
    $helperScript = $helperScript -replace '\{INCLUDE_DRIVERS\}', $Script:Config.IncludePrinterDrivers.ToString().ToLowerInvariant()
    $helperScript | Set-Content -LiteralPath $helperPath -Encoding UTF8
    try {
        Write-Host '    Requesting administrator approval for PrintBRM and full power-plan capture...' -ForegroundColor Cyan
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`" -PackagePath `"$DestinationBase`"" -ErrorAction Stop
        if ($process.ExitCode -ne 0) { throw "Elevated helper exited with code $($process.ExitCode). Review Logs\\AdminExportLog.txt." }
        Add-Result -Category 'Settings' -Item 'Power Scheme (elevated)' -Status 'Success' -Details 'Complete plan captured by scoped elevated helper'
        Add-Result -Category 'Printers' -Item 'Printer Migration File (elevated)' -Status 'Success' -Details 'Created by scoped elevated helper; see printbrm_backup_elevated.log'
        Write-Status 'Printer migration file' 'OK' 'created by elevated helper'
        Write-Log 'Scoped elevated PrintBRM and power export completed.' -Level Success
    }
    catch {
        Write-Log "Scoped elevated export was cancelled or failed: $($_.Exception.Message)" -Level Warning
        Add-Result -Category 'System Export' -Item 'Elevated PrintBRM and power' -Status 'Warning' -Details $_.Exception.Message
        Add-ManualTask -Task 'Capture PrintBRM and full power plan' -Reason 'Scoped administrator helper did not complete' -Instructions 'Review Logs\\AdminExportLog.txt and rerun with administrator approval.'
    }
    finally { Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue }
}

