$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DevelopmentConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
$script:Config = @{
    TransferMode = 'Local'
    UserFolders = @('Documents', 'Desktop', 'Downloads')
    BluebeamPaths = @('Bluebeam Software', 'Bluebeam')
    AppDataRoaming = @{ Signatures = 'Microsoft\Signatures'; QuickAccess = 'Microsoft\Windows\Recent\AutomaticDestinations' }
    Backup = @{ UserData = $true; AppData = $true; LotusNotes = $true; SystemSettings = $true; InstalledPrograms = $true; AppDataCandidateInventory = $true; Printers = $true; Chrome = $true; Firefox = $true; Edge = $true; OneDrive = $true; DesktopLayout = $true; TaskbarLayout = $true; DefaultApps = $true }
    Import = @{ LotusNotes = $true; DeletePrintBrmAfterImport = $true; EnableAdminHelper = $false; AppComparison = $true; AppDataReview = $true }
    Online = @{ DownloadsCapGB = 5; MaxTransferGB = 5; OverrideDownloadsCap = $false; SkipLotusNotes = $true; CreateZipArchive = $true; StageNetworkTransfersLocally = $true; IncludeChromeProfileArchive = $false; IncludeAdditionalUserFolders = $false; AdditionalFolderCapGB = 1; IncludeOcsDocuments = $false; DetailedAppDataCandidateInventory = $false }
}
$script:Config.Import.PostImportLaunch = $script:DevelopmentConfig.Import.PostImportLaunch
$script:SettingsModules = @('06-settings.ps1', '06-layout.ps1', '06-appdata-review.ps1', '06-printers.ps1')
$script:ImportTemplateModules = @('08-import-template.ps1')

foreach ($module in @(
    '01-bootstrap.ps1', '02-ui.ps1', '03-core.ps1', '04-destination.ps1'
) + $script:SettingsModules + @('09-report.ps1')) {
    . (Join-Path $script:RepoRoot "src\$module")
}

# The import template is one here-string split across source files. Rejoin it
# before loading, just as Build-Deployment.ps1 does.
Invoke-Expression (($script:ImportTemplateModules | ForEach-Object {
    Get-Content -LiteralPath (Join-Path $script:RepoRoot "src\$_") -Raw
}) -join '')

function Get-LaptopExportSourceText {
    param([ValidateSet('Settings', 'ImportTemplate')][string]$Group)

    $modules = if ($Group -eq 'Settings') { $script:SettingsModules } else { $script:ImportTemplateModules }
    return (($modules | ForEach-Object {
        Get-Content -LiteralPath (Join-Path $script:RepoRoot "src\$_") -Raw
    }) -join '')
}

function Write-Log { param([string]$Message, [string]$Level = 'Info') }
function Format-FileSize { param([long]$Bytes) return "$Bytes B" }
function Format-RemainingTime { param([double]$Seconds) return 'calculating...' }
function Add-Result {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Details = '')
    [void]$script:Results.Actions.Add(@{ Category = $Category; Item = $Item; Status = $Status; Details = $Details })
}

function Reset-LaptopExportResults {
    $script:Log = [System.Collections.ArrayList]::new()
    $script:Results = @{
        StartTime = Get-Date
        EndTime = $null
        UserName = 'Test User'
        ComputerName = 'TEST-PC'
        Actions = [System.Collections.ArrayList]::new()
        Errors = [System.Collections.ArrayList]::new()
        Warnings = [System.Collections.ArrayList]::new()
        ManualTasks = [System.Collections.ArrayList]::new()
    }
}
