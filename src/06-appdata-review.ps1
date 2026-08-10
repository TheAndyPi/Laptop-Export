function Get-InstalledPrograms {
    # Read the machine's uninstall inventories from both registry views and
    # normalize them into a deduplicated list for comparison during import.
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Documenting installed programs..." -Level Info
    
    $programs = @()
    
    # 64-bit programs
    $programs += Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ReleaseType } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, @{ Name = 'SourceScope'; Expression = { 'Machine64' } }
    
    # 32-bit programs on 64-bit system
    $programs += Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ReleaseType } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, @{ Name = 'SourceScope'; Expression = { 'Machine32' } }
    
    # User-installed programs
    $programs += Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ReleaseType } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, @{ Name = 'SourceScope'; Expression = { 'CurrentUser' } }
    
    $programs = @($programs | ForEach-Object {
        [PSCustomObject]@{
            DisplayName = $_.DisplayName; DisplayVersion = $_.DisplayVersion; Publisher = $_.Publisher
            InstallDate = $_.InstallDate; SourceScope = $_.SourceScope
            MatchKey = Get-ProgramMatchKey -DisplayName $_.DisplayName -Publisher $_.Publisher
        }
    } | Sort-Object MatchKey, DisplayName -Unique)
    
    $settingsPath = Join-Path $DestinationBase "Settings"
    $programsFile = Join-Path $settingsPath "InstalledPrograms.json"
    $programs | ConvertTo-Json | Out-File $programsFile -Encoding UTF8
    
    # Also create a readable text file
    $programsTxt = Join-Path $settingsPath "InstalledPrograms.txt"
    $programs | Format-Table -AutoSize | Out-String | Out-File $programsTxt -Encoding UTF8
    
    $count = ($programs | Measure-Object).Count
    Write-Log "Documented $count installed programs" -Level Success
    Add-Result -Category "Settings" -Item "Installed Programs" -Status "Success" -Details "$count programs listed"
    
    return $programs
}

function ConvertTo-ProgramMatchPart {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' ')
}

function Get-ProgramMatchKey {
    param([string]$DisplayName, [string]$Publisher)
    return "$(ConvertTo-ProgramMatchPart $DisplayName)|$(ConvertTo-ProgramMatchPart $Publisher)"
}

function Get-AppDataCandidates {
    param(
        [string]$DestinationBase,
        [bool]$IncludeSizes = $true
    )

    $excludedNames = @('Microsoft', 'Packages', 'Temp', 'Temporary Internet Files', 'CrashDumps', 'SquirrelTemp', 'D3DSCache', 'ConnectedDevicesPlatform', 'Comms')
    $curated = @($Script:Config.AppDataRoaming.Keys + $Script:Config.AppDataLocal.Keys + 'Bluebeam')
    $candidates = [System.Collections.ArrayList]::new()
    foreach ($root in @(
        @{ Area = 'Roaming'; Path = $Script:OriginalAppDataRoaming },
        @{ Area = 'Local'; Path = $Script:OriginalAppDataLocal }
    )) {
        try {
            foreach ($folder in @(Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction Stop)) {
                if ($folder.Name -in $excludedNames) { continue }
                $covered = $curated -contains $folder.Name
                $size = 0L
                if ($IncludeSizes) {
                    try { $size = Get-FolderSizeBytes -Path $folder.FullName } catch { Write-Log "Could not size AppData candidate $($folder.FullName): $($_.Exception.Message)" -Level Warning }
                }
                [void]$candidates.Add([PSCustomObject]@{
                    Area = $root.Area; RelativePath = $folder.Name; FullPath = $folder.FullName; SizeBytes = $size
                    CoveredByCuratedBackup = $covered; AssociationHint = ConvertTo-ProgramMatchPart $folder.Name
                })
            }
        }
        catch {
            Write-Log "Could not enumerate $($root.Area) AppData candidates: $($_.Exception.Message)" -Level Warning
            Add-Result -Category 'Settings' -Item "AppData candidates ($($root.Area))" -Status 'Warning' -Details $_.Exception.Message
        }
    }
    $settingsPath = Join-Path $DestinationBase 'Settings'
    $path = Join-Path $settingsPath 'AppDataCandidates.json'
    @($candidates | Sort-Object Area, RelativePath) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    $textPath = Join-Path $settingsPath 'AppDataCandidates.txt'
    @($candidates | Sort-Object Area, RelativePath | ForEach-Object { "[$($_.Area)] $($_.RelativePath) | $(Format-FileSize $_.SizeBytes) | $(if ($_.CoveredByCuratedBackup) { 'already curated' } else { 'review candidate' })" }) | Set-Content -LiteralPath $textPath -Encoding UTF8
    $detail = if ($IncludeSizes) { "$($candidates.Count) review candidate(s) listed with sizes" } else { "$($candidates.Count) review candidate(s) listed (sizes skipped for Online speed)" }
    Add-Result -Category 'Settings' -Item 'AppData candidates' -Status 'Success' -Details $detail
    return @($candidates)
}

