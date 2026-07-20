# ============================================================================
# DESTINATION SELECTION
# ============================================================================

function Test-DestinationIsWithinSourceProfile {
    param([string]$Path)

    try {
        $destination = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $profile = [System.IO.Path]::GetFullPath($Script:OriginalUserProfile).TrimEnd('\')
        return $destination.Equals($profile, [System.StringComparison]::OrdinalIgnoreCase) -or
               $destination.StartsWith("$profile\", [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Select-TargetDrive {
    Write-StoLogo
    Write-Banner -Title "Laptop Transfer  -  Export Tool" -Subtitle "v$($Script:Config.Version)"
    Write-KeyValue "Transferring" $Script:OriginalUserName
    Write-KeyValue "Computer" $env:COMPUTERNAME
    Write-KeyValue "Transfer" $Script:Config.TransferMode
    Write-Section "Select external or secondary drive"

    # Local mode keeps the existing drive selector rather than opening the
    # Windows folder picker. C: is deliberately excluded.
    $drives = @(Get-WmiObject Win32_LogicalDisk | Where-Object {
        $_.DriveType -in @(2, 3) -and $_.DeviceID -ne $env:SystemDrive -and $_.Size -gt 0
    } | ForEach-Object {
        $freeGB = [math]::Round($_.FreeSpace / 1GB, 2)
        $totalGB = [math]::Round($_.Size / 1GB, 2)
        $type = if ($_.DriveType -eq 2) { "Removable" } else { "Fixed" }
        [PSCustomObject]@{
            Letter = $_.DeviceID
            Type = $type
            Display = "$($_.DeviceID) [$($_.VolumeName)] - $type - $freeGB GB free of $totalGB GB"
        }
    })

    if (-not $drives) {
        Write-Host "`nNo external or secondary drives found." -ForegroundColor Red
        Write-Host "Connect an external drive and try again." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    for ($i = 0; $i -lt $drives.Count; $i++) {
        $color = if ($drives[$i].Type -eq "Removable") { "Cyan" } else { "White" }
        Write-Host "  [$($i + 1)] $($drives[$i].Display)" -ForegroundColor $color
    }
    Write-Host "`n  [0] Cancel`n" -ForegroundColor Gray

    do {
        $selection = Read-Host "Select target drive (1-$($drives.Count))"
        if ($selection -eq "0") { return $null }

        $index = 0
        if ([int]::TryParse($selection, [ref]$index)) {
            $index--
            if ($index -ge 0 -and $index -lt $drives.Count) {
                $selectedDrive = $drives[$index]
                $confirm = Read-Host "Proceed with $($selectedDrive.Display)? (Y/N)"
                if ($confirm -match "^[Yy]") { return $selectedDrive.Letter }
            }
        }
        Write-Host "Invalid selection. Please try again." -ForegroundColor Red
    } while ($true)
}

function Select-TargetDestination {
    Write-StoLogo
    Write-Banner -Title "Laptop Transfer  -  Export Tool" -Subtitle "v$($Script:Config.Version)"
    Write-KeyValue "Transferring" $Script:OriginalUserName
    Write-KeyValue "Computer" $env:COMPUTERNAME
    if ($Script:IsAdmin) {
        Write-KeyValue "Mode" "Administrator"
    } else {
        Write-KeyValue "Mode" "Standard (some items manual)"
    }
    Write-KeyValue "Transfer" $Script:Config.TransferMode
    if ($Script:IsAdmin -and $Script:OriginalUserName -ne $env:USERNAME) {
        Write-KeyValue "Running as" "$env:USERNAME (elevated)"
    }

    Write-Section "Choose export destination"
    Write-Host "Select a network share, cloud-synced folder, or local folder for the zipped export." -ForegroundColor Gray

    $selectedPath = $DestinationPath
    if (-not $selectedPath) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = "Choose the folder that will receive the laptop transfer package"
            $dialog.ShowNewFolderButton = $true
            if (Test-Path $env:USERPROFILE) { $dialog.SelectedPath = $env:USERPROFILE }

            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
                Write-Host "Operation cancelled." -ForegroundColor Yellow
                return $null
            }
            $selectedPath = $dialog.SelectedPath
        }
        catch {
            # FolderBrowserDialog should be available on supported Windows builds,
            # but keep a console fallback for constrained PowerShell hosts.
            Write-Host "Could not open the Windows folder picker: $_" -ForegroundColor Yellow
            $selectedPath = Read-Host "Enter destination folder path (blank to cancel)"
            if (-not $selectedPath) { return $null }
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $selectedPath -PathType Container)) {
            New-Item -ItemType Directory -Path $selectedPath -Force -ErrorAction Stop | Out-Null
        }
        $selectedPath = (Resolve-Path -LiteralPath $selectedPath -ErrorAction Stop).Path
    }
    catch {
        Write-Host "Unable to use destination folder '$selectedPath': $_" -ForegroundColor Red
        return $null
    }

    if (Test-DestinationIsWithinSourceProfile -Path $selectedPath) {
        Write-Host "The destination cannot be inside the profile being exported." -ForegroundColor Red
        Write-Host "Choose a different folder to avoid copying the export into itself." -ForegroundColor Yellow
        return $null
    }

    Write-KeyValue "Destination" $selectedPath
    return $selectedPath
}

