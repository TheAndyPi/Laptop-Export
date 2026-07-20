# ============================================================================
# BROWSER DATA
# ============================================================================

function Convert-ChromeBookmarksToHtml {
    param(
        [string]$JsonPath,
        [string]$HtmlPath
    )
    
    try {
        $bookmarksJson = Get-Content $JsonPath -Raw | ConvertFrom-Json
        
        $html = @"
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an automatically generated file.
     It will be read and overwritten.
     DO NOT EDIT! -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
"@
        
        function Process-BookmarkFolder {
            param($folder, $indent = "    ")
            
            $result = ""
            
            if ($folder.children) {
                foreach ($child in $folder.children) {
                    if ($child.type -eq "folder") {
                        $result += "$indent<DT><H3>$(Out-HtmlEncoded $child.name)</H3>`n"
                        $result += "$indent<DL><p>`n"
                        $result += (Process-BookmarkFolder -folder $child -indent "$indent    ")
                        $result += "$indent</DL><p>`n"
                    }
                    elseif ($child.type -eq "url") {
                        $result += "$indent<DT><A HREF=`"$(Out-HtmlEncoded $child.url)`">$(Out-HtmlEncoded $child.name)</A>`n"
                    }
                }
            }
            
            return $result
        }
        
        # Process bookmark bar
        if ($bookmarksJson.roots.bookmark_bar) {
            $html += "    <DT><H3>Bookmarks Bar</H3>`n"
            $html += "    <DL><p>`n"
            $html += (Process-BookmarkFolder -folder $bookmarksJson.roots.bookmark_bar -indent "        ")
            $html += "    </DL><p>`n"
        }
        
        # Process other bookmarks
        if ($bookmarksJson.roots.other) {
            $html += "    <DT><H3>Other Bookmarks</H3>`n"
            $html += "    <DL><p>`n"
            $html += (Process-BookmarkFolder -folder $bookmarksJson.roots.other -indent "        ")
            $html += "    </DL><p>`n"
        }
        
        $html += "</DL><p>"
        
        $html | Out-File $HtmlPath -Encoding UTF8
        return $true
    }
    catch {
        Write-Log "Error converting bookmarks to HTML: $_" -Level Warning
        return $false
    }
}

