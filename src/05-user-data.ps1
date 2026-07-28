function Copy-UserFolders {
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Starting user folder copy..." -Level Info
    
    $userProfile = $Script:OriginalUserProfile
    $destUserData = Join-Path $DestinationBase "UserData"
    
    # Create logs directory
    $logsDir = Join-Path $DestinationBase "Logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    
    foreach ($folder in $Script:Config.UserFolders) {
        $sourcePath = Join-Path $userProfile $folder
        $destPath = Join-Path $destUserData $folder
        
        if (Test-Path $sourcePath) {
            # Check if folder has content (excluding junctions)
            $items = Get-ChildItem $sourcePath -Force -ErrorAction SilentlyContinue | 
                Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) }
            
            if ($items) {
                # ---- Online mode: size gating ----
                if ($Script:Config.TransferMode -eq "Online") {
                    $folderBytes = Get-FolderSizeBytes $sourcePath
                    $folderGB = [math]::Round($folderBytes / 1GB, 2)

                    # Downloads has a hard cap: omit entirely if over the limit.
                    if ($folder -eq "Downloads" -and $folderGB -gt $Script:Config.Online.DownloadsCapGB) {
                        Write-Log "Downloads is $folderGB GB (> $($Script:Config.Online.DownloadsCapGB) GB online cap) - omitting" -Level Warning
                        Write-Status "Downloads" "SKIP" "$folderGB GB exceeds $($Script:Config.Online.DownloadsCapGB)GB online cap"
                        Add-Result -Category "User Folders" -Item "Downloads" -Status "Skipped" -Details "Omitted (online mode): $folderGB GB > $($Script:Config.Online.DownloadsCapGB) GB cap"
                        Add-ManualTask -Task "Copy Downloads folder manually (if needed)" -Reason "Omitted in online transfer: $folderGB GB exceeds the $($Script:Config.Online.DownloadsCapGB) GB cap" -Instructions "If the user needs their Downloads, copy C:\Users\$($Script:OriginalUserName)\Downloads separately (external drive or a targeted OneDrive upload)."
                        continue
                    }

                    # Any other large folder: ask the tech (skip / copy anyway).
                    if ($folderGB -gt $Script:Config.Online.LargeFolderPromptGB) {
                        Write-Host ""
                        Write-Host "  $($Script:Theme.Glyphs.WARN) " -ForegroundColor Yellow -NoNewline
                        Write-Host "$folder is $folderGB GB (over the $($Script:Config.Online.LargeFolderPromptGB) GB online threshold)." -ForegroundColor White
                        $ans = Read-Host "    Copy it anyway? (Y = copy / N = skip)"
                        if ($ans -notmatch "^[Yy]") {
                            Write-Log "$folder ($folderGB GB) skipped by operator (online mode)" -Level Warning
                            Write-Status $folder "SKIP" "$folderGB GB, skipped by operator"
                            Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Omitted (online mode): $folderGB GB, operator chose skip"
                            Add-ManualTask -Task "Copy $folder folder manually (if needed)" -Reason "Skipped in online transfer: $folderGB GB" -Instructions "Copy C:\Users\$($Script:OriginalUserName)\$folder separately if the user needs it."
                            continue
                        }
                    }
                }

                $robocopyLog = Join-Path $logsDir "robocopy_$folder.log"
                
                # Use progress copy function
                $result = Copy-WithProgress -Source $sourcePath `
                                           -Destination $destPath `
                                           -FolderName $folder `
                                           -LogPath $robocopyLog `
                                           -RobocopyArgs $Script:Config.RobocopyArgs
                
                # Log result
                if ($result.Status -eq "Success") {
                    Write-Log "$folder completed: $($result.FilesCopied) files, $(Format-FileSize $result.BytesCopied)" -Level Success
                    Add-Result -Category "User Folders" -Item $folder -Status "Success" -Details "$($result.FilesCopied) files copied"
                }
                elseif ($result.Aborted) {
                    Write-Log "$folder copy stopped by operator" -Level Warning
                    Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Stopped by operator; partial files may remain and can be resumed by rerunning the export"
                }
                elseif ($result.Status -eq "Skipped") {
                    Write-Log "$folder has no copyable files (junctions only)" -Level Info
                    Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "No files to copy"
                }
                else {
                    Write-Log "$folder completed with warnings (exit: $($result.ExitCode))" -Level Warning
                    Add-Result -Category "User Folders" -Item $folder -Status "Warning" -Details "Check log for details"
                    [void]$Script:Results.Warnings.Add("${folder}: Robocopy exit code $($result.ExitCode)")
                }
                
                Write-Host ""
            }
            else {
                Write-Log "$folder is empty or contains only junctions, skipping" -Level Info
                Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Folder empty"
            }
        }
        else {
            Write-Log "$folder not found, skipping" -Level Info
            Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Folder not found"
        }
    }
    
    # Check for additional folders in user profile (excluding known system folders and cloud sync folders)
    Write-Log "Checking for additional user folders..." -Level Info
    
    # Explicit folders to exclude
    $excludeFolders = @(
        # System folders
        "AppData", "Application Data", "Local Settings", "NetHood", "PrintHood",
        "Recent", "SendTo", "Start Menu", "Templates", "Cookies", "Links",
        "Saved Games", "Searches", "Contacts", "3D Objects",
        # Cloud sync folders
        "OneDrive", "OneDrive - STO Building Group", "STO Building Group",
        "Dropbox", "Google Drive", "iCloudDrive", "Box", "Box Sync"
    ) + $Script:Config.UserFolders
    
    $additionalFolders = Get-ChildItem $userProfile -Directory -Force -ErrorAction SilentlyContinue | 
        Where-Object { 
            $folderName = $_.Name
            # Exclude if in explicit list
            $folderName -notin $excludeFolders -and 
            # Exclude hidden folders
            -not $folderName.StartsWith(".") -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
            # Exclude any folder starting with "OneDrive"
            -not $folderName.StartsWith("OneDrive")
        }
    
    foreach ($folder in $additionalFolders) {
        $items = Get-ChildItem $folder.FullName -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) }
        if ($items) {
            $destPath = Join-Path $destUserData "Additional\$($folder.Name)"
            $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_additional_$($folder.Name).log"
            
            $result = Copy-WithProgress -Source $folder.FullName `
                                       -Destination $destPath `
                                       -FolderName "Additional: $($folder.Name)" `
                                       -LogPath $robocopyLog `
                                       -RobocopyArgs $Script:Config.RobocopyArgs
            
            if ($result.Status -eq "Success") {
                Write-Log "Additional folder $($folder.Name) copied: $($result.FilesCopied) files" -Level Success
                Add-Result -Category "Additional Folders" -Item $folder.Name -Status "Success" -Details "$($result.FilesCopied) files"
            }
            elseif ($result.Aborted) {
                Write-Log "Additional folder $($folder.Name) copy stopped by operator" -Level Warning
                Add-Result -Category "Additional Folders" -Item $folder.Name -Status "Skipped" -Details "Stopped by operator; partial files may remain"
            }
            Write-Host ""
        }
    }
    
    # Check for loose files directly in user profile root (not in any subfolder)
    Write-Log "Checking for loose files in user profile root..." -Level Info
    
    $looseFiles = Get-ChildItem $userProfile -File -Force -ErrorAction SilentlyContinue | 
        Where-Object { 
            -not $_.Name.StartsWith(".") -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::System) -and
            $_.Extension -notin @(".ini", ".dat", ".log") # Skip system files
        }
    
    if ($looseFiles -and $looseFiles.Count -gt 0) {
        Write-Log "Found $($looseFiles.Count) loose file(s) in profile root" -Level Info
        
        $destLooseFiles = Join-Path $destUserData "ProfileRoot"
        if (-not (Test-Path $destLooseFiles)) {
            New-Item -ItemType Directory -Path $destLooseFiles -Force | Out-Null
        }
        
        $copiedCount = 0
        $failedCount = 0
        
        foreach ($file in $looseFiles) {
            try {
                $destFile = Join-Path $destLooseFiles $file.Name
                Copy-Item $file.FullName -Destination $destFile -Force -ErrorAction Stop
                $copiedCount++
                Write-Log "  Copied: $($file.Name)" -Level Info
            }
            catch {
                $failedCount++
                Write-Log "  Failed: $($file.Name) - $_" -Level Warning
            }
        }
        
        if ($copiedCount -gt 0) {
            Write-Log "Loose files copied: $copiedCount file(s)" -Level Success
            Add-Result -Category "Loose Files" -Item "Profile Root Files" -Status "Success" -Details "$copiedCount file(s) from user profile root"
        }
        if ($failedCount -gt 0) {
            Add-Result -Category "Loose Files" -Item "Profile Root Files (partial)" -Status "Warning" -Details "$failedCount file(s) could not be copied"
        }
    }
    else {
        Write-Log "No loose files found in profile root" -Level Info
    }
    
    # Check for OCS Documents folder on C: drive
    Write-Log "Checking for OCS Documents on C: drive..." -Level Info
    
    $ocsPath = "C:\OCS Documents"
    if (Test-Path $ocsPath) {
        Write-Log "Found OCS Documents folder" -Level Info
        
        $destOcs = Join-Path $destUserData "OCS Documents"
        $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_ocs_documents.log"
        
        $result = Copy-WithProgress -Source $ocsPath `
                                   -Destination $destOcs `
                                   -FolderName "OCS Documents (C:\)" `
                                   -LogPath $robocopyLog `
                                   -RobocopyArgs $Script:Config.RobocopyArgs
        
        if ($result.Status -eq "Success") {
            Write-Log "OCS Documents copied: $($result.FilesCopied) files" -Level Success
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Success" -Details "$($result.FilesCopied) files from C:\OCS Documents"
        }
        elseif ($result.Aborted) {
            Write-Log "OCS Documents copy stopped by operator" -Level Warning
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Skipped" -Details "Stopped by operator; partial files may remain"
        }
        else {
            Write-Log "OCS Documents copy had issues" -Level Warning
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Warning" -Details "Check log for details"
        }
        Write-Host ""
    }
    else {
        Write-Log "OCS Documents folder not found on C: drive" -Level Info
    }
}

