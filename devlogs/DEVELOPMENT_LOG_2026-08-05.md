# Laptop Export Development Log — 2026-08-05

## v0.8 stability and UX work

- Added independent Downloads control, Chrome’s three transfer modes, background size estimates, numeric overview menus, and two-line input prompts.
- Added optional Local ZIP creation, AppData/Exports destination support, full Chrome profile restore with destination backup, and corrected importer manual-task state.
- Online packages guide Chrome password import at startup; Local packages guide it at import completion.

## Changes added across all of v0.8:
Changes in v0.8 that are not in v0.9:

-Downloads Folder Toggle
Downloads is now its own Backup toggle.
Online transfers default that toggle to OFF.
Removed the Downloads size cap and override behavior.
Downloads can be enabled independently for a one-time transfer.

-Chrome Special Toggle
Implemented Chrome’s special three-mode setting:
Off
Bookmarks + Passwords — exports bookmarks and prompts for Chrome’s native password CSV; does not copy the profile.
Full Profile — includes the existing Chrome profile archive.
The setting cycles through those options in the transfer menu.

-Settings only opens if requested
No automatic admin prompt at startup.
Transfer-mode screen now shows the STO logo and includes [0] Administrator to relaunch elevated.
After choosing Local or Online, users see the backup overview and only:
[S] Start transfer [C] Change Settings [Q] Cancel
Settings open only when the user selects C.

-Schema Changes
Main transfer menu now uses [1] Start, [2] Change settings, [3] Cancel; transfer mode Admin is now option 3. Existing T/F and Y/N prompts were preserved.
Transfer-size estimation now runs in the background while menus remain usable, then refreshes the menu when complete. (New v0.9 already does this)
Chrome password export is deferred until automated export work finishes; Chrome password import runs at the end of the import workflow.
Updated every user-input prompt so the question appears first and input is entered on the following > line.
This covers export, import, destination selection, confirmations, settings, browser prompts, exit prompts, and QuickImport. Rebuilt and syntax-verified

-Added new Dev log on a branch of v0.8
DEVLOPMENT_LOG_2026-08-05.md

-Giving local transfers the OPTION for local ZIPs, but have it stay disabled.
Local ZIP creation is now configurable and off by default.
Runtime Transfer Settings can enable ZIP for Local transfers.
Online transfers retain ZIP-on-by-default behavior.
Removed the hard-coded Local ZIP skip.

-AppData Destination Changes
Allowed destinations now include:
C:\Users\<user>\AppData
C:\Users\<user>\AppData\Exports
Still blocked:
AppData\Local
AppData\Roaming
AppData\LocalLow
Other folders inside the user profile

-Chrome profile not importing bug
Full Chrome archives now restore the complete User Data folder—profiles, extensions, settings, history, and bookmarks—after Chrome is closed. Existing new-PC Chrome data is moved to a timestamped backup first. Passwords/cookies remain Windows-protected and still require Chrome sign-in or CSV import.
The printer follow-up error is fixed by initializing ManualTasks in the generated importer’s summary state. [src/08-import-template.ps1](C:\Users\anderson.chan\OneDrive - STO Building Group\Documents\Automation Projects\Laptop Export Copy\Laptop-Export\src\08-import-template.ps1:185)
Verified build, deployment syntax, generated-import syntax, and configuration checks.

-Chrome Password Step Reordering
Online packages now prompt for Chrome’s native password import at importer startup (after elevation handling), before any file restoration begins.
Local packages still prompt at the end.
Online destination screen now recommends:approved reachable network share as best choice;
C:\LaptopTransfers as a temporary fallback with ample free space;
avoiding Desktop, Downloads, OneDrive, and the source user profile.


