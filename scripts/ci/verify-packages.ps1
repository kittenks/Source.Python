[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$OutputDirectory = '',
    [string[]]$Branches = @('blade', 'bms', 'csgo', 'css', 'dods', 'hl2dm', 'l4d2', 'tf2'),
    [string[]]$RequiredPlatforms = @('windows', 'linux'),
    [string]$BuildDate = $env:SOURCEPYTHON_BUILD_DATE,
    # Partial runs verify only the game archives.
    [switch]$SkipSourceArchive
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot 'dist'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($BuildDate)) {
    $BuildDate = [DateTime]::Now.ToString('yyyy-MMdd')
}
if ($BuildDate -notmatch '^\d{4}-\d{4}$') {
    throw "Build date '$BuildDate' must use the yyyy-MMdd format, for example 2026-0925."
}

# Batch files and shells pass game/platform lists as one comma separated token.
$Branches = @($Branches | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
$RequiredPlatforms = @($RequiredPlatforms | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($Branches.Count -eq 0) { throw 'No games were requested.' }

$failures = [Collections.Generic.List[string]]::new()

function Get-ArchiveEntries {
    param([string]$Path)
    $entries = & tar.exe -tf $Path
    if ($LASTEXITCODE -ne 0) { throw "Unable to list '$Path'." }
    return $entries
}

$expected = foreach ($branch in $Branches) {
    $name = "source-python-$branch-$BuildDate.zip"
    $path = Join-Path $OutputDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing archive $name")
        continue
    }
    $path
}
$sourceArchive = Join-Path $OutputDirectory "source-python-source-$BuildDate.zip"
if ($SkipSourceArchive) {
    $sourceArchive = $null
}
elseif (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    $failures.Add("Missing archive source-python-source-$BuildDate.zip")
}

foreach ($archive in $expected) {
    $entries = Get-ArchiveEntries $archive
    $entrySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) { [void]$entrySet.Add($entry) }

    $required = [Collections.Generic.List[string]]::new()
    $required.Add('BUILD-MANIFEST.json')
    $required.Add('addons/source-python.vdf')
    $required.Add('addons/source-python/Python3/plat-linux/libpython3.13.so.1.0')
    $required.Add('addons/source-python/Python3/lib-dynload/_ctypes.cpython-313-x86_64-linux-gnu.so')
    if ($RequiredPlatforms -contains 'windows') {
        $required.Add('addons/source-python.dll')
        $required.Add('addons/source-python/bin/core.dll')
    }
    if ($RequiredPlatforms -contains 'linux') {
        $required.Add('addons/source-python.so')
        $required.Add('addons/source-python/bin/core.so')
    }
    foreach ($relative in $required) {
        $normalised = $relative.Replace('\', '/')
        $found = $false
        foreach ($entry in $entrySet) {
            if ($entry.TrimEnd('/') -eq $normalised) { $found = $true; break }
        }
        if (-not $found) {
            $failures.Add("$(Split-Path -Leaf $archive): missing $normalised")
        }
    }

    if ($RequiredPlatforms -contains 'linux' -and
        -not ($entrySet | Where-Object { $_ -like 'addons/source-python/Python3/plat-linux64/*' })) {
        $failures.Add("$(Split-Path -Leaf $archive): missing the Linux x86-64 runtime from PR #533")
    }
}

$sumFile = Join-Path $OutputDirectory 'SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $sumFile -PathType Leaf)) {
    $failures.Add('Missing SHA256SUMS.txt')
}
else {
    $recorded = @{}
    foreach ($line in Get-Content -LiteralPath $sumFile) {
        if ($line -match '^([0-9a-f]{64})\s+(.+)$') { $recorded[$Matches[2].Trim()] = $Matches[1] }
    }
    foreach ($archive in @($expected) + @($sourceArchive | Where-Object { $_ })) {
        if (-not $archive) { continue }
        $name = Split-Path -Leaf $archive
        if (-not $recorded.ContainsKey($name)) {
            $failures.Add("SHA256SUMS.txt: no entry for $name")
            continue
        }
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $recorded[$name]) {
            $failures.Add("${name}: SHA-256 does not match SHA256SUMS.txt")
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw 'Package verification failed.'
}

$sourceCount = if ($SkipSourceArchive) { 0 } else { 1 }
Write-Host "Verified $($expected.Count + $sourceCount) dated archives in $OutputDirectory"
