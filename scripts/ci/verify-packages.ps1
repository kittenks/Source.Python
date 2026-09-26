[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$OutputDirectory = '',
    [string[]]$Branches = @('blade', 'bms', 'csgo', 'css', 'dods', 'hl2dm', 'l4d2', 'tf2'),
    [string[]]$RequiredPlatforms = @('windows', 'linux'),
    [string]$BuildDate = $env:SOURCEPYTHON_BUILD_DATE,
    # Partial runs verify only the game archives.
    [switch]$SkipSourceArchive,
    # Highest glibc an x86-64 binary in the archive may require. Nothing else in
    # this script can see this: a prebuilt can be committed from a newer distro
    # than the package supports and every other check still passes, because the
    # architecture is right, the entry is present and the hash matches. It only
    # surfaces at dlopen time on a real host, as
    #   "version `GLIBC_2.38' not found (required by ...)"
    # Valve's own 64-bit engine libraries need GLIBC_2.29, so 2.31 -- Ubuntu
    # 20.04 LTS -- costs nothing the engine could not already run on.
    # Only 64-bit objects are checked: the 32-bit natives legitimately sit at
    # 2.34, so a shared budget would turn the master pipeline red.
    [version]$MaxGlibc64 = '2.31'
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
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 5 -and $Bytes[0] -eq 0x7f -and $Bytes[1] -eq 0x45 -and
        $Bytes[2] -eq 0x4c -and $Bytes[3] -eq 0x46) {
        if ($Bytes[4] -eq 1) { return 'elf32' }
        if ($Bytes[4] -eq 2) { return 'elf64' }
        return "elf-class-$($Bytes[4])"
    }
    if ($Bytes.Length -ge 0x40 -and $Bytes[0] -eq 0x4d -and $Bytes[1] -eq 0x5a) {
        $peOffset = [BitConverter]::ToInt32($Bytes, 0x3c)
        if ($peOffset -gt 0 -and ($peOffset + 6) -le $Bytes.Length -and
            $Bytes[$peOffset] -eq 0x50 -and $Bytes[$peOffset + 1] -eq 0x45) {
            $machine = [BitConverter]::ToUInt16($Bytes, $peOffset + 4)
            if ($machine -eq 0x014c) { return 'pe32' }
            if ($machine -eq 0x8664) { return 'pe64' }
            return ('pe-machine-0x{0:x4}' -f $machine)
        }
        return 'pe-without-signature'
    }
    return 'unrecognised'
}

# The highest glibc symbol version an ELF requires, read out of the file
# itself. Version needs are stored in .gnu.version_r as plain NUL-terminated
# "GLIBC_x.y" strings; reading them as text is enough because no other part of
# an ELF produces that shape, and only the maximum matters. Returns $null when
# the file pins no glibc version at all.
#
# The comparison is done on [version] objects, which compare numerically. A
# string compare would rank '2.9' above '2.31' and quietly pass everything.
function Get-GlibcFloor {
    param([byte[]]$Bytes)
    $highest = $null
    $text = [Text.Encoding]::ASCII.GetString($Bytes)
    foreach ($match in [regex]::Matches($text, 'GLIBC_(\d+)\.(\d+)')) {
        $candidate = [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value)
        if ($null -eq $highest -or $candidate -gt $highest) { $highest = $candidate }
    }
    $highest
}

# Records the worst floor seen per archive and fails anything over budget. The
# observed values are printed at the end either way, so a build that tightens
# the floor is visible and a build that loosens it cannot pass quietly.
$glibcObserved = @{}

function Test-GlibcFloor {
    param(
        [string]$Archive,
        [string]$Relative,
        [byte[]]$Bytes
    )
    if ((Get-NativeFormat $Bytes) -ne 'elf64') { return }
    $floor = Get-GlibcFloor $Bytes
    $label = Split-Path -Leaf $Archive
    if ($null -eq $floor) { return }
    if (-not $glibcObserved.ContainsKey($label) -or $floor -gt $glibcObserved[$label]) {
        $glibcObserved[$label] = $floor
    }
    if ($floor -gt $MaxGlibc64) {
        $failures.Add("$label`: $Relative requires GLIBC_$floor but the x86-64 budget is GLIBC_$MaxGlibc64")
    }
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
            # Whether this archive ships a loadable x86-64 runtime at all. Every
            # Linux archive carries plat-linux64/ since PR #533, but in a 32-bit
            # build that copy is never dlopen'd, so its glibc floor is irrelevant
            # and must not be held against the master pipeline. The manifest is
            # the only thing that says which architectures are actually live.
            $targets = @($manifest.sdk_pins.PSObject.Properties.Name)
            $hasX64 = $targets -contains 'linux-x86_64'
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
                    $bytes = [IO.File]::ReadAllBytes($extracted)
                    $actual = Get-NativeFormat $bytes
                    if ($actual -ne $wanted) {
                        $failures.Add("$(Split-Path -Leaf $archive): $staged is $actual but target '$target' requires $wanted")
                    }
                    if ($target -eq 'linux-x86_64') {
                        Test-GlibcFloor -Archive $archive -Relative $staged -Bytes $bytes
                    }
                }
            }
        }

        if (-not $hasX64) { continue }

        # The shipped CPython runtime is not named by the manifest, so it is
        # swept separately. Only the 64-bit half is interesting: the 32-bit
        # libpython predates the current toolchain and already sits at 2.30,
        # which is exactly the comparison that shows the x86-64 one was built
        # somewhere newer.
        foreach ($runtimeRoot in @(
                'addons/source-python/Python3/plat-linux64',
                'addons/source-python/Python3/lib-dynload')) {
            $members = @($entrySet | Where-Object { $_ -like "$runtimeRoot/*" -and $_ -notlike '*/' })
            if ($members.Count -eq 0) { continue }
            & tar.exe -xf $archive -C $probe @members 2>$null
            $root = Join-Path $probe $runtimeRoot.Replace('/', [IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            # $probe is built from $env:TEMP, which can be an 8.3 short path,
            # while Get-ChildItem reports long paths -- so the offset of $probe
            # in FullName is not a constant. Locate the runtime directory by
            # name instead of counting characters off the front.
            $marker = $runtimeRoot.Replace('/', [IO.Path]::DirectorySeparatorChar)
            foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) {
                $fileBytes = [IO.File]::ReadAllBytes($file.FullName)
                if ((Get-NativeFormat $fileBytes) -ne 'elf64') { continue }
                $index = $file.FullName.LastIndexOf($marker)
                if ($index -lt 0) { continue }
                $tail = $file.FullName.Substring($index + $marker.Length).TrimStart('\', '/').Replace('\', '/')
                Test-GlibcFloor -Archive $archive -Relative "$runtimeRoot/$tail" -Bytes $fileBytes
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
    # $ErrorActionPreference is Stop, so Write-Error here would raise on the
    # first entry and hide the rest of a list that was collected precisely so
    # that all of it could be reported in one run.
    foreach ($failure in $failures) { [Console]::Error.WriteLine("error: $failure") }
    throw "Package verification failed with $($failures.Count) problem(s)."
}

foreach ($label in ($glibcObserved.Keys | Sort-Object)) {
    Write-Host "  $label`: worst 64-bit glibc floor GLIBC_$($glibcObserved[$label]) (budget GLIBC_$MaxGlibc64)"
}

$sourceCount = if ($SkipSourceArchive) { 0 } else { 1 }
Write-Host "Verified $($expected.Count + $sourceCount) dated archives in $OutputDirectory"
