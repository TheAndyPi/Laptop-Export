# Laptop Export

**STO Building Group – Laptop Transfer / Export Tool** (`Export-LaptopData.ps1`, v0.9)

A single-file PowerShell tool that automates the **data-collection phase** of a laptop refresh. An IT technician runs it on the **old** laptop (logged in as, or on behalf of, the user being transferred). It creates a self-contained transfer package, ZIPs it for handoff, and generates a matching **Import** script, a **QuickImport.bat**, and an **HTML report** to run on the new machine.

## Development and deployment

The deployed `Export-LaptopData.ps1` remains a single, self-contained script. For maintenance, edit the focused modules in [`src`](src/README.md), then rebuild the deployment file:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Build-Deployment.ps1"
```

For development, [`src/00-development-config.psd1`](src/00-development-config.psd1) controls each export stage. All switches default to `$true`; rebuild after changing a value. The config is embedded in the generated deployment script, so it is not a separate technician-side dependency. Set `Backup.Chrome` to `$false` to skip Chrome while still exporting Edge and Firefox. Under `Import`, disable only the Lotus Notes or Firefox restore as needed. Under `Online`, set `CreateZipArchive` to `$false` to retain only the transfer folder, set `StageNetworkTransfersLocally` to `$false` to disable local staging, and set `Online.Import` values to the defaults that should apply whenever an Online transfer is selected.

Run the automated regression suite before committing changes:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Invoke-LaptopExportTests.ps1"
```

The suite uses only Pester's temporary test data. It validates the build
artifact, destination recursion protection, Online payload limits, ZIP
cancellation cleanup, generated-import syntax, report HTML encoding, and a
non-interactive generated-import `-TestMode` run; it never runs a real export
or import. Pester is required (`Install-Module Pester
-Scope CurrentUser` if it is not already installed).

When running the export script, a **Transfer Settings** master panel shows the backup, import, and Online ZIP switches. It begins in the **Basic** preset after you choose Local or Online mode. Choose **Advanced** to enable the remaining-profile transfer and open a second screen where the technician selects additional Local/Roaming AppData folders to include, with size estimates. Curated AppData items remain included in every preset. Changing any individual setting marks the preset **Custom**. Enter a setting number to toggle it, then press `S` to start. Those menu choices affect only the current transfer and do not change the compiled defaults.

For an Online export to a network share, the default workflow stages the package under `%LOCALAPPDATA%\STO Building Group\LaptopTransferStaging`, creates a fast ZIP locally, then uploads and size-verifies the single ZIP at the selected network destination. The local staging package is retained for recovery. Browser cache trees are excluded from profile archives because they are disposable and commonly account for most of the files and ZIP time. Online mode defaults to portable Chrome bookmarks and the optional native password CSV rather than Chrome's full profile archive; use **Advanced Online Controls** in Transfer Settings to show its size estimate and opt in when recovery/reference data is needed.

## Deploy / Run

Run on the **old** laptop, signed in as the user being transferred:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Export-LaptopData.ps1"
```

The script is interactive. It will prompt you to:

1. **Choose a transfer mode** — `Local` or `Online` (see below).
2. **Review Transfer Settings** — toggle **Run export as administrator** if a complete power-plan or PrintBRM export is needed. The main export remains in the signed-in user's context; after normal capture, UAC is requested only for a small power/PrintBRM helper.
3. **Choose a destination**:
   - **Local:** Select an external or secondary drive from the console; the Windows folder picker is not opened.
   - **Online:** A Windows folder picker opens. Choose a network share, cloud-synced folder, or any local folder.

It then runs the export and opens the HTML report when finished. **Online** transfers also create `LaptopTransfer_<timestamp>.zip` beside the package folder; **Local** transfers keep only the folder.

For lean Online packages, choose `A` in **Transfer Settings** to open **Advanced Online Controls**. There you can opt into the full Chrome profile archive, extra profile folders, `C:\OCS Documents`, detailed AppData candidate sizing, and set the confirmation cap for included extra folders. All advanced options default to off for Online transfers; Local transfers remain comprehensive.

## Requirements

- **Windows PowerShell 5.1+** (`#Requires -Version 5.1`)
- An **external/USB drive** (or second fixed drive) with enough free space for **Local** transfers
- For **Online** transfers, a writable destination folder (network share, cloud-synced folder, or local folder); no external drive is required
- **Administrator rights** — *recommended*. Toggle **Run export as administrator** in Transfer Settings when a complete power-plan mirror or full PrintBRM package is needed. It does not relaunch the whole exporter: only the final power/PrintBRM helper receives UAC.

## Transfer modes

| Mode | Use case | Behavior |
|------|----------|----------|
| **Local** | USB / on-site | Full copy of everything; no ZIP is created. |
| **Online** | Slow / remote links | Trimmed: caps `Downloads` at 5 GB (omits if larger), skips Lotus Notes data, prompts on any folder over 10 GB, skips OneDrive re-hydration, and creates a ZIP. |

