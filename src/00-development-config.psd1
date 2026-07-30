@{
    # Development-time defaults. Edit these values, then run
    # Build-Deployment.ps1 to embed the configuration in Export-LaptopData.ps1.
    # Every backup stage is enabled by default.
    Backup = @{
        UserData          = $true
        # Optional comprehensive profile copy. It excludes data captured by
        # the standard user-folder, AppData, and browser stages.
        EntireUserProfile = $false
        AdditionalAppData = $false
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        AppDataCandidateInventory = $true
        Printers          = $true
        Chrome            = $true
        Firefox           = $true
        Edge              = $true
        OneDrive          = $true
        DesktopLayout     = $true
        TaskbarLayout     = $true
        DefaultApps       = $true
    }

    Import = @{
        # Restores AppData\Lotus_Local when it is present in a transfer package.
        LotusNotes = $true

        # Deletes Printers\Printers.printerExport only after a successful
        # PrintBRM restore and completion of the generated import script.
        DeletePrintBrmAfterImport = $true

        # When enabled, the normal user-context import offers to run the
        # separate elevated helper after all user-scoped restoration finishes.
        EnableAdminHelper = $false
        AppComparison = $true
        AppDataReview = $true
        # These technical uninstall entries are excluded from the user-facing
        # missing-app report. Add patterns here when a new managed runtime or
        # driver should not become a handoff action.
        AppComparisonExcludePatterns = @(
            '^Microsoft Visual C\+\+', '^Microsoft \.NET', '^Microsoft Windows Desktop Runtime', '^Microsoft ASP\.NET Core',
            '^Microsoft Edge( WebView2 Runtime| Update)?$', '^Microsoft Update Health Tools', '^Microsoft OneDrive',
            '^Microsoft Teams Meeting Add-in', '^Windows (Desktop Runtime|Software Development Kit)', '^KB\d+',
            'Driver', 'Firmware', 'Lenovo (System Update|Vantage Service|USB|LAN|Dock)', 'Intel.*(Driver|Component)',
            'Realtek.*(Driver|Audio)', 'NVIDIA.*(Driver|FrameView)', 'AMD.*(Driver|Software)'
        )

        # At the end of an import, the report always opens.  The technician
        # can optionally open this standard handoff set as well.  Future
        # additions only require another target/alternative here; no importer
        # code changes are needed.  Desktop shortcuts are checked in the user,
        # OneDrive, and Public Desktop folders before command fallbacks.
        PostImportLaunch = @{
            Enabled = $true
            DesktopFolders = @('Desktop', 'OneDrive - STO Building Group\Desktop', 'C:\Users\Public\Desktop')
            Targets = @(
                @{ Name = 'PDF application'; Alternatives = @(
                    @{ Name = 'Adobe Acrobat'; DesktopShortcuts = @('Adobe Acrobat.lnk'); Commands = @('Acrobat.exe', 'AcroRd32.exe') },
                    @{ Name = 'Bluebeam Revu'; DesktopShortcuts = @('Bluebeam Revu.lnk', 'Bluebeam Revu 21.lnk'); Commands = @('Revu.exe') }
                ) },
                @{ Name = 'Classic Outlook'; Alternatives = @(@{ Name = 'Classic Outlook'; DesktopShortcuts = @('Outlook.lnk'); Commands = @('OUTLOOK.EXE') }) },
                @{ Name = 'Microsoft Teams'; Alternatives = @(@{ Name = 'Microsoft Teams'; DesktopShortcuts = @('Microsoft Teams.lnk', 'Teams.lnk'); Commands = @('ms-teams.exe', 'Teams.exe') }) },
                @{ Name = 'Cisco Secure Client'; Alternatives = @(@{ Name = 'Cisco Secure Client'; DesktopShortcuts = @('Cisco Secure Client.lnk') }) },
                @{ Name = 'CMiC'; Alternatives = @(@{ Name = 'CMiC'; DesktopShortcuts = @('CMiC.lnk') }) },
                @{ Name = 'Microsoft Edge'; Alternatives = @(@{ Name = 'Microsoft Edge'; DesktopShortcuts = @('Microsoft Edge.lnk'); Commands = @('msedge.exe') }) },
                @{ Name = 'STOBG Intranet'; Alternatives = @(@{ Name = 'STOBG Intranet'; DesktopShortcuts = @('STOBG Intranet.lnk', 'STO Intranet.lnk') }) },
                @{ Name = 'Knowledge Exchange'; Alternatives = @(@{ Name = 'Knowledge Exchange'; DesktopShortcuts = @('Knowledge Exchange.lnk') }) },
                @{ Name = 'Freshservice'; Alternatives = @(@{ Name = 'Freshservice'; DesktopShortcuts = @('Freshservice.url') }) },
                @{ Name = 'Firefox'; Alternatives = @(@{ Name = 'Firefox'; DesktopShortcuts = @('Firefox.lnk'); Commands = @('firefox.exe') }) },
                @{ Name = 'Google Chrome'; Alternatives = @(@{ Name = 'Google Chrome'; DesktopShortcuts = @('Google Chrome.lnk'); Commands = @('chrome.exe') }) },
                @{ Name = 'HR Hub'; Alternatives = @(@{ Name = 'HR Hub'; DesktopShortcuts = @('HR Hub.lnk') }) }
            )
        }
    }

    Export = @{
        # When enabled, request UAC approval after the technician confirms
        # Transfer Settings. It is off by default to avoid an early prompt.
        RequestAdministratorPrivileges = $false
    }

    # These values override the regular Import defaults when the technician
    # selects an Online transfer. They can still be changed for one transfer
    # in the runtime settings menu.
    Online = @{
        # Online transfers warn before starting when selected payload exceeds this size.
        MaxTransferGB = 5
        # Set true only when the technician deliberately wants Downloads above the cap.
        OverrideDownloadsCap = $false
        # Online transfers create a ZIP beside the transfer folder by default.
        CreateZipArchive = $true

        # Build network-bound packages in the transferring user's Local AppData,
        # then upload one ZIP instead of thousands of small network writes.
        StageNetworkTransfersLocally = $true

        # Advanced Online controls. Keep only portable Chrome bookmarks and
        # the optional native password CSV by default; a raw profile archive
        # can be enabled for recovery/reference when its estimated size fits.
        IncludeChromeProfileArchive = $false
        IncludeAdditionalUserFolders = $false
        AdditionalFolderCapGB = 1
        IncludeOcsDocuments = $false
        DetailedAppDataCandidateInventory = $false

        Import = @{
            LotusNotes                  = $true
            DeletePrintBrmAfterImport   = $true
            EnableAdminHelper            = $false
            AppComparison                = $true
            AppDataReview                = $true
        }
    }
}