function Get-AdditionalAppDataCandidates {
    param([bool]$IncludeSizes = $true)
    $excludedNames = @('Microsoft', 'Packages', 'Temp', 'Temporary Internet Files', 'CrashDumps', 'SquirrelTemp', 'D3DSCache', 'ConnectedDevicesPlatform', 'Comms')
    $curated = @($Script:Config.AppDataRoaming.Keys + $Script:Config.AppDataLocal.Keys + 'Bluebeam', 'Bluebeam Software', 'Mozilla', 'Google')
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @(
        @{ Area = 'Roaming'; Path = $Script:OriginalAppDataRoaming },
        @{ Area = 'Local'; Path = $Script:OriginalAppDataLocal }
    )) {
        try {
            foreach ($folder in @(Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction Stop)) {
                if ($folder.Name -in $excludedNames -or $folder.Name -in $curated) { continue }
                if ($folder.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { continue }
                $sizeBytes = $null
                if ($IncludeSizes) {
                    try { $sizeBytes = Get-FolderSizeBytes -Path $folder.FullName }
                    catch {
                        Write-Log "Could not size additional $($root.Area) AppData folder '$($folder.FullName)': $($_.Exception.Message)" -Level Warning
                        Add-Result -Category 'Additional AppData' -Item "$($root.Area)\$($folder.Name)" -Status 'Warning' -Details 'Size unavailable'
                    }
                }
                [void]$candidates.Add([PSCustomObject]@{
                    Area = $root.Area; RelativePath = $folder.Name; FullPath = $folder.FullName; SizeBytes = $sizeBytes
                })
            }
        }
        catch {
            Write-Log "Could not enumerate $($root.Area) AppData folders for Advanced selection: $($_.Exception.Message)" -Level Warning
            Add-Result -Category 'Additional AppData' -Item "$($root.Area) candidates" -Status 'Warning' -Details $_.Exception.Message
        }
    }
    return @($candidates | Sort-Object Area, RelativePath)
}

function Start-AdditionalAppDataSizeJob {
    param([array]$Candidates)
    $paths = @($Candidates | ForEach-Object { $_.FullPath } | Where-Object { $_ } | Sort-Object -Unique)
    return Start-Job -ArgumentList (,$paths) -ScriptBlock {
        param([string[]]$FolderPaths)
        foreach ($path in $FolderPaths) {
            $bytes = 0L
            try {
                if (Test-Path -LiteralPath $path) {
                    # Do not collect every file into an array before adding
                    # its length.  AppData folders can contain hundreds of
                    # thousands of files, and the streaming measure keeps the
                    # selection screen responsive.
                    $measure = Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
                        Measure-Object -Property Length -Sum
                    $bytes = [long]$(if ($null -eq $measure.Sum) { 0 } else { $measure.Sum })
                }
            }
            catch { }
            [PSCustomObject]@{ Path = $path; Bytes = $bytes }
        }
    }
}

function Receive-AdditionalAppDataSizeJob {
    param([System.Management.Automation.Job]$Job, [array]$Candidates)
    if (-not $Job) { return $false }
    $updated = $false
    $sizes = @{}
    foreach ($result in @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)) {
        if ($result -and $result.Path) { $sizes[$result.Path] = [long]$result.Bytes; $updated = $true }
    }
    foreach ($candidate in $Candidates) {
        if ($sizes.ContainsKey($candidate.FullPath)) { $candidate.SizeBytes = $sizes[$candidate.FullPath] }
    }
    return $updated
}

function Show-AdditionalAppDataMenu {
    param([array]$Candidates, [bool]$Calculating, [bool]$Skipped, [System.Collections.Generic.HashSet[int]]$Selected = $null)
    Clear-StoScreen
    Write-Banner -Title 'Advanced AppData Selection' -Subtitle 'Select additional folders to include in this transfer'
    Write-Host '  Curated AppData items remain included automatically. Select only extra folders below.' -ForegroundColor DarkGray
    if ($Calculating) { Write-Host '  Calculating folder sizes in the background. Press R to refresh; the menu refreshes automatically when finished.' -ForegroundColor Cyan }
    elseif ($Skipped) { Write-Host '  Folder sizing was not completed; unsized folders display as unknown.' -ForegroundColor Yellow }
    Write-Host ''
    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        $item = $Candidates[$index]
        $sizeText = if ($null -eq $item.SizeBytes) { 'calculating...' } else { Format-FileSize $item.SizeBytes }
        $state = if ($Selected -and $Selected.Contains($index + 1)) { 'ON ' } else { 'OFF' }
        $color = if ($state -eq 'ON ') { 'Green' } else { 'DarkGray' }
        Write-Host "  [$($index + 1)] $state " -ForegroundColor $color -NoNewline
        Write-Host "$($item.Area.PadRight(7)) $($item.RelativePath.PadRight(32)) $sizeText" -ForegroundColor White
    }
    Write-Host ''
}