# ============================================================================
# FOLDER OPERATIONS
# ============================================================================

function Get-FolderSizeBytes {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

function Get-DestinationFreeSpaceBytes {
    param([string]$Path)

    # PSDrive exposes capacity for local, mapped, and most UNC destinations.
    # It is intentionally best-effort because some cloud providers do not report it.
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSDrive -and $null -ne $item.PSDrive.Free) {
        return [long]$item.PSDrive.Free
    }

    $root = [System.IO.Path]::GetPathRoot($item.FullName)
    if ($root) {
        return [long]([System.IO.DriveInfo]::new($root).AvailableFreeSpace)
    }

    return $null
}

function New-TransferArchive {
    param([string]$TransferBase)

    if ($Script:Config.TransferMode -ne "Online") {
        Write-Log "Skipping ZIP archive for Local transfer" -Level Info
        return $null
    }

    $parentFolder = Split-Path -Path $TransferBase -Parent
    $archiveName = "$(Split-Path -Path $TransferBase -Leaf).zip"
    $archivePath = Join-Path $parentFolder $archiveName

    if (Test-Path -LiteralPath $archivePath) {
        Write-Log "ZIP archive already exists: $archivePath" -Level Warning
        Write-Host "A ZIP archive already exists: $archivePath" -ForegroundColor Yellow
        return $null
    }

    try {
        Write-Host "`n  Creating ZIP archive..." -ForegroundColor Cyan
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $TransferBase,
            $archivePath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $true
        )

        Write-Log "ZIP archive created: $archivePath" -Level Success
        Add-Result -Category "Package" -Item $archiveName -Status "Success" -Details "Compressed transfer package"
        return $archivePath
    }
    catch {
        Write-Log "Could not create ZIP archive: $_" -Level Error
        Add-Result -Category "Package" -Item $archiveName -Status "Error" -Details "ZIP creation failed: $_"
        Write-Host "ZIP creation failed: $_" -ForegroundColor Red
        return $null
    }
}

function Resolve-TransferMode {
    # Prompt for transfer mode unless one was passed on the command line.
    if ($Script:Config.TransferMode -in @("Local", "Online") -and $TransferMode) {
        return  # already set from param
    }
    Write-Section "Transfer mode"
    Write-Host "  [1] Local  " -ForegroundColor Cyan -NoNewline
    Write-Host "- full copy (USB / on-site)" -ForegroundColor DarkGray
    Write-Host "  [2] Online " -ForegroundColor Cyan -NoNewline
    Write-Host "- trimmed for slow/remote links (caps Downloads at $($Script:Config.Online.DownloadsCapGB)GB, skips Lotus)" -ForegroundColor DarkGray
    Write-Host ""
    do {
        $m = Read-Host "  Select transfer mode (1-2)"
        if ($m -eq "1") { $Script:Config.TransferMode = "Local"; break }
        if ($m -eq "2") { $Script:Config.TransferMode = "Online"; break }
        Write-Host "  Invalid selection." -ForegroundColor Red
    } while ($true)
}

