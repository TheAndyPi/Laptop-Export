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
        
        # Chrome can have several root folders (bookmark bar, other/mobile
        # bookmarks, reading list, managed folders, etc.).  Enumerating them
        # instead of hard-coding two roots preserves every bookmark Chrome
        # exposes in the profile file.
        $rootLabels = @{
            bookmark_bar = "Bookmarks Bar"
            other        = "Other Bookmarks"
            synced       = "Mobile Bookmarks"
        }
        foreach ($rootProperty in $bookmarksJson.roots.PSObject.Properties) {
            $folder = $rootProperty.Value
            if (-not $folder -or -not $folder.children) { continue }

            $label = if ($rootLabels.ContainsKey($rootProperty.Name)) {
                $rootLabels[$rootProperty.Name]
            }
            elseif ($folder.name) {
                $folder.name
            }
            else {
                $rootProperty.Name
            }

            $html += "    <DT><H3>$(Out-HtmlEncoded $label)</H3>`n"
            $html += "    <DL><p>`n"
            $html += (Process-BookmarkFolder -folder $folder -indent "        ")
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

function Get-ChromeProfileDirectories {
    param([string]$UserDataPath)

    if (-not (Test-Path -LiteralPath $UserDataPath)) { return @() }

    # The profile names Chrome creates on Windows are Default and Profile N.
    # Guest/System profiles are intentionally not exported as personal data.
    return @(Get-ChildItem -LiteralPath $UserDataPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" } |
        Sort-Object Name)
}

function Request-BrowserClose {
    param(
        [string]$ProcessName,
        [string]$DisplayName
    )

    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return $true }

    Write-Host ""
    Write-Host "  $DisplayName is open. Close it to capture its profile databases consistently." -ForegroundColor Yellow
    $response = Read-Host "  Close $DisplayName, then press Enter to continue (S to copy while it is open)"
    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return $true }

    Write-Log "$DisplayName is still running; some active database files may be unavailable or inconsistent" -Level Warning
    Add-ManualTask -Task "Verify $DisplayName profile export" -Reason "$DisplayName was open during export" -Instructions "Close $DisplayName and run the export again before the old laptop is wiped if its current browser data is important."
    return $false
}

function Export-ChromeBookmarks {
    param(
        [string]$ChromeUserDataPath,
        [string]$BrowserPath
    )

    $bookmarkPath = Join-Path $BrowserPath "Chrome\Bookmarks"
    $profiles = @(Get-ChromeProfileDirectories -UserDataPath $ChromeUserDataPath)
    $exported = 0

    foreach ($profile in $profiles) {
        $bookmarksJson = Join-Path $profile.FullName "Bookmarks"
        if (-not (Test-Path -LiteralPath $bookmarksJson)) { continue }

        $safeProfileName = $profile.Name -replace '[^a-zA-Z0-9_.-]', '_'
        $chromeHtml = Join-Path $bookmarkPath "Chrome_Bookmarks_$safeProfileName.html"
        if (-not (Test-Path -LiteralPath $bookmarkPath)) {
            New-Item -ItemType Directory -Path $bookmarkPath -Force | Out-Null
        }

        if (Convert-ChromeBookmarksToHtml -JsonPath $bookmarksJson -HtmlPath $chromeHtml) {
            $exported++
            Write-Log "Chrome bookmarks exported for profile '$($profile.Name)'" -Level Success

            # Keep the old Default filename as a convenience for technicians
            # who are accustomed to the original single-profile layout.
            if ($profile.Name -eq "Default") {
                Copy-Item -LiteralPath $chromeHtml -Destination (Join-Path $BrowserPath "Chrome_Bookmarks.html") -Force
            }
        }
        else {
            Write-Log "Could not convert Chrome bookmarks for profile '$($profile.Name)'" -Level Warning
        }
    }

    if ($exported -gt 0) {
        Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Success" -Details "$exported Chrome profile(s) exported as HTML"
    }
    else {
        Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Skipped" -Details "No Chrome bookmark files found"
    }

    return $exported
}

