@echo off
setlocal EnableExtensions

:: Source.Python Windows build entry point.
:: Usage: Build.bat blade|bms|csgo|css|dods|hl2dm|l4d2|tf2
:: The SDK revision is pinned by scripts/ci/sdk-pins.json and is not taken
:: from an unpinned branch pull.

set "BRANCH=%~1"
if not defined BRANCH (
    echo Choose a branch: blade, bms, csgo, css, dods, hl2dm, l4d2, or tf2
    set /p "BRANCH=Branch: "
)

if /I "%BRANCH%"=="blade" goto valid
if /I "%BRANCH%"=="bms" goto valid
if /I "%BRANCH%"=="csgo" goto valid
if /I "%BRANCH%"=="css" goto valid
if /I "%BRANCH%"=="dods" goto valid
if /I "%BRANCH%"=="hl2dm" goto valid
if /I "%BRANCH%"=="l4d2" goto valid
if /I "%BRANCH%"=="tf2" goto valid

echo Invalid branch: %BRANCH%
exit /b 2

:valid
set "REPO_ROOT=%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\ci\verify-fixes.ps1" -RepositoryRoot "%REPO_ROOT%"
if errorlevel 1 exit /b %errorlevel%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\ci\fetch-hl2sdk.ps1" -Branch "%BRANCH%" -RepositoryRoot "%REPO_ROOT%"
if errorlevel 1 exit /b %errorlevel%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\ci\build-windows.ps1" -Branch "%BRANCH%" -RepositoryRoot "%REPO_ROOT%"
exit /b %errorlevel%
