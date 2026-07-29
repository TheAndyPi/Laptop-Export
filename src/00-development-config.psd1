@{
    # Development-time defaults. Edit these values, then run
    # Build-Deployment.ps1 to embed the configuration in Export-LaptopData.ps1.
    # Every backup stage is enabled by default.
    Backup = @{
        UserData          = $true
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        Chrome            = $true
        Firefox           = $true
        Edge              = $true
        OneDrive          = $true
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

        Import = @{
            LotusNotes                  = $true
            DeletePrintBrmAfterImport   = $true
            EnableAdminHelper            = $false
        }
    }
}
