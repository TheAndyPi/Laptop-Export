# Laptop Export

**STO Building Group – Laptop Transfer / Export Tool** (`Export-LaptopData.ps1`, v0.6)

A single-file PowerShell tool that automates the **data-collection phase** of a laptop refresh. An IT technician runs it on the **old** laptop (logged in as, or on behalf of, the user being transferred). It creates a self-contained transfer package, ZIPs it for handoff, and generates a matching **Import** script, a **QuickImport.bat**, and an **HTML report** to run on the new machine.

## Deploy / Run

Run on the **old** laptop, signed in as the user being transferred:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Export-LaptopData.ps1"
```

The script is interactive. It will prompt you to:

1. **Elevate to Administrator** (Y/N/Skip) — recommended. Accepting re-launches via UAC, preserving the original user's profile context.
2. **Choose a transfer mode** — `Local` or `Online` (see below).
3. **Choose a destination**:
   - **Local:** Select an external or secondary drive from the console; the Windows folder picker is not opened.
   - **Online:** A Windows folder picker opens. Choose a network share, cloud-synced folder, or any local folder.

It then runs the export and opens the HTML report when finished. **Online** transfers also create `LaptopTransfer_<timestamp>.zip` beside the package folder; **Local** transfers keep only the folder.

## Requirements

- **Windows PowerShell 5.1+** (`#Requires -Version 5.1`)
- An **external/USB drive** (or second fixed drive) with enough free space for **Local** transfers
- For **Online** transfers, a writable destination folder (network share, cloud-synced folder, or local folder); no external drive is required
- **Administrator rights** — *optional but recommended*. The script always attempts the printer export, but Windows can require elevation for a full PrintBRM package. The script offers to self-elevate and logs the precise PrintBRM result.

## Transfer modes

| Mode | Use case | Behavior |
|------|----------|----------|
| **Local** | USB / on-site | Full copy of everything; no ZIP is created. |
| **Online** | Slow / remote links | Trimmed: caps `Downloads` at 5 GB (omits if larger), skips Lotus Notes data, prompts on any folder over 10 GB, skips OneDrive re-hydration, and creates a ZIP. |

## What it captures

- **User folders** — Documents, Desktop, Downloads, Pictures, Videos, Music, Favorites, loose profile files, and OCS Documents
- **AppData** — Bluebeam, Outlook email signatures, Quick Access pins, Lotus Notes
- **System settings** — power scheme, lid-close actions (AC/DC), mapped network drives, personalization (colors, dark mode, taskbar), wallpaper
- **Installed programs** — documented to a list
- **Printers** — a `Printers.printerExport` PrintBRM migration file is attempted for every run, plus a driverless network-connection list. Windows may require elevation to create a full PrintBRM package; the package log records the exact result.
- **Browser data** — Chrome & Edge bookmarks (HTML), Firefox reminder
- **OneDrive** — sync-state handling

## Output package

Written to the chosen destination as a package folder. Online transfers also include a ZIP archive:

```
LaptopTransfer_<timestamp>\
├── UserData\              # user folders + loose files
├── AppData\               # Bluebeam, signatures, Quick Access, Lotus
├── Settings\              # power, drives, personalization
├── BrowserData\           # bookmarks
├── Printers\              # PrintBRM package
├── Logs\                  # ExportLog.txt
├── Import-LaptopData.ps1  # run on the NEW machine to restore
├── QuickImport.bat        # double-click launcher (runs as the current user)
└── TransferReport.html    # full report of everything captured

LaptopTransfer_<timestamp>.zip  # Online transfers only: portable copy of the package above
```

## On the new machine

Copy the transfer folder to the new laptop, or (for Online transfers) extract `LaptopTransfer_<timestamp>.zip`, then restore with **either**:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Import-LaptopData.ps1"
```

...or double-click **`QuickImport.bat`** (no administrator prompt). It restores user-scoped data and reports any admin-only steps for manual follow-up. Add `-TestMode` to the Import command to preview actions without making changes.

## Command-line parameters

Normally you don't pass any — the script prompts for everything. These exist mainly so the tool can hand context to its own elevated relaunch:

| Parameter | Purpose |
|-----------|---------|
| `-TransferMode Local\|Online` | Skip the mode prompt. |
| `-DestinationPath <path>` | Skip the Online folder picker and write the package below this folder. |
| `-TargetUserProfile`, `-TargetUserName`, `-TargetAppDataRoaming`, `-TargetAppDataLocal` | Preserve the original user's context when running elevated. Set automatically during self-elevation. |