function Copy-AppData {
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Copying AppData items..." -Level Info
    
    $roamingPath = $Script:OriginalAppDataRoaming
    $destAppData = Join-Path $DestinationBase "AppData"
    
    # ========== BLUEBEAM (check multiple possible locations) ==========
    Write-Log "Checking for Bluebeam..." -Level Info
    $bluebeamFound = $false
    
    foreach ($bluebeamFolder in $Script:Config.BluebeamPaths) {
        $bluebeamSource = Join-Path $roamingPath $bluebeamFolder
        
        if (Test-Path $bluebeamSource) {
            Write-Log "Found Bluebeam at: $bluebeamSource" -Level Info
            $bluebeamFound = $true
            
            $destPath = Join-Path $destAppData "Bluebeam"
            $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_appdata_bluebeam.log"
            
            $result = Copy-WithProgress -Source $bluebeamSource `
                                       -Destination $destPath `
                                       -FolderName "Bluebeam ($bluebeamFolder)" `
                                       -LogPath $robocopyLog `
                                       -RobocopyArgs $Script:Config.RobocopyArgs
            
            if ($result.Status -eq "Success") {
                Write-Log "Bluebeam copied: $($result.FilesCopied) files" -Level Success
                Add-Result -Category "AppData" -Item "Bluebeam" -Status "Success" -Details "$($result.FilesCopied) files from $bluebeamFolder"
            }
            elseif ($result.Aborted) {
                Write-Log "Bluebeam copy stopped by operator" -Level Warning
                Add-Result -Category "AppData" -Item "Bluebeam" -Status "Skipped" -Details "Stopped by operator; partial files may remain"
            }
            else {
                Write-Log "Bluebeam copy had issues" -Level Warning
                Add-Result -Category "AppData" -Item "Bluebeam" -Status "Warning" -Details "Check log"
            }
            Write-Host ""
            break  # Found and copied, no need to check other paths
        }
    }
    
    if (-not $bluebeamFound) {
        Write-Log "Bluebeam not found in AppData\Roaming" -Level Info
        Add-Result -Category "AppData" -Item "Bluebeam" -Status "Skipped" -Details "Not installed"
    }
    
    # ========== OTHER ROAMING APPDATA ITEMS ==========
    foreach ($item in $Script:Config.AppDataRoaming.GetEnumerator()) {
        $sourcePath = Join-Path $roamingPath $item.Value
        $destPath = Join-Path $destAppData $item.Key
        
        if (Test-Path $sourcePath) {
            Write-Log "Copying $($item.Key)..." -Level Info
            
            try {
                if (-not (Test-Path $destPath)) {
                    New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                }
                
                # For QuickAccess - simply copy the database file (safest method)
                # DO NOT use Shell COM to enumerate - it can modify Quick Access!
                if ($item.Key -eq "QuickAccess") {
                    Write-Log "Backing up Quick Access database..." -Level Info
                    
                    if (-not (Test-Path $destPath)) {
                        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                    }
                    
                    # The correct file for Quick Access pins is f01b4d95cf55d32a.automaticDestinations-ms
                    $qaFile = Join-Path $sourcePath "f01b4d95cf55d32a.automaticDestinations-ms"
                    
                    if (Test-Path $qaFile) {
                        try {
                            # Simply copy the file - this preserves ALL Quick Access items
                            Copy-Item $qaFile -Destination $destPath -Force -ErrorAction Stop
                            
                            $fileSize = (Get-Item $qaFile).Length
                            Write-Log "Quick Access database copied ($(Format-FileSize $fileSize))" -Level Success
                            Add-Result -Category "AppData" -Item "Quick Access Pins" -Status "Success" -Details "Database file backed up"
                            
                            # Create instruction file for manual restore if needed
                            $instructionFile = Join-Path $destPath "RESTORE_INSTRUCTIONS.txt"
                            @"
Quick Access Pins Backup
========================
File: f01b4d95cf55d32a.automaticDestinations-ms
Backed up: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
From: $env:COMPUTERNAME

AUTOMATIC RESTORE:
The Import-LaptopData.ps1 script will automatically restore this file.

MANUAL RESTORE (if needed):
1. Close ALL File Explorer windows
2. Copy f01b4d95cf55d32a.automaticDestinations-ms to:
   %AppData%\Microsoft\Windows\Recent\AutomaticDestinations\
3. Restart Explorer:
   - Press Ctrl+Shift+Esc to open Task Manager
   - Find 'Windows Explorer' in the list
   - Right-click and select 'Restart'

NOTE: If paths don't exist on new machine (different username, etc.),
those pins may not work. You can manually re-pin folders:
Right-click folder > 'Pin to Quick access'
"@ | Out-File $instructionFile -Encoding UTF8
                            
                        }
                        catch {
                            Write-Log "Quick Access backup failed: $_" -Level Warning
                            Add-Result -Category "AppData" -Item "Quick Access Pins" -Status "Warning" -Details $_.Exception.Message
                        }
                    }
                    else {
                        Write-Log "Quick Access database file not found" -Level Warning
                        Add-Result -Category "AppData" -Item "Quick Access Pins" -Status "Skipped" -Details "No Quick Access data found"
                    }
                }
                else {
                    # Copy the folder through the shared progress runner so
                    # the technician can skip this individual transfer.
                    $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_appdata_$($item.Key).log"
                    $result = Copy-WithProgress -Source $sourcePath `
                                                -Destination $destPath `
                                                -FolderName "$($item.Key) (Roaming AppData)" `
                                                -LogPath $robocopyLog `
                                                -RobocopyArgs $Script:Config.RobocopyArgs
                    
                    if ($result.Status -eq "Success") {
                        Write-Log "$($item.Key) copied successfully" -Level Success
                        Add-Result -Category "AppData" -Item $item.Key -Status "Success"
                    }
                    elseif ($result.Aborted) {
                        Write-Log "$($item.Key) copy stopped by operator" -Level Warning
                        Add-Result -Category "AppData" -Item $item.Key -Status "Skipped" -Details "Stopped by operator; partial files may remain"
                    }
                    else {
                        Write-Log "$($item.Key) copy had issues (exit: $($result.ExitCode))" -Level Warning
                        Add-Result -Category "AppData" -Item $item.Key -Status "Warning" -Details "Exit code: $($result.ExitCode)"
                    }
                }
            }
            catch {
                Write-Log "Error copying $($item.Key)`: $_" -Level Error
                Add-Result -Category "AppData" -Item $item.Key -Status "Error" -Details $_.Exception.Message
                [void]$Script:Results.Errors.Add("$($item.Key)`: $($_.Exception.Message)")
            }
        }
        else {
            Write-Log "$($item.Key) not found at $sourcePath" -Level Info
            Add-Result -Category "AppData" -Item $item.Key -Status "Skipped" -Details "Not found"
        }
    }
    
    # ========== LOCAL APPDATA ITEMS (Lotus, etc.) ==========
    Write-Log "Checking AppData Local items..." -Level Info
    $localPath = $Script:OriginalAppDataLocal
    
    foreach ($item in $Script:Config.AppDataLocal.GetEnumerator()) {
        $sourcePath = Join-Path $localPath $item.Value
        $destPath = Join-Path $destAppData "$($item.Key)_Local"

        # Online mode: skip Lotus Notes local data by default (usually very large,
        # and Notes is reconfigured manually on the new machine anyway).
        if ($Script:Config.TransferMode -eq "Online" -and
            $item.Key -eq "Lotus" -and $Script:Config.Online.SkipLotusNotes) {
            if (Test-Path $sourcePath) {
                $lotusGB = [math]::Round((Get-FolderSizeBytes $sourcePath) / 1GB, 2)
                Write-Log "Lotus Notes local data omitted in online mode ($lotusGB GB)" -Level Warning
                Write-Status "Lotus Notes (Local)" "SKIP" "$lotusGB GB, omitted (online)"
                Add-Result -Category "AppData Local" -Item "Lotus" -Status "Skipped" -Details "Omitted (online mode): $lotusGB GB"
                Add-ManualTask -Task "Lotus Notes reconfiguration" -Reason "Local data omitted in online transfer ($lotusGB GB)" -Instructions "Lotus Notes is set up fresh on the new machine (see checklist). If the user has critical local (non-server) Notes data, copy it separately from AppData\Local\Lotus."
            }
            continue
        }

        if (Test-Path $sourcePath) {
            Write-Log "Found $($item.Key) in AppData\Local - copying..." -Level Info
            
            try {
                $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_appdata_local_$($item.Key).log"
                
                $result = Copy-WithProgress -Source $sourcePath `
                                           -Destination $destPath `
                                           -FolderName "$($item.Key) (Local AppData)" `
                                           -LogPath $robocopyLog `
                                           -RobocopyArgs $Script:Config.RobocopyArgs
                
                if ($result.Status -eq "Success") {
                    Write-Log "$($item.Key) (Local) copied: $($result.FilesCopied) files" -Level Success
                    Add-Result -Category "AppData Local" -Item $item.Key -Status "Success" -Details "$($result.FilesCopied) files"
                }
                elseif ($result.Aborted) {
                    Write-Log "$($item.Key) (Local) copy stopped by operator" -Level Warning
                    Add-Result -Category "AppData Local" -Item $item.Key -Status "Skipped" -Details "Stopped by operator; partial files may remain"
                }
                else {
                    Write-Log "$($item.Key) (Local) copy had issues" -Level Warning
                    Add-Result -Category "AppData Local" -Item $item.Key -Status "Warning" -Details "Check log"
                }
                Write-Host ""
            }
            catch {
                Write-Log "Error copying $($item.Key) (Local): $_" -Level Error
                Add-Result -Category "AppData Local" -Item $item.Key -Status "Error" -Details $_.Exception.Message
            }
        }
        else {
            Write-Log "$($item.Key) not found in AppData\Local (user may not have this app)" -Level Info
        }
    }
}

# ============================================================================