function Select-AdditionalAppData {
    # Draw the selection screen before recursive sizing starts so the
    # technician immediately sees what is being evaluated.
    $candidates = @(Get-AdditionalAppDataCandidates -IncludeSizes $false)
    if ($candidates.Count -eq 0) {
        Write-Host '  No additional Local or Roaming AppData folders were found.' -ForegroundColor Yellow
        return @()
    }

    $sizeJob = Start-AdditionalAppDataSizeJob -Candidates $candidates
    $Script:AdditionalAppDataSizeJob = $sizeJob
    $Script:AdditionalAppDataMenuCandidates = $candidates
    $Script:AdditionalAppDataSizeAutoRefreshed = $false
    $selectedNumbers = [System.Collections.Generic.HashSet[int]]::new()
    try {
        while ($true) {
            Show-AdditionalAppDataMenu -Candidates $Script:AdditionalAppDataMenuCandidates -Calculating ($Script:AdditionalAppDataSizeJob.State -eq 'Running') -Skipped $false -Selected $selectedNumbers
            Write-Host '  Enter a number to toggle it; [A] all; [N] none; [S] save; [R] refresh' -ForegroundColor Gray
            $answer = Read-MenuInputWithBackgroundRefresh -Prompt '' -Poll {
                $wasRunning = [bool]$Script:AdditionalAppDataSizeJob
                [void](Receive-AdditionalAppDataSizeJob -Job $Script:AdditionalAppDataSizeJob -Candidates $Script:AdditionalAppDataMenuCandidates)
                if ($wasRunning -and $Script:AdditionalAppDataSizeJob.State -ne 'Running' -and -not $Script:AdditionalAppDataSizeAutoRefreshed) {
                    $Script:AdditionalAppDataSizeAutoRefreshed = $true
                    return $true
                }
                return $false
            }
            if ($answer -eq '__MENU_AUTO_REFRESH__' -or $answer -match '^[Rr]$') { continue }
            if ($answer -match '^[Aa]$') { $selectedNumbers.Clear(); 1..$candidates.Count | ForEach-Object { [void]$selectedNumbers.Add($_) }; continue }
            if ($answer -match '^[Nn]$') { $selectedNumbers.Clear(); continue }
            if ($answer -match '^[Ss]$') { break }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
                if ($selectedNumbers.Contains($number)) { [void]$selectedNumbers.Remove($number) } else { [void]$selectedNumbers.Add($number) }
                continue
            }
            Write-Host '  Enter a listed number, A, N, S, or R.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 700
        }
        if ($sizeJob.State -eq 'Running') { Stop-Job -Job $sizeJob -ErrorAction SilentlyContinue }
    }
    finally {
        Remove-Job -Job $sizeJob -Force -ErrorAction SilentlyContinue
    }
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($number in $selectedNumbers) { [void]$selected.Add($candidates[$number - 1]) }
    return @($selected | Sort-Object Area, RelativePath -Unique)
}

function Copy-SelectedAdditionalAppData {
    param([string]$DestinationBase)

    foreach ($item in @($Script:SelectedAdditionalAppData)) {
        $itemName = "$($item.Area)\$($item.RelativePath)"
        if ($item.Area -notin @('Roaming', 'Local') -or [string]::IsNullOrWhiteSpace($item.RelativePath) -or
            $item.RelativePath -match '[\\/]') {
            Write-Log "Skipping invalid additional AppData selection '$itemName'." -Level Warning
            Add-Result -Category 'Additional AppData' -Item $itemName -Status 'Skipped' -Details 'Invalid selection path'
            continue
        }
        if (-not (Test-Path -LiteralPath $item.FullPath)) {
            Write-Log "Selected additional AppData folder '$itemName' no longer exists." -Level Warning
            Add-Result -Category 'Additional AppData' -Item $itemName -Status 'Skipped' -Details 'Source folder no longer exists'
            continue
        }
        try {
            $destination = Join-Path $DestinationBase "AppData\Additional\$($item.Area)\$($item.RelativePath)"
            $logPath = Join-Path $DestinationBase "Logs\robocopy_additional_appdata_$($item.Area)_$($item.RelativePath).log"
            $result = Copy-WithProgress -Source $item.FullPath -Destination $destination -FolderName "Additional AppData: $itemName" -LogPath $logPath -RobocopyArgs $Script:Config.RobocopyArgs
            Add-Result -Category 'Additional AppData' -Item $itemName -Status $result.Status -Details "$($result.FilesCopied) files; $(Format-FileSize $item.SizeBytes)"
        }
        catch {
            Write-Log "Could not copy additional AppData folder '$itemName': $($_.Exception.Message)" -Level Error
            Add-Result -Category 'Additional AppData' -Item $itemName -Status 'Error' -Details $_.Exception.Message
        }
    }
}

