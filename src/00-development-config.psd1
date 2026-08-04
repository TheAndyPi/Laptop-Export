@{
    # Development-time defaults. Edit these values, then run
    # Build-Deployment.ps1 to embed the configuration in Export-LaptopData.ps1.
    Backup = @{
        UserData          = $true
        Downloads         = $true
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        # Off, BookmarksAndPasswords, or FullProfile. The lightweight option
        # exports bookmarks and prompts for Chrome's native password CSV export.
        Chrome            = "BookmarksAndPasswords"
        Firefox           = $true
        Edge              = $false  # Microsoft account already syncs Edge settings
        OneDrive          = $true
    }

    Import = @{
        # Restores AppData\Lotus_Local when it is present in a transfer package.
        LotusNotes = $true

        # Deletes Printers\Printers.printerExport only after a successful
        # PrintBRM restore and completion of the generated import script.
        DeletePrintBrmAfterImport = $true
    }

    # These values override the regular Import defaults when the technician
    # selects an Online transfer. They can still be changed for one transfer
    # in the runtime settings menu.
    Online = @{
        # Online transfers warn before starting when selected payload exceeds this size.
        MaxTransferGB = 5
        # Downloads is excluded from Online transfers by default. The technician
        # can enable its standalone toggle for an individual transfer.
        Downloads = $true
        # Online transfers create a ZIP beside the transfer folder by default.
        CreateZipArchive = $true

        # Build network-bound packages in the transferring user's Local AppData,
        # then upload one ZIP instead of thousands of small network writes.
        StageNetworkTransfersLocally = $true

        Import = @{
            LotusNotes                  = $true
            DeletePrintBrmAfterImport   = $true
        }
    }
}
