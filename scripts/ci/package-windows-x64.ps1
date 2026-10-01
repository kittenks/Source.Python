[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('css', 'dods', 'hl2dm', 'tf2')]
    [string]$Branch,

    [Parameter(Mandatory = $true)]
    [ValidateSet('stable', 'test')]
    [string]$Flavor,

    # x86-64 Python runtime artifact directory produced by the thirdparty-tools
    # repository's scripts/fetch-python-runtime.ps1. It must contain
    # Python3\plat-win with the 28 PE-x86-64 runtime files.
    [Parameter(Mandatory = $true)]
    [string]$RuntimeDirectory,

    # test only: the debug/server-plugins directory of the thirdparty-tools
    # repository (sp_addrguard, sp_compat, ...). Ignored/forbidden for stable.
    [string]$DiagPluginsDirectory = '',

    [string]$RepositoryRoot = '',
    [string]$NativeRoot = '',
    [string]$OutputDirectory = '',
    [string]$BuildDate = $env:SOURCEPYTHON_BUILD_DATE
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($NativeRoot)) {
    $NativeRoot = Join-Path $RepositoryRoot 'artifacts\native'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot 'dist'
}
$NativeRoot = [IO.Path]::GetFullPath($NativeRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)

if ([string]::IsNullOrWhiteSpace($BuildDate)) {
    $BuildDate = [DateTime]::Now.ToString('yyyy-MMdd')
}
if ($BuildDate -notmatch '^\d{4}-\d{4}$') {
    throw "Build date '$BuildDate' must use the yyyy-MMdd format, for example 2026-1001."
}
$dateStamp = $BuildDate

$isTest = $Flavor -eq 'test'
# build-windows.ps1 stages the stable core under windows-x86_64 and the
# -HookDiag core under windows-x86_64-diag.
$target = if ($isTest) { 'windows-x86_64-diag' } else { 'windows-x86_64' }
$nativeDirectory = Join-Path $NativeRoot "$Branch\$target"

function Get-PeMachine {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or [BitConverter]::ToInt32($bytes, 0x3c) -lt 0) {
        throw "'$Path' is not a valid PE file."
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    return [BitConverter]::ToUInt16($bytes, $peOffset + 4)
}
function Assert-PeX64 {
    param([string]$Path)
    $machine = Get-PeMachine -Path $Path
    if ($machine -ne 0x8664) {
        throw "Expected an x86-64 PE (machine 0x8664) but '$Path' is 0x$($machine.ToString('X4'))."
    }
}

# --- Native binaries must match the requested flavor -----------------------
foreach ($nativeFile in 'core.dll', 'source-python.dll', 'build-info.json') {
    if (-not (Test-Path -LiteralPath (Join-Path $nativeDirectory $nativeFile) -PathType Leaf)) {
        throw "Missing $nativeFile for $Branch/$target at '$nativeDirectory'. Build it with build-windows.ps1 -Architecture x86_64$(if ($isTest) { ' -HookDiag' })."
    }
}
$buildInfo = Get-Content -LiteralPath (Join-Path $nativeDirectory 'build-info.json') -Raw | ConvertFrom-Json
if ($isTest) {
    if (-not $buildInfo.hook_diag) { throw "The test package requires a core built with -HookDiag ($target has hook_diag=false)." }
}
else {
    if ($buildInfo.hook_diag) { throw "The stable package requires a non-diagnostic core ($target has hook_diag=true)." }
}

# --- Stage the payload ------------------------------------------------------
$stagingRoot = Join-Path $OutputDirectory 'staging-win64'
$stage = Join-Path $stagingRoot "$Branch-$Flavor"
Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$payloadDirectories = @('addons', 'cfg', 'logs', 'resource', 'sound')
foreach ($directory in $payloadDirectories) {
    $source = Join-Path $RepositoryRoot $directory
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force
    }
    else {
        New-Item -ItemType Directory -Force -Path (Join-Path $stage $directory) | Out-Null
    }
}

