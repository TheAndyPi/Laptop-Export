@echo off
setlocal EnableExtensions
title STO Laptop Transfer

rem The dot prevents a trailing backslash from escaping the closing quote in Git.
set "TRANSFER_ROOT=%~dp0."

echo.
echo ================================================================
echo                     STO LAPTOP TRANSFER
echo ================================================================
echo.
echo Welcome. Choose the export method you want to run:
echo.
echo   [S] Stable export method    ^(main branch^)
echo   [P] Prototype export method ^(A1A2-Prototype branch^)
echo   [E] Experimental UNSTABLE export method ^(PrototypeSuperUnstable branch^)
echo.

:ChooseMethod
set "METHOD="
set /p "METHOD=Choose S or P: "
if /I "%METHOD%"=="S" set "TARGET_BRANCH=main"
if /I "%METHOD%"=="P" set "TARGET_BRANCH=A1A2-Prototype"
if /I "%METHOD%"=="E" set "TARGET_BRANCH=PrototypeSuperUnstable"
if not defined TARGET_BRANCH (
    echo Please enter S for Stable or P for Prototype or E for Experimental.
    echo.
    goto ChooseMethod
)

git -C "%TRANSFER_ROOT%" rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: This launcher must remain inside the Laptop-Export Git repository.
    goto Finish
)

git -C "%TRANSFER_ROOT%" show-ref --verify --quiet "refs/heads/%TARGET_BRANCH%"
if errorlevel 1 (
    echo.
    echo ERROR: The %TARGET_BRANCH% branch is not available locally.
    echo Fetch or create the branch, then run this launcher again.
    goto Finish
)

set "CURRENT_BRANCH="
for /f "delims=" %%B in ('git -C "%TRANSFER_ROOT%" branch --show-current') do set "CURRENT_BRANCH=%%B"

if /I "%CURRENT_BRANCH%"=="%TARGET_BRANCH%" goto RunExport

set "WORKTREE_DIRTY="
for /f "delims=" %%D in ('git -C "%TRANSFER_ROOT%" status --porcelain') do set "WORKTREE_DIRTY=1"
if defined WORKTREE_DIRTY (
    echo.
    echo Cannot switch from "%CURRENT_BRANCH%" to "%TARGET_BRANCH%" safely.
    echo Your repository has uncommitted or untracked changes. Commit or stash them first,
    echo then run this launcher again. Nothing was changed.
    goto Finish
)

echo.
echo Switching to the %TARGET_BRANCH% branch...
git -C "%TRANSFER_ROOT%" switch "%TARGET_BRANCH%"
if errorlevel 1 (
    echo.
    echo ERROR: Git could not switch to %TARGET_BRANCH%. Nothing was exported.
    goto Finish
)

:RunExport
echo.
echo Starting the %TARGET_BRANCH% export method...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%TRANSFER_ROOT%Export-LaptopData.ps1"
set "EXPORT_EXIT=%ERRORLEVEL%"

echo.
if "%EXPORT_EXIT%"=="0" (
    echo The export method finished successfully.
) else (
    echo The export method ended with exit code %EXPORT_EXIT%.
)

:Finish
echo.
pause
endlocal
