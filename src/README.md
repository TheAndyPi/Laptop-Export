# Source modules

This directory is the build-time source for the single-file deployment script.
The numbered PowerShell files are concatenated in the explicit order defined in
`Build-Deployment.ps1`, so a function must be declared before a later module
calls it. The files intentionally share
the `Script:` scope: configuration, results, progress state, and helper
functions are process-wide state rather than module-local state.

The export path collects data into a package and records every operation in a
structured results list.  The import-template module emits a second script;
that generated script runs later on the replacement computer and therefore has
its own initialization, logging, elevation, and report-update logic.

The source is deliberately divided around export responsibilities: destination
and archive handling; user data; settings; desktop layout/default apps; AppData
review; printers; browsers/OneDrive; import-template sections; and reporting. The
import-template sections are concatenated into one generated here-string, so
their order in the build manifest is part of the runtime contract.

When adding code, preserve these boundaries: keep UI output in the UI helpers,
record work through the result/log helpers, use the configured copy arguments,
and escape values before inserting them into HTML.

Edit the numbered `.ps1` modules in this directory. Run `..\Build-Deployment.ps1` from the repository root to generate the self-contained `Export-LaptopData.ps1` deployment script.

The build manifest, rather than filename sorting, is authoritative. It
intentionally keeps declarations before the features that use them.