function Invoke-ChromePasswordExportPrompt {
    param(
        [string]$BrowserPath,
        [bool]$CanLaunchChromeForOriginalUser
    )

    $passwordExportPath = Join-Path $BrowserPath "Chrome\PasswordExport"
    New-Item -ItemType Directory -Path $passwordExportPath -Force | Out-Null

    Write-Host ""
    Write-Host "  Chrome passwords are protected by Windows and cannot be restored by copying the profile." -ForegroundColor Yellow
    Write-Host "  Chrome's own export is the supported transfer method: it will request Windows authentication." -ForegroundColor Yellow
    Write-Host "  Save the resulting CSV only in: $passwordExportPath" -ForegroundColor Cyan

    $exportNow = Read-Host "  Open Chrome Password Manager now to export passwords? (Y/N)"
    if ($exportNow -notmatch '^[Yy]') {
        Add-ManualTask -Task "Export Chrome Passwords" -Reason "Chrome passwords remain encrypted in the raw profile backup" -Instructions @"
On the old laptop, while signed in as the original Windows user:
1. Open Chrome > Passwords and autofill > Google Password Manager > Settings.
2. Under Export passwords, select Download file and complete the Windows authentication prompt.
3. Save the CSV only to: $passwordExportPath
4. On the new laptop, import it in Google Password Manager > Settings > Import passwords, then delete the CSV.
"@
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details "Native Chrome export declined; raw encrypted profile backup is included"
        return
    }

    if (-not $CanLaunchChromeForOriginalUser) {
        Write-Log "Cannot safely launch Chrome for the original profile from an elevated alternate-user session" -Level Warning
        Write-Host "  Run the native Chrome export from the original user's desktop and use the path above." -ForegroundColor Yellow
        Add-ManualTask -Task "Export Chrome Passwords" -Reason "Export is running under a different/elevated Windows user" -Instructions "Sign in as the original user, open Chrome's Google Password Manager > Settings > Export passwords, complete Windows authentication, and save the CSV to: $passwordExportPath"
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details "Must be exported in original user's Windows session"
        return
    }

    try {
        Start-Process "chrome.exe" "chrome://password-manager/settings" -ErrorAction Stop
        Write-Host "  Complete Chrome's export, choose the folder shown above, then return here." -ForegroundColor Gray
        [void](Read-Host "  Press Enter after saving the CSV (S to skip)")
    }
    catch {
        Write-Log "Could not open Chrome Password Manager: $_" -Level Warning
        Write-Host "  Open Chrome manually and use the folder shown above." -ForegroundColor Yellow
    }

    $csvFiles = @(Get-ChildItem -LiteralPath $passwordExportPath -Filter "*.csv" -File -Force -ErrorAction SilentlyContinue)
    if ($csvFiles.Count -gt 0) {
        Write-Log "Chrome password CSV captured: $($csvFiles.Count) file(s)" -Level Success
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Success" -Details "$($csvFiles.Count) CSV file(s) captured; plaintext - protect transfer package"
    }
    else {
        Write-Log "No Chrome password CSV was found in the designated folder" -Level Warning
        Add-ManualTask -Task "Export Chrome Passwords" -Reason "No CSV was saved to the transfer package" -Instructions "Use Chrome's Google Password Manager > Settings > Export passwords, complete Windows authentication, and save the CSV to: $passwordExportPath"
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details "No native Chrome password export captured"
    }
}

function Copy-BrowserData {
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Capturing browser data..." -Level Info
    
    $browserPath = Join-Path $DestinationBase "BrowserData"
    if (-not (Test-Path $browserPath)) {
        New-Item -ItemType Directory -Path $browserPath -Force | Out-Null
    }
    
    $localAppData = $Script:OriginalAppDataLocal
    
    # ========== CHROME ==========
    # Chrome data is split across every profile under User Data.  Keep a raw
    # archive with common disposable cache directories excluded, then export each profile's
    # bookmarks into Chrome's portable HTML format for reliable import.
    $chromeUserDataPath = Join-Path $localAppData "Google\Chrome\User Data"
    if (Test-Path -LiteralPath $chromeUserDataPath) {
        [void](Request-BrowserClose -ProcessName "chrome" -DisplayName "Google Chrome")
        [void](Export-ChromeBookmarks -ChromeUserDataPath $chromeUserDataPath -BrowserPath $browserPath)

        $chromeRawDestination = Join-Path $browserPath "Chrome\User Data"
        $chromeRawLog = Join-Path $DestinationBase "Logs\robocopy_chrome_user_data.log"
        $chromeCopyArgs = @($Script:Config.RobocopyArgs) + @(
            "/XD", "Cache", '"Code Cache"', "GPUCache", "ShaderCache", "GrShaderCache", "DawnCache", "Crashpad"
        )
        $result = Copy-WithProgress -Source $chromeUserDataPath `
                                    -Destination $chromeRawDestination `
                                    -FolderName "Chrome profile archive (all profiles)" `
                                    -LogPath $chromeRawLog `
                                    -RobocopyArgs $chromeCopyArgs
        if ($result.Status -eq "Success") {
            Write-Log "Chrome profile archive copied: $($result.FilesCopied) files" -Level Success
            Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Success" -Details "$($result.FilesCopied) files; common caches excluded; credentials remain Windows-protected"
        }
        else {
            Write-Log "Chrome profile archive copy completed with warnings" -Level Warning
            Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Warning" -Details "Check robocopy_chrome_user_data.log"
        }

        $canLaunchChromeForOriginalUser = (-not $Script:IsAdmin) -or ($Script:OriginalUserProfile -eq $env:USERPROFILE)
        Invoke-ChromePasswordExportPrompt -BrowserPath $browserPath -CanLaunchChromeForOriginalUser $canLaunchChromeForOriginalUser
    }
    else {
        Write-Log "Chrome not installed or no user data found" -Level Info
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

    [void](Request-BrowserClose -ProcessName "firefox" -DisplayName "Firefox")

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
