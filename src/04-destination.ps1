# ============================================================================
# DESTINATION SELECTION
# ============================================================================

function Test-PathIsSameOrChild {
    param(
        [string]$Path,
        [string]$ParentPath
    )

    try {
        $destination = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]92)
        $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([char]92)
        $parentPrefix = $parent + [System.IO.Path]::DirectorySeparatorChar
        return $destination.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or
               $destination.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-DestinationIsWithinSourceProfile {
    param([string]$Path)

    if (-not (Test-PathIsSameOrChild -Path $Path -ParentPath $Script:OriginalUserProfile)) {
        return $false
    }

    # AppData itself is a safe export location because the collector only
    # copies selected AppData subfolders. Keep the three live AppData trees
    # protected, however, since placing the package inside one of them could
    # make a future broad AppData copy recurse into its own output.
    $appDataRoot = Join-Path $Script:OriginalUserProfile "AppData"
    if (Test-PathIsSameOrChild -Path $Path -ParentPath $appDataRoot) {
        foreach ($protectedRoot in @("Local", "Roaming", "LocalLow")) {
            if (Test-PathIsSameOrChild -Path $Path -ParentPath (Join-Path $appDataRoot $protectedRoot)) {
                return $true
            }
        }

        return $false
    }

    return $true
}

function Show-NativeWindowsFolderPicker {
    param([string]$InitialPath = "")

    # Use Windows' Common Item Dialog: the modern Explorer-style picker used
    # by desktop applications, rather than the legacy Shell tree dialog.
    try {
        if (-not ("Sto.NativeFolderPicker" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Sto {
    [Flags]
    internal enum FOS : uint {
        FORCEFILESYSTEM = 0x00000040,
        PATHMUSTEXIST = 0x00000800,
        PICKFOLDERS = 0x00000020
    }

    internal enum SIGDN : uint {
        FILESYSPATH = 0x80058000
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(SIGDN sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(FOS fos);
        void GetOptions(out FOS pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName(out IntPtr pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialog { }

    public static class NativeFolderPicker {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SHCreateItemFromParsingName(
            string path, IntPtr pbc, ref Guid riid, out IShellItem shellItem);

        public static string Pick(string initialPath) {
            IFileDialog dialog = (IFileDialog)new FileOpenDialog();
            try {
                FOS options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | FOS.PICKFOLDERS | FOS.FORCEFILESYSTEM | FOS.PATHMUSTEXIST);
                dialog.SetTitle("Choose the laptop transfer destination");
                dialog.SetOkButtonLabel("Select Folder");

                if (!String.IsNullOrEmpty(initialPath)) {
                    IShellItem initialFolder;
                    Guid iid = typeof(IShellItem).GUID;
                    if (SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid, out initialFolder) == 0) {
                        try { dialog.SetFolder(initialFolder); }
                        finally { Marshal.ReleaseComObject(initialFolder); }
                    }
                }

                const int ERROR_CANCELLED = unchecked((int)0x800704C7);
                int result = dialog.Show(IntPtr.Zero);
                if (result == ERROR_CANCELLED) return null;
                if (result != 0) Marshal.ThrowExceptionForHR(result);

                IShellItem selected;
                dialog.GetResult(out selected);
                try {
                    IntPtr path;
                    selected.GetDisplayName(SIGDN.FILESYSPATH, out path);
                    try { return Marshal.PtrToStringUni(path); }
                    finally { Marshal.FreeCoTaskMem(path); }
                }
                finally { Marshal.ReleaseComObject(selected); }
            }
            finally { Marshal.ReleaseComObject(dialog); }
        }
    }
}
'@ -ErrorAction Stop
        }

        return [Sto.NativeFolderPicker]::Pick($InitialPath)
    }
    catch {
        throw "Windows folder picker could not be opened: $($_.Exception.Message)"
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
    try {
        $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
    }
    catch {
        Write-Host "`nUnable to look for external drives: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "No files were copied. Resolve the Windows disk-service issue, then run the export again." -ForegroundColor Yellow
        return $null
    }

    $drives = @($logicalDisks | Where-Object {
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
        Write-Host "Connect an external drive and start the export again. No files were copied." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    for ($i = 0; $i -lt $drives.Count; $i++) {
        $color = if ($drives[$i].Type -eq "Removable") { "Cyan" } else { "White" }
        Write-Host "  [$($i + 1)] $($drives[$i].Display)" -ForegroundColor $color
    }
    Write-Host "`n  [0] Cancel`n" -ForegroundColor Gray

    do {
        $selection = Read-UserInput "Select target drive (1-$($drives.Count))"
        if ($selection -eq "0") { return $null }

        $index = 0
        if ([int]::TryParse($selection, [ref]$index)) {
            $index--
            if ($index -ge 0 -and $index -lt $drives.Count) {
                $selectedDrive = $drives[$index]
                $confirm = Read-UserInput "Proceed with $($selectedDrive.Display)? (Y/N)"
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
    Write-Host "  Recommended: use an approved network share that the new laptop can reach." -ForegroundColor Cyan
    Write-Host "  The export is staged and zipped locally, then uploaded as one ZIP when a network share is selected." -ForegroundColor DarkGray
    Write-Host "  If no share is available, use a temporary folder on C: with ample free space (for example C:\LaptopTransfers)." -ForegroundColor Gray
    Write-Host "  AppData itself is allowed; avoid Desktop, Downloads, OneDrive, and folders outside AppData\Local, AppData\Roaming, and AppData\LocalLow inside the profile." -ForegroundColor Yellow

    $selectedPath = $DestinationPath
    if (-not $selectedPath) {
        try {
            $initialPath = if (Test-Path $env:SystemDrive) { $env:SystemDrive } else { "" }
            $selectedPath = Show-NativeWindowsFolderPicker -InitialPath $initialPath
            if (-not $selectedPath) {
                Write-Host "Operation cancelled." -ForegroundColor Yellow
                return $null
            }
        }
        catch {
            # Keep a console fallback for constrained PowerShell hosts.
            Write-Host "Could not open the Windows folder picker: $_" -ForegroundColor Yellow
            $selectedPath = Read-UserInput "Enter destination folder path (blank to cancel)"
            if (-not $selectedPath) { return $null }
        }
    }

    # Reject before creating anything. AppData itself is allowed, but the
    # active Local/Roaming/LocalLow trees and all other profile locations are
    # protected from receiving the transfer package.
    if (Test-DestinationIsWithinSourceProfile -Path $selectedPath) {
        Write-Host "The destination is inside a source folder being exported." -ForegroundColor Red
        Write-Host "Choose AppData itself or a folder outside AppData\Local, AppData\Roaming, and AppData\LocalLow. No files were copied." -ForegroundColor Yellow
        return $null
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
        Write-Host "The destination is inside a source folder being exported." -ForegroundColor Red
        Write-Host "Choose AppData itself or a folder outside AppData\Local, AppData\Roaming, and AppData\LocalLow. No files were copied." -ForegroundColor Yellow
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

function Get-TransferPayloadEstimate {
    $sizes = @{}
    foreach ($key in @("UserData","Downloads","AppData","LotusNotes","SystemSettings","InstalledPrograms","Printers","Chrome","Firefox","Edge","OneDrive")) {
        $sizes[$key] = [long]0
    }

    if ($Script:Config.Backup.UserData) {
        foreach ($folder in $Script:Config.UserFolders) {
            if ($folder -eq "Downloads") { continue }
            $bytes = Get-FolderSizeBytes (Join-Path $Script:OriginalUserProfile $folder)
            $sizes.UserData += $bytes
        }
    }
    if ($Script:Config.Backup.Downloads) {
        $sizes.Downloads = Get-FolderSizeBytes (Join-Path $Script:OriginalUserProfile "Downloads")
    }

    if ($Script:Config.Backup.AppData) {
        foreach ($path in $Script:Config.BluebeamPaths) {
            $candidate = Join-Path $Script:OriginalAppDataRoaming $path
            if (Test-Path -LiteralPath $candidate) { $sizes.AppData += Get-FolderSizeBytes $candidate; break }
        }
        foreach ($path in $Script:Config.AppDataRoaming.Values) {
            $sizes.AppData += Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataRoaming $path)
        }
    }

    if ($Script:Config.Backup.LotusNotes -and $Script:Config.Backup.AppData -and
        -not ($Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.SkipLotusNotes)) {
        $sizes.LotusNotes = Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataLocal "Lotus")
    }
    if ($Script:Config.Backup.Chrome -eq "FullProfile") {
        $sizes.Chrome = Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataLocal "Google\Chrome\User Data")
    }
    elseif ($Script:Config.Backup.Chrome -eq "BookmarksAndPasswords") {
        $chromeRoot = Join-Path $Script:OriginalAppDataLocal "Google\Chrome\User Data"
        $sizes.Chrome = [long]((Get-ChildItem -LiteralPath $chromeRoot -Recurse -File -Filter "Bookmarks" -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
    }
    if ($Script:Config.Backup.Firefox) {
        $sizes.Firefox = (Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataRoaming "Mozilla\Firefox")) +
                          (Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataLocal "Mozilla\Firefox"))
    }
    if ($Script:Config.Backup.Edge) {
        $edgeRoot = Join-Path $Script:OriginalAppDataLocal "Microsoft\Edge\User Data"
        $sizes.Edge = [long]((Get-ChildItem -LiteralPath $edgeRoot -Recurse -File -Filter "Bookmarks" -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
    }

    [PSCustomObject]@{
        ItemBytes = $sizes
        TotalBytes = [long](($sizes.Values | Measure-Object -Sum).Sum)
    }
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

function Test-NetworkDestination {
    param([string]$Path)

    # UNC paths are always network destinations. For mapped drives, consult
    # the logical-drive type instead of assuming every drive letter is local.
    if ($Path -like "\\*") { return $true }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSDrive -and $item.PSDrive.Root -like "\\*") { return $true }

        if ($item.PSDrive -and $item.PSDrive.Name -match "^[A-Za-z]$") {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($item.PSDrive.Name):'" -ErrorAction Stop
            return $disk.DriveType -eq 4
        }
    }
    catch { }

    return $false
}

function Test-ArchiveAbortRequested {
    try {
        if ([Console]::KeyAvailable) {
            return ([Console]::ReadKey($true).Key -eq [ConsoleKey]::S)
        }
    }
    catch { }
    return $false
}

function Write-ArchiveProgress {
    param([string]$Label, [long]$Completed, [long]$Total, [datetime]$StartedAt)

    $percent = if ($Total -gt 0) { [math]::Min(100, [math]::Round(($Completed / $Total) * 100)) } else { 0 }
    $width = 34
    $filled = [math]::Round(($percent / 100) * $width)
    $bar = ([string]$Script:Theme.Bar.Full * $filled) + ([string]$Script:Theme.Bar.Light * ($width - $filled))
    $elapsed = (Get-Date) - $StartedAt
    $speed = if ($elapsed.TotalSeconds -gt 0) { $Completed / $elapsed.TotalSeconds } else { 0 }
    $remaining = [math]::Max([long]0, [long]($Total - $Completed))
    $eta = if ($speed -gt 0) { Format-RemainingTime ($remaining / $speed) } else { "calculating..." }
    Write-Host "`r    $Label  $bar $($percent.ToString().PadLeft(3))%  $(Format-FileSize $Completed) / $(Format-FileSize $Total)  $(Format-FileSize $speed)/s  ETA $eta   " -NoNewline
}

function Clear-ArchiveProgress {
    Write-Host "`r$(' ' * 160)`r" -NoNewline
}

function Publish-TransferArchive {
    param(
        [string]$ArchivePath,
        [string]$DestinationFolder,
        [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        Write-Log "Cannot upload ZIP archive because it was not created: $ArchivePath" -Level Error
        return $null
    }

    $archiveName = Split-Path -Path $ArchivePath -Leaf
    $destinationArchive = Join-Path $DestinationFolder $archiveName
    if (Test-Path -LiteralPath $destinationArchive) {
        Write-Log "Network ZIP upload skipped because the target already exists: $destinationArchive" -Level Warning
        Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Warning" -Details "Target already exists: $destinationArchive"
        return $null
    }

    try {
        $sourceFolder = Split-Path -Path $ArchivePath -Parent
        $arguments = "`"$sourceFolder`" `"$DestinationFolder`" `"$archiveName`" /Z /J /R:2 /W:3 /NP /NDL /NFL /NJH /NJS /LOG:`"$LogPath`""
        Write-Host "`n  Uploading ZIP archive to network destination..." -ForegroundColor Cyan
        Write-Log "Uploading ZIP archive to network destination: $destinationArchive" -Level Info
        $sourceSize = [long](Get-Item -LiteralPath $ArchivePath -ErrorAction Stop).Length
        Write-Host "    $(Format-FileSize $sourceSize). Press S to cancel the ZIP upload." -ForegroundColor DarkGray
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "robocopy.exe"
        $pinfo.Arguments = $arguments
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pinfo
        if (-not $process.Start()) { throw "Could not start ZIP upload." }

        $uploadStartedAt = Get-Date
        $aborted = $false
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            $uploadedBytes = if (Test-Path -LiteralPath $destinationArchive -PathType Leaf) {
                [long](Get-Item -LiteralPath $destinationArchive -ErrorAction SilentlyContinue).Length
            }
            else { [long]0 }
            Write-ArchiveProgress -Label "UPLOAD" -Completed $uploadedBytes -Total $sourceSize -StartedAt $uploadStartedAt
            if (Test-ArchiveAbortRequested) {
                $aborted = $true
                $process.Kill()
                $process.WaitForExit()
                break
            }
        }
        if (-not $aborted) {
            Write-ArchiveProgress -Label "UPLOAD" -Completed $sourceSize -Total $sourceSize -StartedAt $uploadStartedAt
        }
        Clear-ArchiveProgress
        if ($aborted) {
            Remove-Item -LiteralPath $destinationArchive -Force -ErrorAction SilentlyContinue
            Write-Host "    $($Script:Theme.Glyphs.WARN) ZIP upload cancelled; incomplete upload removed." -ForegroundColor Yellow
            Write-Log "ZIP archive upload cancelled by operator; incomplete destination file removed" -Level Warning
            Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Skipped" -Details "Cancelled by operator; incomplete upload removed"
            return $null
        }

        $destinationSize = if (Test-Path -LiteralPath $destinationArchive -PathType Leaf) {
            (Get-Item -LiteralPath $destinationArchive -ErrorAction Stop).Length
        }
        else { -1 }

        if ($process.ExitCode -lt 8 -and $sourceSize -eq $destinationSize) {
            Write-Log "ZIP archive uploaded and size verified: $destinationArchive" -Level Success
            Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Success" -Details "Uploaded and size verified: $archiveName"
            return $destinationArchive
        }

        throw "Robocopy exit code $($process.ExitCode); source size $sourceSize, destination size $destinationSize"
    }
    catch {
        Write-Log "Could not upload ZIP archive to network destination: $_" -Level Error
        Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Error" -Details $_.Exception.Message
        return $null
    }
}

function New-TransferArchive {
    param([string]$TransferBase)

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
        $files = @(Get-ChildItem -LiteralPath $TransferBase -Recurse -File -Force -ErrorAction Stop)
        $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        $startedAt = Get-Date
        $completedBytes = [long]0
        $lastProgressAt = [datetime]::MinValue
        $aborted = $false
        Write-Host "    $($files.Count) files / $(Format-FileSize $totalBytes). Press S to cancel ZIP creation." -ForegroundColor DarkGray
        # ZipArchive/ZipArchiveMode live in System.IO.Compression, while the
        # ZipFile helper lives in System.IO.Compression.FileSystem. Windows
        # PowerShell does not always load the former when the latter is loaded.
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Create)
        $buffer = New-Object byte[] 1048576
        try {
            foreach ($file in $files) {
                $relativePath = $file.FullName.Substring($TransferBase.Length).TrimStart([char]92)
                $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
                $input = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                $output = $entry.Open()
                try {
                    while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $output.Write($buffer, 0, $read)
                        $completedBytes += $read
                        if ((Get-Date) - $lastProgressAt -gt [TimeSpan]::FromMilliseconds(250)) {
                            Write-ArchiveProgress -Label "ZIP" -Completed $completedBytes -Total $totalBytes -StartedAt $startedAt
                            $lastProgressAt = Get-Date
                        }
                        if (Test-ArchiveAbortRequested) {
                            $aborted = $true
                            break
                        }
                    }
                }
                finally {
                    $output.Dispose()
                    $input.Dispose()
                }
                if ($aborted) { break }
            }
        }
        finally {
            $archive.Dispose()
        }

        if (-not $aborted) {
            Write-ArchiveProgress -Label "ZIP" -Completed $totalBytes -Total $totalBytes -StartedAt $startedAt
        }
        Clear-ArchiveProgress
        if ($aborted) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            Write-Host "    $($Script:Theme.Glyphs.WARN) ZIP creation cancelled. The transfer folder was kept." -ForegroundColor Yellow
            Write-Log "ZIP creation cancelled by operator; transfer folder retained at $TransferBase" -Level Warning
            Add-Result -Category "Package" -Item $archiveName -Status "Skipped" -Details "ZIP creation cancelled by operator; transfer folder retained"
            return $null
        }

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
    Write-StoLogo
    Write-Section "Transfer mode"
    Write-Host "  [1] Local  " -ForegroundColor Cyan -NoNewline
    Write-Host "- full copy (USB / on-site)" -ForegroundColor DarkGray
    Write-Host "  [2] Online " -ForegroundColor Cyan -NoNewline
    Write-Host "- trimmed for slow/remote links (Downloads disabled by default, skips Lotus)" -ForegroundColor DarkGray
    Write-Host "  [3] Administrator" -ForegroundColor Cyan -NoNewline
    Write-Host "- restart with administrator privileges" -ForegroundColor DarkGray
    Write-Host ""
    do {
        $m = Read-UserInput "  Select transfer mode (1-3)"
        if ($m -eq "1") { $Script:Config.TransferMode = "Local"; break }
        if ($m -eq "2") { $Script:Config.TransferMode = "Online"; break }
        if ($m -eq "3") { Restart-AsAdministrator; continue }
        Write-Host "  Invalid selection." -ForegroundColor Red
    } while ($true)
}