# --- Ensure the Source.Python runtime directory skeleton exists -----------
# A clean git checkout does not track these runtime-writable directories
# (they are git-ignored). Without them a first boot on a fresh install fails
# before Python can bootstrap any files, so create the full skeleton in the
# staged payload. The Python bootstrap also creates them defensively
# (makedirs_p), so this additionally covers archive tools that do not restore
# empty directory entries.
$runtimeDirectories = @(
    'cfg\source-python',
    'cfg\source-python\auth',
    'logs\source-python',
    'addons\source-python\data',
    'addons\source-python\data\custom',
    'addons\source-python\data\plugins',
    'addons\source-python\data\source-python\settings',
    'addons\source-python\plugins',
    'addons\source-python\packages\custom',
    'resource\source-python\events',
    'sound\source-python'
)
foreach ($runtimeDirectory in $runtimeDirectories) {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage $runtimeDirectory) | Out-Null
}

# Rebuild bin/ and the loader from the native artifacts (do not trust stale
# binaries copied out of the source tree).
$binDirectory = Join-Path $stage 'addons\source-python\bin'
Remove-Item -LiteralPath $binDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $binDirectory | Out-Null
foreach ($loaderName in @('source-python.dll', 'source-python.so')) {
    Remove-Item -LiteralPath (Join-Path $stage "addons\$loaderName") -Force -ErrorAction SilentlyContinue
}
Copy-Item -LiteralPath (Join-Path $nativeDirectory 'core.dll') -Destination (Join-Path $binDirectory 'core.dll') -Force
Copy-Item -LiteralPath (Join-Path $nativeDirectory 'source-python.dll') -Destination (Join-Path $stage 'addons\source-python.dll') -Force
Assert-PeX64 (Join-Path $binDirectory 'core.dll')
Assert-PeX64 (Join-Path $stage 'addons\source-python.dll')

# --- Replace Python3/plat-win with the x86-64 runtime wholesale ------------
# The loader reads Python3/plat-win on Windows for both architectures; there
# is no plat-win64. The checkout ships an x86 plat-win, so delete it and drop
# in the official CPython 3.13.2 embeddable amd64 set (native files only).
$sourcePlatWin = Join-Path $RuntimeDirectory 'Python3\plat-win'
if (-not (Test-Path -LiteralPath $sourcePlatWin -PathType Container)) {
    throw "Runtime directory is missing Python3\plat-win: '$sourcePlatWin'."
}
$destPlatWin = Join-Path $stage 'addons\source-python\Python3\plat-win'
Remove-Item -LiteralPath $destPlatWin -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $destPlatWin | Out-Null
$runtimeFiles = @(Get-ChildItem -LiteralPath $sourcePlatWin -File |
        Where-Object { $_.Extension -in '.dll', '.pyd' })
foreach ($file in $runtimeFiles) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destPlatWin $file.Name) -Force
}
$license = Join-Path $RuntimeDirectory 'LICENSE.txt'
if (Test-Path -LiteralPath $license) {
    Copy-Item -LiteralPath $license -Destination (Join-Path $destPlatWin 'LICENSE.txt') -Force
}
foreach ($required in 'python313.dll', 'vcruntime140.dll') {
    if (-not (Test-Path -LiteralPath (Join-Path $destPlatWin $required) -PathType Leaf)) {
        throw "x86-64 runtime is missing required file '$required'."
    }
}
$stagedRuntime = @(Get-ChildItem -LiteralPath $destPlatWin -File |
        Where-Object { $_.Extension -in '.dll', '.pyd' })
foreach ($file in $stagedRuntime) { Assert-PeX64 -Path $file.FullName }
# Pinned to CPython 3.13.2 embeddable amd64; the verified set is exactly 28.
if ($stagedRuntime.Count -ne 28) {
    throw "Expected 28 PE-x86-64 runtime files in plat-win, found $($stagedRuntime.Count)."
}
Write-Host "Runtime: $($stagedRuntime.Count) PE-x86-64 files staged in Python3/plat-win"

# --- The diagnostic string must match the flavor ---------------------------
$coreText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $binDirectory 'core.dll')))
$hasDiagStrings = $coreText.Contains('first24')
if ($isTest) {
    if (-not $hasDiagStrings) {
        throw 'The test core.dll does not contain the DYNAMICHOOKS_DIAG strings ("first24"); it was not built with -HookDiag.'
    }
}
else {
    if ($hasDiagStrings) {
        throw 'The stable core.dll contains DYNAMICHOOKS_DIAG strings ("first24"); it must be built with SP_HOOK_DIAG OFF.'
    }
}