## What it captures

- **User folders** — Documents, Desktop, Downloads, Pictures, Videos, Music, Favorites, loose profile files, and OCS Documents. Transfer Settings also offers an opt-in **Entire user profile** copy; it adds remaining profile content without duplicating folders already captured by the standard user-data, AppData, or browser stages.
- **AppData** — Bluebeam, Outlook email signatures, Quick Access pins, Lotus Notes
- **System settings** — individual active power-plan values are captured alongside mapped drives, personalization (colors, dark mode, taskbar), wallpaper, desktop shortcut layout, taskbar pins, and a default-app inventory. The complete power plan is captured/restored by the scoped elevated helper.
- **Installed programs** — captured from the old PC and compared against the signed-in user's new-PC inventory during import; missing apps and version differences are written to `Logs\AppMigrationReview.html`
- **AppData candidates** — a review-only inventory of non-system Roaming/Local AppData folders, including size and curated-backup coverage; candidates are never copied automatically
- **Printers** — a `Printers.printerExport` PrintBRM migration file is attempted for every run, plus a driverless network-connection list. Windows may require elevation to create a full PrintBRM package; the package log records the exact result.
- **Browser data** — Chrome and Edge bookmarks from every profile (automatic restore for Default/matching profiles plus portable HTML), a Chrome profile archive with common cache directories excluded for recovery/reference, and an optional native Chrome Password Manager CSV export that requires Windows authentication; full Firefox profile data, including bookmarks, saved logins, history, extensions, settings, and companion local data
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
├── QuickImport.bat        # double-click launcher (runs as the signed-in user)
└── TransferReport.html    # full report of everything captured

LaptopTransfer_<timestamp>.zip  # Online transfers only: portable copy of the package above
```

## On the new machine

Copy the transfer folder to the new laptop, or (for Online transfers) extract `LaptopTransfer_<timestamp>.zip`, then restore with **either**:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Import-LaptopData.ps1"
```

...or double-click **`QuickImport.bat`**. It restores user-scoped data as the signed-in user, then requests UAC for a separate helper that restores only power settings and the PrintBRM package. If UAC is unavailable and the package contains the elevated-export artifacts, it makes one logged standard-user fallback attempt and retains the package if Windows rejects it. Add `-TestMode` to the Import command to preview actions without making changes.

If Firefox data is present, the import script restores it automatically. Close Firefox when prompted; any existing Firefox data on the new laptop is moved to a timestamped `Firefox_Backup_*` folder beside the restored profile.

With Chrome and Edge closed, the import script restores bookmarks automatically for each `Default` profile and any matching `Profile N` profiles. It backs up any target bookmark file first. Profiles that do not yet exist on the new machine remain available as portable HTML files for native browser import. The raw Chrome profile archive is retained for recovery/reference but credentials and cookies are deliberately not copied over: their encryption is tied to the old Windows installation. During export, the tool can open Chrome Password Manager so the original user can complete Chrome's Windows-authenticated password export. Save that resulting plaintext CSV in the requested `BrowserData\Chrome\PasswordExport` folder. The generated import script guides the native Chrome CSV import and offers to delete the CSV only after you confirm the import succeeded.

During any file-copy step, press `S` to stop that copy and continue the export. The transfer report records the step as skipped; partially copied files remain in place so a later export can resume the copy.

Desktop Layout, Taskbar Layout, and Default Apps are independent Transfer Settings switches and are enabled by default. Desktop duplicate cleanup only offers exact duplicate `.lnk`/`.url` files found in both the local and OneDrive Desktop folders; it requires confirmation and sends selected shortcuts to the Recycle Bin. Taskbar restoration retains existing destination pins and reports unavailable apps. Default-app associations are documented in `Logs\DefaultAppsRestoreGuide.txt` and opened in Windows Settings rather than being force-written.

The AppData candidate inventory, installed-app comparison, and AppData review are also independent Transfer Settings switches and default to enabled. After import, review `Logs\AppMigrationReview.html` for missing applications and associated/unassociated AppData candidates. This produces a warning and checklist task but does not block import completion.

## Command-line parameters

Normally you don't pass any — the script prompts for everything. These exist mainly so the tool can hand context to its own elevated relaunch:

| Parameter | Purpose |
|-----------|---------|
| `-TransferMode Local\|Online` | Skip the mode prompt. |
| `-DestinationPath <path>` | Skip the Online folder picker and write the package below this folder. |
| `-TargetUserProfile`, `-TargetUserName`, `-TargetAppDataRoaming`, `-TargetAppDataLocal` | Preserve the original user's context when running elevated. Set automatically during self-elevation. |
