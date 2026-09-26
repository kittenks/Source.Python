@echo off
REM ===========================================================================
REM  One-click Windows x86 build for the eight Source.Python games.
REM
REM  Usage:
REM    scripts\ci\build-all.bat                 build all eight games
REM    scripts\ci\build-all.bat css dods         build selected games only
REM    scripts\ci\build-all.bat css --no-package build without packaging
REM    scripts\ci\build-all.bat --dry-run        print the planned commands
REM
REM  Each game fetches the HL2SDK revision pinned in scripts\ci\sdk-pins.json,
REM  builds x86 core.dll/source-python.dll, and finally writes
REM  dist\source-python-<game>-<yyyy-MMdd>.zip plus the source archive.
REM ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
set "REPO_ROOT=%~dp0..\.."
pushd "%REPO_ROOT%" || exit /b 1

set "PACKAGE=1"
set "DRYRUN=0"
set "GAMES="
:parse
if "%~1"=="" goto parsed
if /I "%~1"=="--no-package" (
    set "PACKAGE=0"
) else if /I "%~1"=="--dry-run" (
    set "DRYRUN=1"
) else (
    set "GAMES=!GAMES! %1"
)
shift
goto parse
:parsed
if "!GAMES!"=="" set "GAMES= blade bms csgo css dods hl2dm l4d2 tf2"

set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"
"%PS%" -NoProfile -Command "$PSVersionTable.PSVersion.Major -ge 5" >nul 2>&1
if errorlevel 1 (
    echo [build-all] Windows PowerShell 5.1 or PowerShell 7+ is required.
    popd
    exit /b 1
)

set "PACKAGE_BRANCHES="
for %%G in (!GAMES!) do (
    if defined PACKAGE_BRANCHES (
        set "PACKAGE_BRANCHES=!PACKAGE_BRANCHES!,%%G"
    ) else (
        set "PACKAGE_BRANCHES=%%G"
    )
)

for %%G in (!GAMES!) do (
    echo.
    echo [build-all] === Fetching pinned HL2SDK for %%G ===
    if "%DRYRUN%"=="1" (
        echo   "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\ci\fetch-hl2sdk.ps1 -Branch %%G
    ) else (
        "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\ci\fetch-hl2sdk.ps1 -Branch %%G
    )
    if errorlevel 1 goto :failed
    echo [build-all] === Building Windows x86 for %%G ===
    if "%DRYRUN%"=="1" (
        echo   "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\ci\build-windows.ps1 -Branch %%G
    ) else (
        "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\ci\build-windows.ps1 -Branch %%G
    )
    if errorlevel 1 goto :failed
)

if "%PACKAGE%"=="1" (
    echo.
    echo [build-all] === Packaging !PACKAGE_BRANCHES! ===
    if "%DRYRUN%"=="1" (
        echo   "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\ci\package.ps1 -Branches "!PACKAGE_BRANCHES!" -RequiredPlatforms windows -SourceArchive
    ) else (
        "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\ci\package.ps1 ^
            -Branches "!PACKAGE_BRANCHES!" -RequiredPlatforms windows -SourceArchive
        if errorlevel 1 goto :failed
    )
    echo [build-all] Archives are in "%REPO_ROOT%\dist"
) else (
    echo [build-all] Packaging skipped; run scripts\ci\package.ps1 manually.
)

popd
endlocal
exit /b 0

:failed
echo [build-all] FAILED
popd
endlocal
exit /b 1
