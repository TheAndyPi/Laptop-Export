function New-QuickImportBatch {
    param(
        [string]$DestinationBase
    )

    $batPath = Join-Path $DestinationBase "QuickImport.bat"

    # Let the technician choose once: run normally for user-scoped data, or
    # request elevation when power settings and local printer drivers matter.
    $batContent = @"
@echo off
title STO Laptop Transfer - Quick Import

echo.
echo ============================================
echo    STO Laptop Transfer - Quick Import
echo ============================================
echo.
if /I "%~1"=="--elevated" goto :Elevated

set /p RUN_AS_ADMIN="Run with administrator rights? (Y/N) [N]: "
echo.

if /I "%RUN_AS_ADMIN%"=="Y" (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '--elevated'"
    exit /b
) else (
    echo Running import script as the current user...
    echo Admin-only restore steps will be skipped and listed in the report.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Import-LaptopData.ps1" -NoElevationPrompt
)
goto :Complete

:Elevated
echo Running import script with administrator rights...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Import-LaptopData.ps1"

:Complete
set IMPORT_EXIT=%errorlevel%

echo.
echo ============================================
if %IMPORT_EXIT% neq 0 (
    echo Import finished with exit code %IMPORT_EXIT%. Review messages above.
) else (
    echo Import complete.
)
echo Press any key to exit...
pause >nul
"@

    $batContent | Out-File $batPath -Encoding ASCII

    Write-Log "QuickImport.bat created" -Level Success
    Add-Result -Category "Scripts" -Item "QuickImport.bat" -Status "Success"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Start-LaptopExport {
    Clear-StoScreen

    # Resolve transfer mode: honor -TransferMode param, else prompt.
    if ($TransferMode -in @("Local", "Online")) {
        $Script:Config.TransferMode = $TransferMode
    }
    else {
        Resolve-TransferMode
    }

    Apply-OnlineImportDefaults
    if ($NonInteractive) {
        # Browsers can require a close/password-export prompt. Leave them out
        # of unattended validation runs rather than hanging partway through.
        $Script:Config.Backup.Chrome = $false
        $Script:Config.Backup.Firefox = $false
        $Script:Config.Backup.Edge = $false
        # PrintBRM and ZIP compression can outlive automation time limits; the
        # package and all generated artifacts are still exercised by validation
        # runs. Normal technician exports retain both stages.
        $Script:Config.Backup.Printers = $false
        $Script:Config.Online.CreateZipArchive = $false
        Write-Log "Non-interactive mode: browser collection, PrintBRM, and ZIP creation disabled" -Level Info
    }
    elseif (-not (Show-TransferSettingsMenu)) {
        Write-Host "`n  Transfer cancelled." -ForegroundColor Yellow
        return
    }

    # Online exports use the Windows folder picker. Local exports retain the
    # external/secondary-drive selector and do not open the picker.
    if ($Script:Config.TransferMode -eq "Local") {
        $destinationFolder = Select-TargetDrive
    }
    else {
        $destinationFolder = Select-TargetDestination
    }
    if (-not $destinationFolder) {
        Write-Host "`n  Export cancelled: no usable destination was selected. No files were copied." -ForegroundColor Yellow
        if (-not $NonInteractive) { Read-Host "  Press Enter to exit" }
        return
    }

    $createsZipArchive = $Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.CreateZipArchive
    $isNetworkDestination = $Script:Config.TransferMode -eq "Online" -and (Test-NetworkDestination -Path $destinationFolder)
    $useLocalStaging = $isNetworkDestination -and $createsZipArchive -and $Script:Config.Online.StageNetworkTransfersLocally
    $stagingAppData = if ($Script:OriginalAppDataLocal) { $Script:OriginalAppDataLocal } else { $env:LOCALAPPDATA }
    $stagingRoot = Join-Path $stagingAppData "STO Building Group\LaptopTransferStaging"
    $workingFolder = $destinationFolder
    if ($useLocalStaging) {
        try {
            New-Item -ItemType Directory -Path $stagingRoot -Force -ErrorAction Stop | Out-Null
            $workingFolder = $stagingRoot
            Write-Section "Network transfer staging"
            Write-KeyValue "Network destination" $destinationFolder
            Write-KeyValue "Local staging" $stagingRoot
            Write-Host "  Files will be collected and zipped locally before one ZIP is uploaded." -ForegroundColor DarkGray
        }
        catch {
            Write-Host "Could not create local staging folder '$stagingRoot': $_" -ForegroundColor Red
            return
        }
    }

    # ---- Pre-scan + free-space check ----
    # Estimate what we're about to copy so we can (a) warn on insufficient space
    # and (b) show the operator the size up front. In online mode this reflects
    # the trimmed set (Downloads over cap and Lotus are excluded from the estimate).
    Write-Section "Estimating transfer size"
    $payloadEstimate = Get-TransferPayloadEstimate
    $estBytes = $payloadEstimate.TotalBytes
    Write-KeyValue "Estimated size" (Format-FileSize $estBytes)
    if ($Script:Config.TransferMode -eq "Online") {
        Write-KeyValue "Online payload limit" "$($Script:Config.Online.MaxTransferGB) GB"
        if ($estBytes -gt ($Script:Config.Online.MaxTransferGB * 1GB)) {
            $message = "Selected Online payload ($(Format-FileSize $estBytes)) exceeds the $($Script:Config.Online.MaxTransferGB) GB limit."
            Write-Host ""; Write-Host "  $($Script:Theme.Glyphs.WARN) $message" -ForegroundColor Yellow
            if ($NonInteractive) { throw "Non-interactive export stopped because: $message" }
            $continueLargePayload = Read-Host "    Export anyway? (Y/N)"
            if ($continueLargePayload -notmatch "^[Yy]") { Write-Host "  Cancelled. No files were copied." -ForegroundColor Yellow; return }
        }
    }

    try {
        $freeBytes = Get-DestinationFreeSpaceBytes -Path $workingFolder
        $networkFreeBytes = if ($useLocalStaging) { Get-DestinationFreeSpaceBytes -Path $destinationFolder } else { $null }
    }
    catch {
        # A provider that cannot report capacity (some cloud folders, for
        # example) must not prevent an export. Only the query itself is
        # best-effort; warnings calculated below still control the flow.
        Write-Log "Could not read free space at $destinationFolder (continuing)" -Level Info
        $freeBytes = $null
        $networkFreeBytes = $null
    }

    if ($null -ne $freeBytes) {
        $freeLabel = if ($useLocalStaging) { "Free in local staging" } else { "Free at destination" }
        Write-KeyValue $freeLabel (Format-FileSize $freeBytes)
    }
    # Online mode needs extra space only when it will also create a ZIP.
    $spaceMultiplier = if ($createsZipArchive) { 2.15 } else { 1.15 }
    $requiredFreeBytes = [math]::Ceiling($estBytes * $spaceMultiplier)
    $spaceWarnings = @()
    if ($freeBytes -gt 0 -and $freeBytes -lt $requiredFreeBytes) {
        $spaceLocation = if ($useLocalStaging) { "local staging location" } else { "destination" }
        $spaceDetail = if ($createsZipArchive) { "the package and ZIP archive" } else { "the transfer package" }
        $spaceWarnings += "The $spaceLocation may not have enough space for $spaceDetail."
    }
    if ($useLocalStaging) {
        if ($null -ne $networkFreeBytes) {
            Write-KeyValue "Free at network destination" (Format-FileSize $networkFreeBytes)
        }
        if ($networkFreeBytes -gt 0 -and $networkFreeBytes -lt [math]::Ceiling($estBytes * 1.15)) {
            $spaceWarnings += "The network destination may not have enough space for the ZIP archive."
        }
    }
    if ($spaceWarnings.Count -gt 0) {
        if ($NonInteractive) {
            throw "Non-interactive export stopped because: $($spaceWarnings -join ' ')"
        }
        Write-Host ""
        Write-Host "  $($Script:Theme.Glyphs.WARN) " -ForegroundColor Yellow -NoNewline
        Write-Host ($spaceWarnings -join " ") -ForegroundColor White
        $go = Read-Host "    Continue anyway? (Y/N)"
        if ($go -notmatch "^[Yy]") { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    }

    # Create transfer folder structure
    $transferBase = Join-Path $workingFolder $Script:Config.TransferFolderName
    
    Write-KeyValue "Transfer folder" $transferBase
    
    $folders = @("UserData", "AppData", "Settings", "BrowserData", "Printers", "Logs")
    foreach ($folder in $folders) {
        $path = Join-Path $transferBase $folder
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    
    Write-Log "Transfer folder created at $transferBase" -Level Success
    
    # Execute export tasks
    Write-Banner -Title "Starting Export Process ($($Script:Config.TransferMode))"
    
    # 1. Copy user folders
    if ($Script:Config.Backup.UserData) {
        Copy-UserFolders -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "User data" -Category "User Folders" }
    
    # 2. Copy AppData
    if ($Script:Config.Backup.AppData) {
        Copy-AppData -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "AppData" }
    
    # 3. Capture system settings
    $settings = @{}
    if ($Script:Config.Backup.SystemSettings) {
        $settings = Get-SystemSettings -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "System settings" -Category "Settings" }
    
    # 4. Document installed programs
    if ($Script:Config.Backup.InstalledPrograms) {
        $programs = Get-InstalledPrograms -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "Installed programs" }
    
    # 5. Back up printers
    if ($Script:Config.Backup.Printers) {
        Backup-Printers -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "Printers" }

    # 6. Copy the independently selected browser data.
    Copy-BrowserData -DestinationBase $transferBase
    
    # 7. Check OneDrive
    if ($Script:Config.Backup.OneDrive) {
        Set-OneDriveLocalSync
    }
    else { Add-DisabledBackupResult -Item "OneDrive" }
    
    # 8. Generate import script
    New-ImportScript -DestinationBase $transferBase -Settings $settings

    # 9. Generate HTML report
    $reportPath = New-TransferReport -DestinationBase $transferBase
    
    # 10. Generate quick import batch file
    New-QuickImportBatch -DestinationBase $transferBase

    if ($Script:Config.TransferMode -eq "Online" -and -not $Script:Config.Online.CreateZipArchive) {
        Write-Log "ZIP archive creation disabled by configuration" -Level Info
        Add-Result -Category "Package" -Item "ZIP Archive" -Status "Skipped" -Details "Disabled by configuration"
    }

    # Local transfers stay as folders for a removable drive. Online transfers
    # also produce a portable ZIP beside the package.
    $archivePath = $null
    $publishedArchivePath = $null
    if ($Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.CreateZipArchive) {
        $archivePath = New-TransferArchive -TransferBase $transferBase
        if ($archivePath -and $useLocalStaging) {
            $uploadLog = Join-Path $transferBase "Logs\robocopy_network_zip_upload.log"
            $publishedArchivePath = Publish-TransferArchive -ArchivePath $archivePath -DestinationFolder $destinationFolder -LogPath $uploadLog
        }
    }
    
    # Summary
    $Script:Results.EndTime = Get-Date
    $dur = $Script:Results.EndTime - $Script:Results.StartTime
    $sc = ($Script:Results.Actions | Where-Object { $_.Status -eq "Success" }).Count
    $wc = ($Script:Results.Actions | Where-Object { $_.Status -match "Warning|Manual" }).Count
    $ec = @($Script:Results.Actions | Where-Object {
        $_.Status -eq "Error" -or $_.Status -like "NOT EXPORTED*"
    }).Count
    $kc = ($Script:Results.Actions | Where-Object { $_.Status -eq "Skipped" }).Count

    Write-Banner -Title "Export Complete"
    Write-SummaryCard -Success $sc -Warning $wc -Errors $ec -Skipped $kc -Duration "$([math]::Round($dur.TotalMinutes, 1)) min"

    $adminRequiredTasks = @($Script:Results.ManualTasks | Where-Object { $_.Reason -match "admin|Administrator|privileges" })
    if (-not $Script:IsAdmin -and $adminRequiredTasks.Count -gt 0) {
        Write-Host ""
        Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "  ! INCOMPLETE EXPORT: ADMIN-ONLY ITEMS WERE NOT CAPTURED !" -ForegroundColor Red
        Write-Host "  ! Re-run elevated before wiping the old laptop.          !" -ForegroundColor Red
        Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        foreach ($task in $adminRequiredTasks) {
            Write-Host "  $($Script:Theme.Glyphs.WARN) $($task.Task)" -ForegroundColor Yellow
        }
    }

    $packageLabel = if ($useLocalStaging) { "Local staging package" } else { "Package" }
    Write-KeyValue $packageLabel $transferBase
    if ($publishedArchivePath) { Write-KeyValue "Network ZIP" $publishedArchivePath }
    elseif ($archivePath) { Write-KeyValue "ZIP archive" $archivePath }
    Write-Section "Package contents"
    Write-Status "UserData"               "INFO" "Documents, Desktop, loose files"
    Write-Status "AppData"                "INFO" "Bluebeam, signatures, Quick Access"
    Write-Status "Settings"               "INFO" "power, drives, personalization"
    if ($Script:Config.Backup.Printers) {
        Write-Status "Printers" "INFO" "PrintBRM package"
    }
    else {
        Write-Status "Printers" "SKIP" "disabled by configuration"
    }
    if ($Script:Config.Backup.Chrome) { Write-Status "Chrome" "INFO" "selected" } else { Write-Status "Chrome" "SKIP" "disabled by configuration" }
    if ($Script:Config.Backup.Firefox) { Write-Status "Firefox" "INFO" "selected" } else { Write-Status "Firefox" "SKIP" "disabled by configuration" }
    if ($Script:Config.Backup.Edge) { Write-Status "Edge" "INFO" "selected" } else { Write-Status "Edge" "SKIP" "disabled by configuration" }
    Write-Status "Import-LaptopData.ps1"  "OK"   "run on new machine"
    Write-Status "QuickImport.bat"        "OK"   "double-click (choose admin or standard)"
    Write-Status "TransferReport.html"    "OK"   "full report"
    if ($publishedArchivePath) {
        Write-Status "$(Split-Path -Path $publishedArchivePath -Leaf)" "OK" "uploaded ZIP archive"
    }
    elseif ($archivePath) {
        Write-Status "$(Split-Path -Path $archivePath -Leaf)" "OK" "portable compressed package"
    }

    # Persist every event, including ZIP creation and any network upload.
    $logPath = Join-Path $transferBase "Logs\ExportLog.txt"
    $Script:Log | Out-File $logPath -Encoding UTF8

    # Open report only for an interactive technician run.
    Write-Host ""
    if ($NonInteractive) {
        Write-Host "  Report saved: $reportPath" -ForegroundColor DarkGray
    }
    elseif ($reportPath -and (Test-Path $reportPath)) {
        Write-Host "  Opening transfer report..." -ForegroundColor DarkGray
        Start-Process $reportPath
    }
    
    Write-Host ""
    if (-not $NonInteractive) { Read-Host "  Press Enter to exit" }
}

# Run the export
Start-LaptopExport
