# ============================================================================
# ADMIN ELEVATION
# ============================================================================

# Track if we have admin privileges
$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# If no target profile was passed, use current user's profile (we're not elevated yet, or user chose not to elevate)
if ([string]::IsNullOrEmpty($TargetUserProfile)) {
    $Script:OriginalUserProfile = $env:USERPROFILE
    $Script:OriginalUserName = $env:USERNAME
    $Script:OriginalAppDataRoaming = $env:APPDATA
    $Script:OriginalAppDataLocal = $env:LOCALAPPDATA
}
else {
    # Use the passed values (we're running elevated)
    $Script:OriginalUserProfile = $TargetUserProfile
    $Script:OriginalUserName = $TargetUserName
    $Script:OriginalAppDataRoaming = $TargetAppDataRoaming
    $Script:OriginalAppDataLocal = $TargetAppDataLocal
}

if (-not $Script:IsAdmin) {
    Write-Banner -Title "Administrator Privileges Recommended"
    Write-Host "  Some features (power scheme and a full PrintBRM package) require admin rights." -ForegroundColor Gray
    Write-Host "  PrintBRM is still attempted if you skip; its result is recorded in the package.`n" -ForegroundColor DarkGray
    
    $choice = Read-Host "  Run as Administrator? (Y/N, or S to skip)"
    
    if ($choice -eq "Y" -or $choice -eq "y") {
        Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
        $scriptPath = $MyInvocation.MyCommand.Path
        
        # Pass the current user's profile info to the elevated script
        $elevatedArgs = "-ExecutionPolicy Bypass -File `"$scriptPath`" -TargetUserProfile `"$env:USERPROFILE`" -TargetUserName `"$env:USERNAME`" -TargetAppDataRoaming `"$env:APPDATA`" -TargetAppDataLocal `"$env:LOCALAPPDATA`""
        if ($TransferMode) { $elevatedArgs += " -TransferMode `"$TransferMode`"" }
        if ($DestinationPath) { $elevatedArgs += " -DestinationPath `"$DestinationPath`"" }
        
        try {
            $process = Start-Process PowerShell -Verb RunAs -ArgumentList $elevatedArgs -PassThru -ErrorAction Stop
            # If we get here, elevation was accepted - exit this non-admin instance
            exit
        }
        catch {
            Write-Host "`nCould not elevate to administrator. Continuing without admin rights..." -ForegroundColor Yellow
            Write-Host "Admin-required tasks will be added to the manual checklist.`n" -ForegroundColor Gray
            Start-Sleep -Seconds 2
        }
    }
    else {
        Write-Host "`nContinuing without administrator privileges..." -ForegroundColor Yellow
        Write-Host "Some tasks will be added to the manual checklist.`n" -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
}

# ============================================================================
# CONFIGURATION
# ============================================================================

$Script:Config = @{
    Version = "0.7"
    TransferFolderName = "LaptopTransfer_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    # Printer driver binaries in the PrintBRM package. Network printers also
    # have a driverless, non-admin connection restore. TRUE bundles drivers
    # when PrintBRM is permitted to create the package; FALSE (-NOBIN) makes a
    # smaller package.
    IncludePrinterDrivers = $true
    
    # User profile folders to copy (relative to user profile)
    UserFolders = @(
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Videos",
        "Music",
        "Favorites"
    )
    
    # AppData paths to check/copy (relative to AppData\Roaming)
    AppDataRoaming = @{
        "Signatures" = "Microsoft\Signatures"
        "QuickAccess" = "Microsoft\Windows\Recent\AutomaticDestinations"
    }
    
    # AppData\Local paths to check/copy
    AppDataLocal = @{
        "Lotus" = "Lotus"
    }
    
    # Bluebeam can be in different locations - check these paths
    BluebeamPaths = @(
        "Bluebeam Software",
        "Bluebeam"
    )
    
    # Robocopy settings
    RobocopyArgs = @("/E", "/Z", "/R:2", "/W:3", "/MT:8", "/NP", "/NDL", "/NFL")

    # ---- Transfer mode ----
    # "Local"  = full copy (USB/on-site).  "Online" = trimmed for slow/remote links.
    # Resolved at runtime from the -TransferMode param or an interactive prompt.
    TransferMode = "Local"

    # Online-mode trimming rules (only applied when TransferMode = "Online")
    Online = @{
        # Downloads is usually one of the two largest folders. Cap it: if it
        # exceeds this size, omit it entirely (per IT guidance) and log a manual task.
        DownloadsCapGB   = 5
        # Lotus Notes local data is the other usual heavy hitter; omit by default.
        SkipLotusNotes   = $true
        # Any other user folder above this size prompts the tech (skip / copy anyway).
        LargeFolderPromptGB = 10
        # Skip the OneDrive force-hydration step (it would re-download everything
        # over the same constrained link).
        SkipOneDriveHydration = $true
    }

    # These switches are supplied by src\00-development-config.psd1 at build
    # time and remain embedded in the single deployment script.
    Backup = @{
        UserData          = $true
        AppData           = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        BrowserData       = $true
        OneDrive          = $true
    }
    Import = @{
        DeletePrintBrmAfterImport = $true
    }
}

# Apply only known Boolean development switches so invalid additions cannot
# unexpectedly change the behavior of a technician deployment.
foreach ($sectionName in @("Backup", "Import")) {
    if (-not ($Script:DevelopmentConfig -is [hashtable]) -or
        -not $Script:DevelopmentConfig.ContainsKey($sectionName) -or
        -not ($Script:DevelopmentConfig[$sectionName] -is [hashtable])) {
        continue
    }

    foreach ($switchName in $Script:Config[$sectionName].Keys) {
        if ($Script:DevelopmentConfig[$sectionName].ContainsKey($switchName) -and
            $Script:DevelopmentConfig[$sectionName][$switchName] -is [bool]) {
            $Script:Config[$sectionName][$switchName] = $Script:DevelopmentConfig[$sectionName][$switchName]
        }
    }
}

function Add-DisabledBackupResult {
    param(
        [string]$Item,
        [string]$Category = "Backup"
    )

    Write-Log "$Item backup disabled by development configuration" -Level Info
    Write-Status $Item "SKIP" "disabled by config"
    Add-Result -Category $Category -Item $Item -Status "Skipped" -Details "Disabled by development configuration"
}

# ============================================================================
# LOGGING & REPORTING
# ============================================================================

$Script:Log = [System.Collections.ArrayList]::new()
$Script:Results = @{
    StartTime = Get-Date
    EndTime = $null
    UserName = $Script:OriginalUserName
    ComputerName = $env:COMPUTERNAME
    Actions = [System.Collections.ArrayList]::new()
    Errors = [System.Collections.ArrayList]::new()
    Warnings = [System.Collections.ArrayList]::new()
    ManualTasks = [System.Collections.ArrayList]::new()
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = "[$timestamp][$Level] $Message"
    [void]$Script:Log.Add($logEntry)
    
    $color = switch ($Level) {
        "Info"    { "White" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    Write-Host $logEntry -ForegroundColor $color
}

function Add-Result {
    param(
        [string]$Category,
        [string]$Item,
        [string]$Status,
        [string]$Details = ""
    )
    
    $result = @{
        Category = $Category
        Item = $Item
        Status = $Status
        Details = $Details
        Timestamp = Get-Date -Format "HH:mm:ss"
    }
    
    [void]$Script:Results.Actions.Add($result)
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Copy-WithProgress {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$FolderName,
        [string]$LogPath,
        [array]$RobocopyArgs
    )
    
    # Get source size and file count
    $sourceFiles = Get-ChildItem $Source -Recurse -File -Force -ErrorAction SilentlyContinue
    $totalFiles = ($sourceFiles | Measure-Object).Count
    $totalSize = ($sourceFiles | Measure-Object -Property Length -Sum).Sum
    
    if ($totalFiles -eq 0) {
        return @{ ExitCode = 0; FilesCopied = 0; Status = "Empty" }
    }
    
    # Create destination if needed
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    
    Write-Host ""
    Write-Host "  $($Script:Theme.Glyphs.ARROW) " -ForegroundColor Cyan -NoNewline
    Write-Host $FolderName -ForegroundColor White -NoNewline
    Write-Host "  $(Format-FileSize $totalSize) / $totalFiles files" -ForegroundColor DarkGray
    
    $startTime = Get-Date
    $progressBarWidth = 34
    $lastPercent = -1
    $spinIndex = 0
    
    # Build full argument string for robocopy
    $robocopyArgString = ($RobocopyArgs -join " ")
    
    # Run robocopy as a background job to capture all output
    $robocopyScript = {
        param($src, $dst, $argString, $log)
        $fullArgs = "$argString /LOG:`"$log`""
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "robocopy.exe"
        $pinfo.Arguments = "`"$src`" `"$dst`" $fullArgs"
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pinfo
        $process.Start() | Out-Null
        $process.WaitForExit()
        return $process.ExitCode
    }
    
    $job = Start-Job -ScriptBlock $robocopyScript -ArgumentList $Source, $Destination, $robocopyArgString, $LogPath
    
    # Monitor progress while robocopy runs.
    # Poll less aggressively than before (recursive sizing of a large USB dest
    # every 500ms competes with the copy itself); spinner keeps it feeling live.
    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 750
        
        # Get current destination size
        $destFiles = Get-ChildItem $Destination -Recurse -File -Force -ErrorAction SilentlyContinue
        $copiedSize = ($destFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        $copiedFiles = ($destFiles | Measure-Object).Count
        
        if ($null -eq $copiedSize) { $copiedSize = 0 }
        
        # Calculate percentage
        $percent = if ($totalSize -gt 0) { [math]::Min(100, [math]::Round(($copiedSize / $totalSize) * 100)) } else { 0 }
        
        # Advance spinner + redraw every tick (spinner animates even when % is static)
        $spin = $Script:Theme.Spinner[$spinIndex % $Script:Theme.Spinner.Count]
        $spinIndex++
        $lastPercent = $percent
        
        # Build block-character progress bar
        $filledWidth = [math]::Round(($percent / 100) * $progressBarWidth)
        $emptyWidth = $progressBarWidth - $filledWidth
        $progressBar = ([string]$Script:Theme.Bar.Full * $filledWidth) + ([string]$Script:Theme.Bar.Light * $emptyWidth)
        
        # Calculate speed
        $elapsed = (Get-Date) - $startTime
        $speed = if ($elapsed.TotalSeconds -gt 0) { $copiedSize / $elapsed.TotalSeconds } else { 0 }
        
        # Build + write status line (carriage return to overwrite)
        $statusLine = "    $spin $progressBar $($percent.ToString().PadLeft(3))%  $(Format-FileSize $copiedSize) / $(Format-FileSize $totalSize)  $(Format-FileSize $speed)/s   "
        Write-Host "`r$statusLine" -NoNewline
    }
    
    # Get the exit code from the job
    $exitCode = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    
    # If exit code is null, check the log file for success indicators
    if ($null -eq $exitCode) { $exitCode = 0 }
    
    # Final update
    $destFiles = Get-ChildItem $Destination -Recurse -File -Force -ErrorAction SilentlyContinue
    $copiedSize = ($destFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    $copiedFiles = ($destFiles | Measure-Object).Count
    if ($null -eq $copiedSize) { $copiedSize = 0 }
    
    $elapsed = (Get-Date) - $startTime
    $avgSpeed = if ($elapsed.TotalSeconds -gt 0) { $copiedSize / $elapsed.TotalSeconds } else { 0 }
    
    # Complete the progress bar (clear the line first, then draw the final state)
    $progressBar = [string]$Script:Theme.Bar.Full * $progressBarWidth
    Write-Host "`r$(' ' * 90)" -NoNewline
    Write-Host "`r    " -NoNewline
    Write-Host "$($Script:Theme.Glyphs.OK) " -ForegroundColor Green -NoNewline
    Write-Host $progressBar -ForegroundColor Green -NoNewline
    Write-Host " 100%  $(Format-FileSize $copiedSize)  in $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
    
    # Determine status based on exit code and files copied
    $status = if ($exitCode -lt 8) { 
        "Success" 
    } elseif ($exitCode -in @(8, 9) -and $copiedFiles -gt 0) { 
        "Success" 
    } elseif ($exitCode -in @(8, 9)) { 
        "Skipped" 
    } else { 
        "Warning" 
    }
    
    return @{
        ExitCode = $exitCode
        FilesCopied = $copiedFiles
        BytesCopied = $copiedSize
        Status = $status
        Duration = $elapsed
    }
}

function Add-ManualTask {
    param(
        [string]$Task,
        [string]$Reason,
        [string]$Instructions = ""
    )
    
    $manual = @{
        Task = $Task
        Reason = $Reason
        Instructions = $Instructions
    }
    
    [void]$Script:Results.ManualTasks.Add($manual)
}

