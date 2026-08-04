# Laptop Export

**STO Building Group – Laptop Transfer / Export Tool** (`Export-LaptopData.ps1`, v0.7)

A single-file PowerShell tool that automates the **data-collection phase** of a laptop refresh. An IT technician runs it on the **old** laptop (logged in as, or on behalf of, the user being transferred). It creates a self-contained transfer package, ZIPs it for handoff, and generates a matching **Import** script, a **QuickImport.bat**, and an **HTML report** to run on the new machine.

## Development and deployment

The deployed `Export-LaptopData.ps1` remains a single, self-contained script. For maintenance, edit the focused modules in [`src`](src/README.md), then rebuild the deployment file:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Build-Deployment.ps1"
```

For development, [`src/00-development-config.psd1`](src/00-development-config.psd1) controls each export stage. Rebuild after changing a value; the config is embedded in the generated deployment script, so it is not a separate technician-side dependency. Set `Backup.Chrome` to `Off`, `BookmarksAndPasswords`, or `FullProfile`. The lightweight Chrome mode exports bookmarks and prompts for Chrome's native password CSV without copying the profile. Under `Import`, disable only the Lotus Notes or Firefox restore as needed. Under `Online`, set `CreateZipArchive` to `$false` to retain only the transfer folder, set `StageNetworkTransfersLocally` to `$false` to disable local staging, and set `Online.Import` values to the defaults that should apply whenever an Online transfer is selected.

When running the export script, a **Transfer Settings** master panel shows the backup, import, and Online ZIP switches. Enter a setting number to toggle it, then press `S` to start. Those menu choices affect only the current transfer and do not change the compiled defaults.

For an Online export to a network share, the default workflow stages the package under `%LOCALAPPDATA%\STO Building Group\LaptopTransferStaging`, creates the ZIP locally, then uploads and size-verifies the single ZIP at the selected network destination. The local staging package is retained for recovery.

## Deploy / Run

Run on the **old** laptop, signed in as the user being transferred:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Export-LaptopData.ps1"
```

The script is interactive. It will prompt you to:

1. **Choose a transfer mode** — `Local` or `Online` (see below). Select `0` on this screen to relaunch as Administrator when needed.
2. **Review the backup overview** — select `S` to start, `C` to open the transfer settings, or `Q` to cancel.
3. **Choose a destination**:
   - **Local:** Select an external or secondary drive from the console; the Windows folder picker is not opened.
   - **Online:** A Windows folder picker opens. Choose a network share, cloud-synced folder, or any local folder.

It then runs the export and opens the HTML report when finished. **Online** transfers also create `LaptopTransfer_<timestamp>.zip` beside the package folder; **Local** transfers keep only the folder.

## Requirements

- **Windows PowerShell 5.1+** (`#Requires -Version 5.1`)
- An **external/USB drive** (or second fixed drive) with enough free space for **Local** transfers
- For **Online** transfers, a writable destination folder (network share, cloud-synced folder, or local folder); no external drive is required
- **Administrator rights** — *optional but recommended*. The script always attempts the printer export, but Windows can require elevation for a full PrintBRM package. Select `0` from the transfer-mode screen to relaunch as Administrator; the package logs the precise PrintBRM result.

## Transfer modes

| Mode | Use case | Behavior |
|------|----------|----------|
| **Local** | USB / on-site | Full copy of everything; no ZIP is created. |
| **Online** | Slow / remote links | Trimmed: disables the standalone `Downloads` toggle by default, skips Lotus Notes data, prompts on any selected folder over 10 GB, skips OneDrive re-hydration, and creates a ZIP. |

## What it captures

- **User folders** — Documents, Desktop, Downloads, Pictures, Videos, Music, Favorites, loose profile files, and OCS Documents
- **AppData** — Bluebeam, Outlook email signatures, Quick Access pins, Lotus Notes
- **System settings** — power scheme, lid-close actions (AC/DC), mapped network drives, personalization (colors, dark mode, taskbar), wallpaper
- **Installed programs** — documented to a list
- **Printers** — a `Printers.printerExport` PrintBRM migration file is attempted for every run, plus a driverless network-connection list. Windows may require elevation to create a full PrintBRM package; the package log records the exact result.
- **Browser data** — Chrome can be set to bookmarks-and-passwords only or a full profile archive; both modes export Chrome bookmarks from every profile and offer Chrome's native password CSV export. Edge bookmarks and full Firefox profile data are also supported.
- **OneDrive** — sync-state handling

## Output package

Written to the chosen destination as a package folder. Online transfers also include a ZIP archive:

```
LaptopTransfer_<timestamp>\
├── UserData\              # user folders + loose files
├── AppData\               # Bluebeam, signatures, Quick Access, Lotus
├── Settings\              # power, drives, personalization
├── BrowserData\           # Chrome/Edge bookmark HTML + portable bookmark records, Chrome archive/password CSV (if chosen), Firefox profile data
├── Printers\              # PrintBRM package
├── Logs\                  # ExportLog.txt
├── Import-LaptopData.ps1  # run on the NEW machine to restore
├── QuickImport.bat        # double-click launcher (choose admin or standard)
└── TransferReport.html    # full report of everything captured

LaptopTransfer_<timestamp>.zip  # Online transfers only: portable copy of the package above
```

## On the new machine

Copy the transfer folder to the new laptop, or (for Online transfers) extract `LaptopTransfer_<timestamp>.zip`, then restore with **either**:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Import-LaptopData.ps1"
```

...or double-click **`QuickImport.bat`** and choose whether to run with administrator rights. Standard mode restores user-scoped data and reports any admin-only steps for manual follow-up. Add `-TestMode` to the Import command to preview actions without making changes.

If Firefox data is present, the import script restores it automatically. Close Firefox when prompted; any existing Firefox data on the new laptop is moved to a timestamped `Firefox_Backup_*` folder beside the restored profile.

With Chrome and Edge closed, the import script restores bookmarks automatically for each `Default` profile and any matching `Profile N` profiles. It backs up any target bookmark file first. Profiles that do not yet exist on the new machine remain available as portable HTML files for native browser import. The raw Chrome profile archive is retained for recovery/reference but credentials and cookies are deliberately not copied over: their encryption is tied to the old Windows installation. During export, the tool can open Chrome Password Manager so the original user can complete Chrome's Windows-authenticated password export. Save that resulting plaintext CSV in the requested `BrowserData\Chrome\PasswordExport` folder. The generated import script guides the native Chrome CSV import and offers to delete the CSV only after you confirm the import succeeded.

During any file-copy step, press `S` to stop that copy and continue the export. The transfer report records the step as skipped; partially copied files remain in place so a later export can resume the copy.

## Command-line parameters

Normally you don't pass any — the script prompts for everything. These exist mainly so the tool can hand context to its own elevated relaunch:

| Parameter | Purpose |
|-----------|---------|
| `-TransferMode Local\|Online` | Skip the mode prompt. |
| `-DestinationPath <path>` | Skip the Online folder picker and write the package below this folder. |
| `-TargetUserProfile`, `-TargetUserName`, `-TargetAppDataRoaming`, `-TargetAppDataLocal` | Preserve the original user's context when running elevated. Set automatically during self-elevation. |
