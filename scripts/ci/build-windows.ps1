[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('blade', 'bms', 'csgo', 'css', 'dods', 'hl2dm', 'l4d2', 'tf2')]
    [string]$Branch,

    [string]$RepositoryRoot = '',
    [string]$BuildDirectory = '',
    [string]$OutputDirectory = '',
    [string]$Generator = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
& (Join-Path $PSScriptRoot 'verify-fixes.ps1') -RepositoryRoot $RepositoryRoot
if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    $BuildDirectory = Join-Path $RepositoryRoot "src\Builds\Windows\$Branch"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot 'artifacts\native'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$nativeDirectory = Join-Path $OutputDirectory "$Branch\windows"
$buildDirectory = [IO.Path]::GetFullPath($BuildDirectory)

$pinsPath = Join-Path $PSScriptRoot 'sdk-pins.json'
$pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
$commit = [string]$pins.PSObject.Properties[$Branch].Value.commit
$sdkDirectory = Join-Path $RepositoryRoot "src\hl2sdk\$Branch"
if (-not (Test-Path -LiteralPath (Join-Path $sdkDirectory 'tier1\KeyValues.cpp') -PathType Leaf)) {
    throw "HL2SDK is not ready at '$sdkDirectory'. Run scripts/ci/fetch-hl2sdk.ps1 first."
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

function Assert-X86Pe {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or [BitConverter]::ToInt32($bytes, 0x3c) -lt 0) {
        throw "'$Path' is not a valid PE file."
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x014c) {
        throw "'$Path' is not an x86 PE (machine 0x$($machine.ToString('X4')))."
    }
}

$cmake = Find-CMake
$Generator = Select-Generator -CMake $cmake
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $nativeDirectory | Out-Null

Write-Host "Using CMake: $cmake"
Write-Host "Using generator: $Generator"
& $cmake -S (Join-Path $RepositoryRoot 'src') -B $buildDirectory -G $Generator -A Win32 `
    "-DBRANCH=$Branch" "-DSOURCEPYTHON_ARCH=x86"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE." }

& $cmake --build $buildDirectory --config Release --parallel 2
if ($LASTEXITCODE -ne 0) { throw "CMake build failed with exit code $LASTEXITCODE." }

$core = Get-ChildItem -LiteralPath $buildDirectory -Recurse -Filter 'core.dll' -File | Select-Object -First 1
$loader = Get-ChildItem -LiteralPath $buildDirectory -Recurse -Filter 'source-python.dll' -File | Select-Object -First 1
if ($null -eq $core -or $null -eq $loader) {
    throw 'The build completed but core.dll or source-python.dll was not produced.'
}
Assert-X86Pe $core.FullName
Assert-X86Pe $loader.FullName

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
    architecture = 'x86'
    sdk_commit = $commit
    source_revision = $sourceRevision
    cmake_generator = $Generator
    compiler = 'MSVC'
    files = @('core.dll', 'source-python.dll')
    built_at_utc = [DateTime]::UtcNow.ToString('o')
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $nativeDirectory 'build-info.json') -Encoding UTF8
Write-Host "Windows artifacts for $Branch are ready at $nativeDirectory"
