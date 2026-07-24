@{
    # Development-time backup switches. Edit these values, then run
    # Build-Deployment.ps1 to embed the configuration in Export-LaptopData.ps1.
    # Every backup stage is enabled by default.
    Backup = @{
        UserData          = $true
        AppData           = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        BrowserData       = $true
        OneDrive          = $true
    }

    Import = @{
        # Deletes Printers\Printers.printerExport only after a successful
        # PrintBRM restore and completion of the generated import script.
        DeletePrintBrmAfterImport = $true
    }
}
