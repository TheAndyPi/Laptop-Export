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
    Clear-Host

    # Resolve transfer mode: honor -TransferMode param, else prompt.
    if ($TransferMode -in @("Local", "Online")) {
        $Script:Config.TransferMode = $TransferMode
    }
    else {
        Resolve-TransferMode
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
        return
    }

    # ---- Pre-scan + free-space check ----
    # Estimate what we're about to copy so we can (a) warn on insufficient space
    # and (b) show the operator the size up front. In online mode this reflects
    # the trimmed set (Downloads over cap and Lotus are excluded from the estimate).
    Write-Section "Estimating transfer size"
    $estBytes = 0
    foreach ($f in $Script:Config.UserFolders) {
        $fp = Join-Path $Script:OriginalUserProfile $f
        $fb = Get-FolderSizeBytes $fp
        if ($Script:Config.TransferMode -eq "Online" -and $f -eq "Downloads" -and
            ($fb / 1GB) -gt $Script:Config.Online.DownloadsCapGB) { continue }
        $estBytes += $fb
    }
    Write-KeyValue "Estimated size" (Format-FileSize $estBytes)

    try {
        $freeBytes = Get-DestinationFreeSpaceBytes -Path $destinationFolder
        if ($null -ne $freeBytes) {
            Write-KeyValue "Free at destination" (Format-FileSize $freeBytes)
        }
        # Online mode keeps the folder while creating a ZIP; Local mode keeps
        # only the folder, so it needs substantially less destination space.
        $spaceMultiplier = if ($Script:Config.TransferMode -eq "Online") { 2.15 } else { 1.15 }
        $requiredFreeBytes = [math]::Ceiling($estBytes * $spaceMultiplier)
        if ($freeBytes -gt 0 -and $freeBytes -lt $requiredFreeBytes) {
            Write-Host ""
            Write-Host "  $($Script:Theme.Glyphs.WARN) " -ForegroundColor Yellow -NoNewline
            $spaceDetail = if ($Script:Config.TransferMode -eq "Online") { "the package and its ZIP archive" } else { "the transfer package" }
            Write-Host "Destination may not have enough free space for $spaceDetail." -ForegroundColor White
            $go = Read-Host "    Continue anyway? (Y/N)"
            if ($go -notmatch "^[Yy]") { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
        }
    }
    catch {
        Write-Log "Could not read free space at $destinationFolder (continuing)" -Level Info
    }

    # Create transfer folder structure
    $transferBase = Join-Path $destinationFolder $Script:Config.TransferFolderName
    
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
    Copy-UserFolders -DestinationBase $transferBase
    
    # 2. Copy AppData
    Copy-AppData -DestinationBase $transferBase
    
    # 3. Capture system settings
    $settings = Get-SystemSettings -DestinationBase $transferBase
    
    # 4. Document installed programs
    $programs = Get-InstalledPrograms -DestinationBase $transferBase
    
    # 5. Back up printers
    Backup-Printers -DestinationBase $transferBase

    # 6. Copy browser data
    Copy-BrowserData -DestinationBase $transferBase
    
    # 7. Check OneDrive
    Set-OneDriveLocalSync
    
    # 8. Generate import script
    New-ImportScript -DestinationBase $transferBase -Settings $settings

    # 9. Generate HTML report
    $reportPath = New-TransferReport -DestinationBase $transferBase
    
    # 10. Generate quick import batch file
    New-QuickImportBatch -DestinationBase $transferBase

    # Save log
    $logPath = Join-Path $transferBase "Logs\ExportLog.txt"
    $Script:Log | Out-File $logPath -Encoding UTF8

    # Local transfers stay as folders for a removable drive. Online transfers
    # also produce a portable ZIP beside the package.
    $archivePath = $null
    if ($Script:Config.TransferMode -eq "Online") {
        $archivePath = New-TransferArchive -TransferBase $transferBase
    }
    
    # Summary
    $Script:Results.EndTime = Get-Date
    $dur = $Script:Results.EndTime - $Script:Results.StartTime
    $sc = ($Script:Results.Actions | Where-Object { $_.Status -eq "Success" }).Count
    $wc = ($Script:Results.Actions | Where-Object { $_.Status -match "Warning|Manual" }).Count
    $ec = ($Script:Results.Actions | Where-Object { $_.Status -match "Error|NOT EXPORTED" }).Count
    $kc = ($Script:Results.Actions | Where-Object { $_.Status -eq "Skipped" }).Count

    Write-Banner -Title "Export Complete"
    Write-SummaryCard -Success $sc -Warning $wc -Errors $ec -Skipped $kc -Duration "$([math]::Round($dur.TotalMinutes, 1)) min"

    Write-KeyValue "Package" $transferBase
    if ($archivePath) { Write-KeyValue "ZIP archive" $archivePath }
    Write-Section "Package contents"
    Write-Status "UserData"               "INFO" "Documents, Desktop, loose files"
    Write-Status "AppData"                "INFO" "Bluebeam, signatures, Quick Access"
    Write-Status "Settings"               "INFO" "power, drives, personalization"
    Write-Status "Printers"               "INFO" "PrintBRM package"
    Write-Status "BrowserData"            "INFO" "bookmarks"
    Write-Status "Import-LaptopData.ps1"  "OK"   "run on new machine"
    Write-Status "QuickImport.bat"        "OK"   "double-click (choose admin or standard)"
    Write-Status "TransferReport.html"    "OK"   "full report"
    if ($archivePath) {
        Write-Status "$(Split-Path -Path $archivePath -Leaf)" "OK" "portable compressed package"
    }

    # Open report
    Write-Host ""
    Write-Host "  Opening transfer report..." -ForegroundColor DarkGray
    if ($reportPath -and (Test-Path $reportPath)) { Start-Process $reportPath }
    
    Write-Host ""
    Read-Host "  Press Enter to exit"
}

# Run the export
Start-LaptopExport
