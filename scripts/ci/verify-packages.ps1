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

# What a packaged native module actually is, read from its own header rather
# than believed from the manifest. The manifest is written by the same step that
# picks the file, so it cannot disagree with itself; the file can still be the
# wrong architecture, which is precisely the mistake this catches.
#
# ELF: e_ident[EI_CLASS] is byte 4, 1 for 32-bit and 2 for 64-bit. Only the
# class is read, so nothing here depends on the 32/64 section-header layout
# differences. PE: the DOS header keeps the PE header offset at 0x3c and the
# machine field is the first 2 bytes of that.
function Get-NativeFormat {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 5 -and $bytes[0] -eq 0x7f -and $bytes[1] -eq 0x45 -and
        $bytes[2] -eq 0x4c -and $bytes[3] -eq 0x46) {
        if ($bytes[4] -eq 1) { return 'elf32' }
        if ($bytes[4] -eq 2) { return 'elf64' }
        return "elf-class-$($bytes[4])"
    }
    if ($bytes.Length -ge 0x40 -and $bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a) {
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
        if ($peOffset -gt 0 -and ($peOffset + 6) -le $bytes.Length -and
            $bytes[$peOffset] -eq 0x50 -and $bytes[$peOffset + 1] -eq 0x45) {
            $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
            if ($machine -eq 0x014c) { return 'pe32' }
            if ($machine -eq 0x8664) { return 'pe64' }
            return ('pe-machine-0x{0:x4}' -f $machine)
        }
        return 'pe-without-signature'
    }
    return 'unrecognised'
}

# The format each packaging target has to produce. Keyed by target name, so a
# new architecture is one row here, matching $targetExtensions in package.ps1.
$expectedFormats = @{
    'windows'        = 'pe32'
    'linux'          = 'elf32'
    'windows-x86_64' = 'pe64'
    'linux-x86_64'   = 'elf64'
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

    # Confirm the archive really contains the architectures its manifest claims.
    # Entry names cannot show this, because both architectures of a platform are
    # called core.so / core.dll, so the only way to know is to read the headers
    # of the shipped files. Extract just the handful of members involved rather
    # than the whole archive, which also carries a full CPython runtime.
    $probe = Join-Path $env:TEMP ("sp-verify-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    # tar reports a non-zero status for a member it did not find, and under
    # PowerShell 5.1 a native command writing to stderr raises an error record
    # that $ErrorActionPreference = Stop would turn into a terminating failure.
    # The exit status is checked explicitly below, so relax it around tar only.
    $strict = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & tar.exe -xf $archive -C $probe 'BUILD-MANIFEST.json' 2>$null
        $manifestPath = Join-Path $probe 'BUILD-MANIFEST.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $failures.Add("$(Split-Path -Leaf $archive): could not extract BUILD-MANIFEST.json")
        }
        else {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            foreach ($property in $manifest.sdk_pins.PSObject.Properties) {
                $target = $property.Name
                if (-not $expectedFormats.ContainsKey($target)) {
                    $failures.Add("$(Split-Path -Leaf $archive): manifest names unknown target '$target'")
                    continue
                }
                $wanted = $expectedFormats[$target]
                foreach ($fileName in $property.Value.files) {
                    # package.ps1 stages the core under addons/source-python/bin
                    # and the loader directly under addons.
                    $staged = if ($fileName -like 'core.*') {
                        "addons/source-python/bin/$fileName"
                    }
                    else {
                        "addons/$fileName"
                    }
                    if (-not ($entrySet | Where-Object { $_.TrimEnd('/') -eq $staged })) {
                        $failures.Add("$(Split-Path -Leaf $archive): manifest lists $staged for '$target' but the archive has no such entry")
                        continue
                    }
                    & tar.exe -xf $archive -C $probe $staged 2>$null
                    $extracted = Join-Path $probe $staged.Replace('/', [IO.Path]::DirectorySeparatorChar)
                    if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
                        $failures.Add("$(Split-Path -Leaf $archive): could not extract $staged")
                        continue
                    }
                    $actual = Get-NativeFormat $extracted
                    if ($actual -ne $wanted) {
                        $failures.Add("$(Split-Path -Leaf $archive): $staged is $actual but target '$target' requires $wanted")
                    }
                }
            }
        }
    }
    finally {
        $ErrorActionPreference = $strict
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
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