function Copy-BrowserData {
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Capturing browser bookmarks..." -Level Info
    
    $browserPath = Join-Path $DestinationBase "BrowserData"
    if (-not (Test-Path $browserPath)) {
        New-Item -ItemType Directory -Path $browserPath -Force | Out-Null
    }
    
    $localAppData = $Script:OriginalAppDataLocal
    
    # ========== CHROME BOOKMARKS ==========
    $chromePath = Join-Path $localAppData "Google\Chrome\User Data\Default"
    $bookmarksJson = Join-Path $chromePath "Bookmarks"
    
    if (Test-Path $bookmarksJson) {
        Write-Log "Chrome bookmarks found" -Level Info
        
        $chromeHtml = Join-Path $browserPath "Chrome_Bookmarks.html"
        if (Convert-ChromeBookmarksToHtml -JsonPath $bookmarksJson -HtmlPath $chromeHtml) {
            Write-Log "Chrome bookmarks exported as HTML" -Level Success
            Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Success" -Details "HTML file ready for import"
        }
        else {
            Write-Log "Could not convert Chrome bookmarks" -Level Warning
            Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Warning" -Details "Conversion failed"
        }
        
        # Manual task for passwords
        Add-ManualTask -Task "Export Chrome Passwords" -Reason "Passwords are encrypted and require manual export" -Instructions @"
BEFORE wiping the old laptop:
1. Open Chrome > chrome://settings/passwords
2. Click three dots menu > 'Export passwords'
3. Save CSV file to transfer drive
4. On new laptop: chrome://settings/passwords > Import

OR: Sign into Chrome with Google account to sync automatically.
"@
    }
    else {
        Write-Log "Chrome not installed or no bookmarks" -Level Info
        Add-Result -Category "Browser" -Item "Chrome" -Status "Skipped" -Details "Not found"
    }
    
    # ========== FIREFOX PROFILE ==========
    # Firefox stores the portable profile (bookmarks, history, extensions,
    # saved logins, settings, and open tabs) in Roaming AppData. Local AppData
    # holds companion profile data such as offline storage and cache metadata.
    # Copy both locations so the generated import script can restore Firefox
    # without requiring separate HTML/CSV exports.
    $firefoxRoamingSource = Join-Path $Script:OriginalAppDataRoaming "Mozilla\Firefox"
    $firefoxLocalSource = Join-Path $Script:OriginalAppDataLocal "Mozilla\Firefox"
    $firefoxPackagePath = Join-Path $browserPath "Firefox"
    $firefoxFound = $false

    if (@(Get-Process -Name "firefox" -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log "Firefox is running; profile files may change while they are copied" -Level Warning
        Add-ManualTask -Task "Verify Firefox profile export" -Reason "Firefox was open during export" -Instructions "Close Firefox before running the export when possible. If Firefox data is important, run the export again with Firefox closed so its profile databases are captured consistently."
    }

    if (Test-Path $firefoxRoamingSource) {
        $firefoxFound = $true
        $firefoxRoamingDest = Join-Path $firefoxPackagePath "Roaming"
        $firefoxRoamingLog = Join-Path $DestinationBase "Logs\robocopy_firefox_roaming.log"
        $result = Copy-WithProgress -Source $firefoxRoamingSource `
                                    -Destination $firefoxRoamingDest `
                                    -FolderName "Firefox profile (Roaming)" `
                                    -LogPath $firefoxRoamingLog `
                                    -RobocopyArgs $Script:Config.RobocopyArgs

        if ($result.Status -eq "Success") {
            Write-Log "Firefox roaming profile copied: $($result.FilesCopied) files" -Level Success
            Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Success" -Details "$($result.FilesCopied) files; bookmarks, history, logins, extensions, and settings"
        }
        else {
            Write-Log "Firefox roaming profile copy completed with warnings" -Level Warning
            Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Warning" -Details "Check robocopy_firefox_roaming.log"
        }
    }

    if (Test-Path $firefoxLocalSource) {
        $firefoxFound = $true
        $firefoxLocalDest = Join-Path $firefoxPackagePath "Local"
        $firefoxLocalLog = Join-Path $DestinationBase "Logs\robocopy_firefox_local.log"
        $result = Copy-WithProgress -Source $firefoxLocalSource `
                                    -Destination $firefoxLocalDest `
                                    -FolderName "Firefox data (Local)" `
                                    -LogPath $firefoxLocalLog `
                                    -RobocopyArgs $Script:Config.RobocopyArgs

        if ($result.Status -eq "Success") {
            Write-Log "Firefox local data copied: $($result.FilesCopied) files" -Level Success
            Add-Result -Category "Browser" -Item "Firefox Local Data" -Status "Success" -Details "$($result.FilesCopied) files"
        }
        else {
            Write-Log "Firefox local data copy completed with warnings" -Level Warning
            Add-Result -Category "Browser" -Item "Firefox Local Data" -Status "Warning" -Details "Check robocopy_firefox_local.log"
        }
    }

    if (-not $firefoxFound) {
        Write-Log "Firefox not installed or no profile data found" -Level Info
        Add-Result -Category "Browser" -Item "Firefox" -Status "Skipped" -Details "Not found"
    }
    
    # ========== EDGE BOOKMARKS ==========
    $edgePath = Join-Path $localAppData "Microsoft\Edge\User Data\Default"
    $edgeBookmarks = Join-Path $edgePath "Bookmarks"
    
    if (Test-Path $edgeBookmarks) {
        Write-Log "Edge bookmarks found" -Level Info
        
        $edgeHtml = Join-Path $browserPath "Edge_Bookmarks.html"
        if (Convert-ChromeBookmarksToHtml -JsonPath $edgeBookmarks -HtmlPath $edgeHtml) {
            Write-Log "Edge bookmarks exported as HTML" -Level Success
            Add-Result -Category "Browser" -Item "Edge Bookmarks" -Status "Success" -Details "HTML file ready for import"
        }
    }
    else {
        Write-Log "Edge not installed or no bookmarks" -Level Info
        Add-Result -Category "Browser" -Item "Edge" -Status "Skipped" -Details "Not found"
    }
    
    # Edge syncs via Microsoft account
    Add-ManualTask -Task "Sign into Microsoft Edge" -Reason "Edge syncs via Microsoft account" -Instructions "Sign into Edge with Microsoft account to sync passwords and settings"
}

# ============================================================================
# ONEDRIVE
# ============================================================================

function Set-OneDriveLocalSync {
    Write-Log "Checking OneDrive status..." -Level Info

    # Online mode: don't force-hydrate OneDrive. Pinning every file would
    # re-download the whole drive over the same constrained link we're trying
    # to spare. OneDrive re-syncs on the new machine after sign-in anyway.
    if ($Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.SkipOneDriveHydration) {
        Write-Log "Skipping OneDrive offline hydration (online mode)" -Level Info
        Write-Status "OneDrive Hydration" "SKIP" "online mode - re-syncs on new machine"
        Add-Result -Category "OneDrive" -Item "Offline Sync" -Status "Skipped" -Details "Skipped in online mode (re-syncs after sign-in)"
        Add-ManualTask -Task "Verify OneDrive after sign-in" -Reason "Offline hydration skipped in online transfer" -Instructions "On the new machine, sign into OneDrive and confirm files sync. No action needed on the old machine."
        return
    }

    # Find OneDrive folder
    $oneDrivePath = $env:OneDrive
    $oneDriveCommercial = $env:OneDriveCommercial
    
    $targetPath = if ($oneDriveCommercial) { $oneDriveCommercial } else { $oneDrivePath }
    
    if ($targetPath -and (Test-Path $targetPath)) {
        Write-Log "OneDrive path: $targetPath" -Level Info
        
        # Try to set files as "Always available on this device" using attrib
        # -U removes the "online-only" attribute, +P sets "pinned" (always available)
        Write-Log "Attempting to mark OneDrive files for offline availability..." -Level Info
        Write-Host "  This may take several minutes depending on the number of files..." -ForegroundColor Yellow
        
        $success = $false
        $errorMessage = ""
        
        try {
            # Count files first to give user an idea of scope
            $fileCount = (Get-ChildItem $targetPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Log "Found approximately $fileCount files in OneDrive" -Level Info
            
            # Use attrib to remove cloud-only and set pinned
            # /S = process subfolders, /D = process directories too
            $attribResult = Start-Process -FilePath "attrib.exe" -ArgumentList "+P", "-U", "/S", "/D", "`"$targetPath\*`"" -Wait -PassThru -NoNewWindow -ErrorAction Stop
            
            if ($attribResult.ExitCode -eq 0) {
                $success = $true
                Write-Log "OneDrive files marked for offline availability" -Level Success
                Add-Result -Category "OneDrive" -Item "Offline Sync" -Status "Success" -Details "Files marked for download (~$fileCount files)"
                
                # Add note that download may still be in progress
                Add-ManualTask -Task "Verify OneDrive Download Complete" -Reason "Files are downloading in background" -Instructions @"
Files have been marked for offline availability but may still be downloading.
1. Check the OneDrive icon in system tray for sync status
2. Wait for sync to complete before disconnecting from network
3. Verify important files are available by checking for green checkmarks
"@
            }
            else {
                $errorMessage = "attrib command returned exit code $($attribResult.ExitCode)"
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        
        if (-not $success) {
            Write-Log "Could not automatically set OneDrive offline: $errorMessage" -Level Warning
            Add-Result -Category "OneDrive" -Item "Offline Sync" -Status "Manual" -Details "Automatic method failed"
            
            Add-ManualTask -Task "OneDrive - Make Files Available Offline" -Reason "Automatic method failed: $errorMessage" -Instructions @"
1. Open File Explorer and navigate to: $targetPath
2. Press Ctrl+A to select all files/folders
3. Right-click and select 'Always keep on this device'
4. Wait for sync to complete (check OneDrive tray icon)
5. Verify files show green checkmarks before proceeding
"@
        }
    }
    else {
        Write-Log "OneDrive not configured" -Level Warning
        Add-Result -Category "OneDrive" -Item "Sync Status" -Status "Skipped" -Details "OneDrive not found"
    }
}

# ============================================================================
# IMPORT SCRIPT GENERATOR
