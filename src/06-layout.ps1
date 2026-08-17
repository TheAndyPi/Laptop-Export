function Get-ShortcutMetadata {
    param([System.IO.FileInfo]$File, [int]$Ordinal = 0)

    $item = [ordered]@{
        Name = $File.Name; Extension = $File.Extension.ToLowerInvariant(); Sha256 = $null
        TargetPath = $null; Arguments = $null; WorkingDirectory = $null; IconLocation = $null; Ordinal = $Ordinal
    }
    try { $item.Sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    if ($item.Extension -eq '.lnk') {
        try {
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($File.FullName)
            $item.TargetPath = $shortcut.TargetPath; $item.Arguments = $shortcut.Arguments
            $item.WorkingDirectory = $shortcut.WorkingDirectory; $item.IconLocation = $shortcut.IconLocation
        } catch { Write-Log "Could not inspect shortcut '$($File.Name)': $($_.Exception.Message)" -Level Warning }
    }
    return [PSCustomObject]$item
}

function Backup-TaskbarLayout {
    param([string]$DestinationBase)

    $settingsPath = Join-Path $DestinationBase 'Settings'
    $sourcePath = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $packagePath = Join-Path $settingsPath 'TaskbarLayout'
    try {
        $pins = @()
        $taskbandValues = @{}
        $taskbandPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        if (Test-Path -LiteralPath $taskbandPath) {
            $taskbandProperties = Get-ItemProperty -LiteralPath $taskbandPath -ErrorAction SilentlyContinue
            foreach ($property in @($taskbandProperties.PSObject.Properties | Where-Object { $_.Name -in @('Favorites', 'FavoritesResolve') -and $_.Value -is [byte[]] })) {
                $taskbandValues[$property.Name] = [Convert]::ToBase64String([byte[]]$property.Value)
            }
        }
        if (Test-Path -LiteralPath $sourcePath) {
            New-Item -ItemType Directory -Path $packagePath -Force | Out-Null
            $ordinal = 0
            # Taskband contains the authoritative pin order. Keep the link
            # inventory independent of alphabetical file-name sorting so it
            # cannot obscure that source ordering during restoration.
            foreach ($file in @(Get-ChildItem -LiteralPath $sourcePath -File -Force | Where-Object { $_.Name -notmatch 'Microsoft Store|WindowsStore' })) {
                $ordinal++; Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $packagePath $file.Name) -Force -ErrorAction Stop
                $pins += Get-ShortcutMetadata -File $file -Ordinal $ordinal
            }
        }
        [PSCustomObject]@{ CaptureDate = (Get-Date).ToString('o'); Pins = @($pins); SourcePath = $sourcePath; TaskbandValues = $taskbandValues; MicrosoftStoreExcluded = $true } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $settingsPath 'TaskbarLayout.json') -Encoding UTF8
        Add-Result -Category 'Settings' -Item 'Taskbar Layout' -Status 'Success' -Details "$($pins.Count) pinned app shortcut(s) captured"
        Write-Log "Taskbar layout captured: $($pins.Count) pin(s)" -Level Success
    } catch {
        Write-Log "Taskbar layout capture failed: $($_.Exception.Message)" -Level Warning
        Add-Result -Category 'Settings' -Item 'Taskbar Layout' -Status 'Warning' -Details $_.Exception.Message
    }
}

function Backup-DefaultApps {
    param([string]$DestinationBase)

    $settingsPath = Join-Path $DestinationBase 'Settings'
    try {
        $associations = @()
        $roots = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'; Type = 'FileExtension' },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'; Type = 'Protocol' }
        )
        foreach ($root in $roots) {
            foreach ($key in @(Get-ChildItem -Path $root.Path -ErrorAction SilentlyContinue)) {
                $choice = Get-ItemProperty -LiteralPath (Join-Path $key.PSPath 'UserChoice') -ErrorAction SilentlyContinue
                if ($choice -and $choice.ProgId) {
                    $associations += [PSCustomObject]@{ Name = $key.PSChildName; Type = $root.Type; ProgId = $choice.ProgId }
                }
            }
        }
        $associations = @($associations | Sort-Object Type, Name -Unique)
        [PSCustomObject]@{ CaptureDate = (Get-Date).ToString('o'); Associations = $associations } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $settingsPath 'DefaultApps.json') -Encoding UTF8
        Add-Result -Category 'Settings' -Item 'Default Apps' -Status 'Success' -Details "$($associations.Count) explicit association(s) captured"
        Write-Log "Default app inventory captured: $($associations.Count) association(s)" -Level Success
    } catch {
        Write-Log "Default app inventory capture failed: $($_.Exception.Message)" -Level Warning
        Add-Result -Category 'Settings' -Item 'Default Apps' -Status 'Warning' -Details $_.Exception.Message
    }
}
