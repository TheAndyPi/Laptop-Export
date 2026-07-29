$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DevelopmentConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
$script:Config = @{
    TransferMode = 'Local'
    UserFolders = @('Documents', 'Desktop', 'Downloads')
    BluebeamPaths = @('Bluebeam Software', 'Bluebeam')
    AppDataRoaming = @{ Signatures = 'Microsoft\Signatures'; QuickAccess = 'Microsoft\Windows\Recent\AutomaticDestinations' }
    Backup = @{ UserData = $true; AppData = $true; LotusNotes = $true; SystemSettings = $true; InstalledPrograms = $true; AppDataCandidateInventory = $true; Printers = $true; Chrome = $true; Firefox = $true; Edge = $true; OneDrive = $true; DesktopLayout = $true; TaskbarLayout = $true; DefaultApps = $true }
    Import = @{ LotusNotes = $true; DeletePrintBrmAfterImport = $true; EnableAdminHelper = $false; AppComparison = $true; AppDataReview = $true }
    Online = @{ DownloadsCapGB = 5; MaxTransferGB = 5; OverrideDownloadsCap = $false; SkipLotusNotes = $true; CreateZipArchive = $true; StageNetworkTransfersLocally = $true }
}
foreach ($module in @(
    '01-bootstrap.ps1', '02-ui.ps1', '04-destination.ps1', '06-settings-printers.ps1', '08-import-template.ps1', '09-report.ps1'
)) {
    . (Join-Path $script:RepoRoot "src\$module")
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