# --- Diagnostic plugins (test only; never auto-loaded) ---------------------
$pluginsDirectory = Join-Path $stage 'addons\source-python\plugins'
$diagnosticPlugins = @('sp_addrguard', 'sp_compat', 'sp_console', 'sp_hibprobe', 'sp_stride', 'sp_vtable', 'sp_vtable_probe')
if ($isTest) {
    if ([string]::IsNullOrWhiteSpace($DiagPluginsDirectory) -or
        -not (Test-Path -LiteralPath $DiagPluginsDirectory -PathType Container)) {
        throw 'The test flavor requires -DiagPluginsDirectory (the thirdparty-tools debug/server-plugins folder).'
    }
    New-Item -ItemType Directory -Force -Path $pluginsDirectory | Out-Null
    foreach ($plugin in $diagnosticPlugins) {
        $pluginSource = Join-Path $DiagPluginsDirectory $plugin
        $pluginEntry = Join-Path $pluginSource "$plugin.py"
        if (-not (Test-Path -LiteralPath $pluginEntry -PathType Leaf)) {
            throw "Diagnostic plugin '$plugin' (with $plugin.py) was not found under '$DiagPluginsDirectory'."
        }
        Copy-Item -LiteralPath $pluginSource -Destination (Join-Path $pluginsDirectory $plugin) -Recurse -Force
    }
    Write-Host "Injected $($diagnosticPlugins.Count) diagnostic plugins (load manually with 'sp plugin load <name>')"
}
else {
    foreach ($plugin in $diagnosticPlugins) {
        if (Test-Path -LiteralPath (Join-Path $pluginsDirectory $plugin)) {
            throw "The stable package must not contain the diagnostic plugin '$plugin'."
        }
    }
    $pdbs = @(Get-ChildItem -LiteralPath $stage -Recurse -Filter '*.pdb' -File -ErrorAction SilentlyContinue)
    if ($pdbs.Count -gt 0) {
        throw "The stable package must not contain PDB files: $($pdbs[0].Name)"
    }
}

# --- Manifest ---------------------------------------------------------------
$pins = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sdk-pins.json') -Raw | ConvertFrom-Json
$sdkCommit = [string]$pins.PSObject.Properties[$Branch].Value.commit
$sourceRevision = $env:SOURCEPYTHON_SOURCE_REVISION
if ([string]::IsNullOrWhiteSpace($sourceRevision)) { $sourceRevision = $env:GITHUB_SHA }
if ([string]::IsNullOrWhiteSpace($sourceRevision)) { $sourceRevision = 'local-archive' }

$manifest = [ordered]@{
    package = 'source-python'
    game = $Branch
    platform = 'windows'
    architecture = 'x86_64'
    flavor = $Flavor
    hook_diag = $isTest
    build_date = $dateStamp
    source_revision = $sourceRevision
    sdk_commit = $sdkCommit
    native_target = $target
    runtime = [ordered]@{
        kind = 'cpython-embeddable-amd64'
        version = '3.13.2'
        source_url = 'https://www.python.org/ftp/python/3.13.2/python-3.13.2-embed-amd64.zip'
        layout = 'Python3/plat-win'
        native_file_count = $stagedRuntime.Count
    }
    diagnostic_plugins = if ($isTest) { $diagnosticPlugins } else { @() }
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'BUILD-MANIFEST.json') -Encoding UTF8

# --- Archive ----------------------------------------------------------------
$archiveName = "source-python-$Branch-win64-$Flavor-$dateStamp.zip"
$archive = Join-Path $OutputDirectory $archiveName
Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
$members = @($payloadDirectories) + 'BUILD-MANIFEST.json'
& tar.exe -a -c -f $archive -C $stage @members
if ($LASTEXITCODE -ne 0) { throw "Failed to create '$archive'." }
Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue

# SHA256SUMS over every dated archive in the output directory.
$archives = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Filter "*-$dateStamp.zip" |
        Sort-Object Name -Unique)
$sumLines = foreach ($item in $archives) {
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($item.Name)"
}
$sumLines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Created $archive"
Write-Host "Wrote $(Join-Path $OutputDirectory 'SHA256SUMS.txt') ($($archives.Count) archive(s))"
