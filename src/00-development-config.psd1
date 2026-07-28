@{
    # Development-time defaults. Edit these values, then run
    # Build-Deployment.ps1 to embed the configuration in Export-LaptopData.ps1.
    # Every backup stage is enabled by default.
    Backup = @{
        UserData          = $true
        AppData           = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        BrowserData       = $true
        # Controls Chrome only; Edge and Firefox stay enabled when this is false.
        Chrome            = $true
        OneDrive          = $true
    }

    Import = @{
        # Restores AppData\Lotus_Local when it is present in a transfer package.
        LotusNotes = $true

        # Restores the Firefox profile and its local companion data.
        Firefox = $true

        # Deletes Printers\Printers.printerExport only after a successful
        # PrintBRM restore and completion of the generated import script.
        DeletePrintBrmAfterImport = $true
    }

    # These values override the regular Import defaults when the technician
    # selects an Online transfer. They can still be changed for one transfer
    # in the runtime settings menu.
    Online = @{
        # Online transfers create a ZIP beside the transfer folder by default.
        CreateZipArchive = $true

        # Build network-bound transfer packages on the local system drive, then
        # upload one ZIP instead of thousands of small files over the network.
        StageNetworkTransfersLocally = $true

        Import = @{
            LotusNotes                  = $true
            Firefox                     = $true
            DeletePrintBrmAfterImport   = $true
        }
    }
}
