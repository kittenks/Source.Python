[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('blade', 'bms', 'csgo', 'css', 'dods', 'hl2dm', 'l4d2', 'tf2')]
    [string]$Branch,

    [string]$RepositoryRoot = '',
    [string]$BuildDirectory = '',
    [string]$OutputDirectory = '',
    [string]$Generator = '',

    [ValidateSet('x86', 'x86_64')]
    [string]$Architecture = 'x86'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
& (Join-Path $PSScriptRoot 'verify-fixes.ps1') -RepositoryRoot $RepositoryRoot
# Mirror the Linux layout: the x86 build keeps its historical path, and the
# x86-64 build gets its own so the two architectures can coexist in artifacts.
if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    $buildFolder = if ($Architecture -eq 'x86') { $Branch } else { "$Branch-$Architecture" }
    $BuildDirectory = Join-Path $RepositoryRoot "src\Builds\Windows\$buildFolder"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot 'artifacts\native'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$platformFolder = if ($Architecture -eq 'x86') { 'windows' } else { "windows-$Architecture" }
$nativeDirectory = Join-Path $OutputDirectory "$Branch\$platformFolder"
$buildDirectory = [IO.Path]::GetFullPath($BuildDirectory)

$pinsPath = Join-Path $PSScriptRoot 'sdk-pins.json'
$pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
$commit = [string]$pins.PSObject.Properties[$Branch].Value.commit
$sdkDirectory = Join-Path $RepositoryRoot "src\hl2sdk\$Branch"
if (-not (Test-Path -LiteralPath (Join-Path $sdkDirectory 'tier1\KeyValues.cpp') -PathType Leaf)) {
    throw "HL2SDK is not ready at '$sdkDirectory'. Run scripts/ci/fetch-hl2sdk.ps1 first."
}
if ($Architecture -eq 'x86_64') {
    $win64Library = [string]$pins.PSObject.Properties[$Branch].Value.sdk_lib_win64
    if ([string]::IsNullOrWhiteSpace($win64Library)) {
        throw "sdk-pins.json has no sdk_lib_win64 entry for '$Branch'."
    }
    $win64Path = Join-Path $sdkDirectory $win64Library.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $win64Path -PathType Leaf)) {
        throw "The pinned HL2SDK checkout has no Windows x86-64 tier1 library at '$win64Library'."
    }
}

function Find-CMake {
    $command = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installation) {
            $bundled = Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
        }
    }
    throw 'CMake was not found. Install Visual Studio C++ tools or add cmake.exe to PATH.'
}

function Select-Generator {
    param([string]$CMake)
    if (-not [string]::IsNullOrWhiteSpace($Generator)) { return $Generator }
    if (-not [string]::IsNullOrWhiteSpace($env:SOURCEPYTHON_VS_GENERATOR)) { return $env:SOURCEPYTHON_VS_GENERATOR }

    $help = (& $CMake --help 2>&1 | Out-String)
    foreach ($candidate in @('Visual Studio 18 2026', 'Visual Studio 17 2022', 'Visual Studio 16 2019')) {
        if ($help.Contains($candidate)) { return $candidate }
    }
    return 'Visual Studio 17 2022'
}

function Assert-PeMachine {
    param(
        [string]$Path,
        [int]$Expected,
        [string]$ExpectedName
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or [BitConverter]::ToInt32($bytes, 0x3c) -lt 0) {
        throw "'$Path' is not a valid PE file."
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne $Expected) {
        throw "'$Path' is not a $ExpectedName PE (machine 0x$($machine.ToString('X4')), expected 0x$($Expected.ToString('X4')))."
    }
}

$peMachine = if ($Architecture -eq 'x86') { 0x014c } else { 0x8664 }
$peName = if ($Architecture -eq 'x86') { 'x86' } else { 'x86-64' }

$cmake = Find-CMake
$Generator = Select-Generator -CMake $cmake
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $nativeDirectory | Out-Null

Write-Host "Using CMake: $cmake"
Write-Host "Using generator: $Generator"
$vsPlatform = if ($Architecture -eq 'x86') { 'Win32' } else { 'x64' }
Write-Host "Using platform: $vsPlatform ($Architecture)"
& $cmake -S (Join-Path $RepositoryRoot 'src') -B $buildDirectory -G $Generator -A $vsPlatform `
    "-DBRANCH=$Branch" "-DSOURCEPYTHON_ARCH=$Architecture"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE." }

& $cmake --build $buildDirectory --config Release --parallel 2
if ($LASTEXITCODE -ne 0) { throw "CMake build failed with exit code $LASTEXITCODE." }

$core = Get-ChildItem -LiteralPath $buildDirectory -Recurse -Filter 'core.dll' -File | Select-Object -First 1
$loader = Get-ChildItem -LiteralPath $buildDirectory -Recurse -Filter 'source-python.dll' -File | Select-Object -First 1
if ($null -eq $core -or $null -eq $loader) {
    throw 'The build completed but core.dll or source-python.dll was not produced.'
}
Assert-PeMachine $core.FullName $peMachine $peName
Assert-PeMachine $loader.FullName $peMachine $peName

Remove-Item -LiteralPath $nativeDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $nativeDirectory | Out-Null
Copy-Item -LiteralPath $core.FullName -Destination (Join-Path $nativeDirectory 'core.dll')
Copy-Item -LiteralPath $loader.FullName -Destination (Join-Path $nativeDirectory 'source-python.dll')

$sourceRevision = $env:SOURCEPYTHON_SOURCE_REVISION
if ([string]::IsNullOrWhiteSpace($sourceRevision)) { $sourceRevision = $env:GITHUB_SHA }
if ([string]::IsNullOrWhiteSpace($sourceRevision)) { $sourceRevision = 'local-archive' }
$metadata = [ordered]@{
    game = $Branch
    platform = 'windows'
    architecture = $Architecture
    vs_platform = $vsPlatform
    sdk_commit = $commit
    source_revision = $sourceRevision
    cmake_generator = $Generator
    compiler = 'MSVC'
    files = @('core.dll', 'source-python.dll')
    built_at_utc = [DateTime]::UtcNow.ToString('o')
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $nativeDirectory 'build-info.json') -Encoding UTF8
Write-Host "Windows artifacts for $Branch are ready at $nativeDirectory"
