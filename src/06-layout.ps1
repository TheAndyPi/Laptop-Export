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

function Initialize-DesktopLayoutInterop {
    # The shell registry cache is resolution-specific and does not reliably
    # move visible icons on current Windows builds. Use Explorer's supported
    # IFolderView API to capture each displayed item's actual coordinates.
    if ('StoDesktopLayoutInterop' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;

public sealed class StoDesktopPosition {
    public string Name { get; set; }
    public int X { get; set; }
    public int Y { get; set; }
}
public sealed class StoDesktopRestoreResult {
    public int Positioned { get; set; }
    public string[] Missing { get; set; }
}
public static class StoDesktopLayoutInterop {
    const int SWC_DESKTOP = 8, SWFO_NEEDDISPATCH = 1;
    static object GetView() {
        // Do not use C# dynamic here. Older Windows PowerShell installations
        // may not ship Microsoft.CSharp.RuntimeBinder, preventing compilation.
        object app = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application"));
        object windows = app.GetType().InvokeMember("Windows", BindingFlags.GetProperty, null, app, null);
        object[] findArguments = { Type.Missing, Type.Missing, SWC_DESKTOP, 0, SWFO_NEEDDISPATCH };
        object disp = windows.GetType().InvokeMember("FindWindowSW", BindingFlags.InvokeMethod, null, windows, findArguments);
        var provider = (IServiceProvider)disp;
        var service = new Guid("4c96be40-915c-11cf-99d3-00aa004ae837");
        var browser = (IShellBrowser)provider.QueryService(service, typeof(IShellBrowser).GUID);
        return browser.QueryActiveShellView();
    }
    public static StoDesktopPosition[] Capture() {
        var view = (IFolderView)GetView(); var view2 = (IFolderView2)view;
        var positions = new List<StoDesktopPosition>();
        for (int i = 0; i < view.ItemCount(); i++) {
            var shellItem = view2.GetItem(i, typeof(IShellItem).GUID);
            var name = shellItem.GetDisplayName(SIGDN.SIGDN_NORMALDISPLAY);
            var pidl = view.Item(i); POINT pt; view.GetItemPosition(pidl, out pt);
            positions.Add(new StoDesktopPosition { Name = name, X = pt.x, Y = pt.y });
        }
        return positions.ToArray();
    }
    public static StoDesktopRestoreResult Restore(StoDesktopPosition[] saved, double scaleX, double scaleY) {
        var view = (IFolderView)GetView(); var view2 = (IFolderView2)view;
        var current = new Dictionary<string, IntPtr>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < view.ItemCount(); i++) {
            var item = view2.GetItem(i, typeof(IShellItem).GUID);
            var name = item.GetDisplayName(SIGDN.SIGDN_NORMALDISPLAY);
            if (!String.IsNullOrEmpty(name) && !current.ContainsKey(name)) { current.Add(name, view.Item(i)); }
        }
        var missing = new List<string>(); int positioned = 0;
        foreach (var savedItem in saved ?? new StoDesktopPosition[0]) {
            IntPtr pidl;
            if (String.IsNullOrEmpty(savedItem.Name) || !current.TryGetValue(savedItem.Name, out pidl)) { missing.Add(savedItem.Name ?? "(unnamed)"); continue; }
            var point = new POINT { x = (int)Math.Round(savedItem.X * scaleX), y = (int)Math.Round(savedItem.Y * scaleY) };
            view.SelectAndPositionItems(1, new IntPtr[] { pidl }, new POINT[] { point }, SVSIF.SVSI_POSITIONITEM);
            positioned++;
        }
        return new StoDesktopRestoreResult { Positioned = positioned, Missing = missing.ToArray() };
    }
    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IServiceProvider { [return: MarshalAs(UnmanagedType.IUnknown)] object QueryService([MarshalAs(UnmanagedType.LPStruct)] Guid service, [MarshalAs(UnmanagedType.LPStruct)] Guid riid); }
    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellBrowser { void _VtblGap1_12(); [return: MarshalAs(UnmanagedType.IUnknown)] object QueryActiveShellView(); }
    [ComImport, Guid("cde725b0-ccc9-4519-917e-325d72fab4ce"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFolderView {
        void _VtblGap1_3(); IntPtr Item(int index); int ItemCount(uint flags = 0); void _VtblGap2_3();
        void GetItemPosition(IntPtr pidl, out POINT point); void _VtblGap1_4();
        void SelectAndPositionItems(int count, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] IntPtr[] pidls, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] POINT[] points, SVSIF flags);
    }
    [ComImport, Guid("1af3a467-214f-4298-908e-06b03e0b39f9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFolderView2 { void _VtblGap1_26(); IShellItem GetItem(int index, [MarshalAs(UnmanagedType.LPStruct)] Guid riid); }
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem { [return: MarshalAs(UnmanagedType.IUnknown)] object BindToHandler(System.Runtime.InteropServices.ComTypes.IBindCtx context, [MarshalAs(UnmanagedType.LPStruct)] Guid bhid, [MarshalAs(UnmanagedType.LPStruct)] Guid riid); IShellItem GetParent(); [return: MarshalAs(UnmanagedType.LPWStr)] string GetDisplayName(SIGDN sigdn); }
    struct POINT { public int x; public int y; }
    enum SIGDN { SIGDN_NORMALDISPLAY }
    [Flags] enum SVSIF { SVSI_POSITIONITEM = 0x80 }
}
'@ -ErrorAction Stop
}

function Backup-DesktopLayout {
    param([string]$DestinationBase)

    $settingsPath = Join-Path $DestinationBase 'Settings'
    $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    try {
        $shortcuts = @(Get-ChildItem -LiteralPath $desktopPath -File -Force -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.lnk', '.url') } |
            Sort-Object Name | ForEach-Object -Begin { $ordinal = 0 } -Process { $ordinal++; Get-ShortcutMetadata -File $_ -Ordinal $ordinal })
        $desktopBagPath = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
        $desktopShellValues = @{}
        if (Test-Path -LiteralPath $desktopBagPath) {
            $bag = Get-ItemProperty -LiteralPath $desktopBagPath -ErrorAction SilentlyContinue
            foreach ($property in @($bag.PSObject.Properties | Where-Object { $_.Name -like 'ItemPos*' -and $_.Value -is [byte[]] })) {
                $desktopShellValues[$property.Name] = [Convert]::ToBase64String([byte[]]$property.Value)
            }
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $desktopItems = @()
        try {
            Initialize-DesktopLayoutInterop
            $desktopItems = @([StoDesktopLayoutInterop]::Capture())
            Write-Log "Desktop shell coordinates captured: $($desktopItems.Count) item(s)" -Level Info
        }
        catch { Write-Log "Desktop shell-coordinate capture unavailable: $($_.Exception.Message)" -Level Warning }
        [PSCustomObject]@{
            CaptureDate = (Get-Date).ToString('o'); DesktopPath = $desktopPath; CoordinateRestore = 'ScaledShellItemCoordinates'
            Shortcuts = $shortcuts; ShellPositionValues = $desktopShellValues
            DesktopItems = $desktopItems
            SourceWorkArea = @{ X = $workArea.X; Y = $workArea.Y; Width = $workArea.Width; Height = $workArea.Height }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $settingsPath 'DesktopLayout.json') -Encoding UTF8
        Add-Result -Category 'Settings' -Item 'Desktop Layout' -Status 'Success' -Details "$($desktopItems.Count) visible item position(s); $($shortcuts.Count) shortcut(s) captured"
        Write-Log "Desktop layout captured: $($desktopItems.Count) visible item(s), $($shortcuts.Count) shortcut(s)" -Level Success
    } catch {
        Write-Log "Desktop layout capture failed: $($_.Exception.Message)" -Level Warning
        Add-Result -Category 'Settings' -Item 'Desktop Layout' -Status 'Warning' -Details $_.Exception.Message
    }
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
