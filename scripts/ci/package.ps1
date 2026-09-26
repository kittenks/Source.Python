[CmdletBinding()]
param(
    [string[]]$Branches = @('blade', 'bms', 'csgo', 'css', 'dods', 'hl2dm', 'l4d2', 'tf2'),
    [string[]]$RequiredPlatforms = @('windows', 'linux'),
    [string]$RepositoryRoot = '',
    [string]$NativeRoot = '',
    [string]$OutputDirectory = '',
    # Date stamped into every archive name, for example 2026-0925. Leave empty
    # to detect it from the current date; SOURCEPYTHON_BUILD_DATE overrides it.
    [string]$BuildDate = $env:SOURCEPYTHON_BUILD_DATE,
    [switch]$SourceArchive,
    # Assemble only the source archive. Game archives need both native
    # platforms, so this is useful while the remaining builds still run.
    [switch]$SourceOnly
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

if ([string]::IsNullOrWhiteSpace($BuildDate)) {
    $BuildDate = [DateTime]::Now.ToString('yyyy-MMdd')
}
if ($BuildDate -notmatch '^\d{4}-\d{4}$') {
    throw "Build date '$BuildDate' must use the yyyy-MMdd format, for example 2026-0925."
}
$dateStamp = $BuildDate

# Batch files and shells pass game/platform lists as one comma separated token.
$Branches = @($Branches | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
$RequiredPlatforms = @($RequiredPlatforms | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($Branches.Count -eq 0) { throw 'No games were requested.' }

$pins = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sdk-pins.json') -Raw | ConvertFrom-Json
$sourceRevision = $env:SOURCEPYTHON_SOURCE_REVISION
if ([string]::IsNullOrWhiteSpace($sourceRevision)) { $sourceRevision = $env:GITHUB_SHA }
if ([string]::IsNullOrWhiteSpace($sourceRevision)) { $sourceRevision = 'local-archive' }

$stagingRoot = Join-Path $OutputDirectory 'staging'
$generatedArchives = [Collections.Generic.List[string]]::new()
Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

# -SourceOnly assembles just the source archive; the game archives are skipped
# because they need both native platforms.
$assembleSourceArchive = $SourceArchive -or $SourceOnly
$gameBranches = if ($SourceOnly) { @() } else { $Branches }

# The game payload. .gitignore keeps cfg, logs and sound out of the repository
# because the game writes into them at runtime, so a fresh CI checkout does not
# have them at all. Recreate those folders in staging and hand tar exactly the
# members that exist, instead of asking it for names that may be absent.
$payloadDirectories = @('addons', 'cfg', 'logs', 'resource', 'sound')

# Native artifacts are laid out as <game>/<target>, where <target> is a
# platform plus an optional architecture suffix. Both workflows publish into
# the same artifacts tree and the suffix is what keeps them apart: the 32-bit
# builds use windows / linux and the x86-64 builds use windows-x86_64 /
# linux-x86_64, and build-packages.yml already merges every native-* artifact
# into one directory. Keying the manifest by target rather than by platform is
# what stops one architecture from silently overwriting the other. Map a target
# to its file extension so a new architecture only needs a row here.
$targetExtensions = [ordered]@{
    'windows'        = 'dll'
    'linux'          = 'so'
    'windows-x86_64' = 'dll'
    'linux-x86_64'   = 'so'
}

foreach ($branch in $gameBranches) {
    $property = $pins.PSObject.Properties[$branch]
    if ($null -eq $property) { throw "No SDK pin exists for '$branch'." }
    $stage = Join-Path $stagingRoot $branch
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    foreach ($directory in $payloadDirectories) {
        $source = Join-Path $RepositoryRoot $directory
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force
        }
        else {
            New-Item -ItemType Directory -Force -Path (Join-Path $stage $directory) | Out-Null
        }
    }

    # The source tree may contain ignored/stale native files. Rebuild this
    # directory from the native artifacts for this invocation only.
    $binDirectory = Join-Path $stage 'addons\source-python\bin'
    Remove-Item -LiteralPath $binDirectory -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $binDirectory | Out-Null
    foreach ($loaderName in @('source-python.dll', 'source-python.so')) {
        Remove-Item -LiteralPath (Join-Path $stage "addons\$loaderName") -Force -ErrorAction SilentlyContinue
    }
    # The 32-bit platforms stay mandatory. An x86-64 sibling is packaged when
    # the run produced one, so a game that has no 64-bit build yet still gets a
    # complete archive instead of failing. Which architectures actually landed
    # in the archive is recorded in the manifest, so nothing here is implicit.
    $targets = [ordered]@{}
    foreach ($platform in $RequiredPlatforms) {
        $targets[$platform] = $platform
        $candidate = "$platform-x86_64"
        if (Test-Path -LiteralPath (Join-Path $NativeRoot "$branch\$candidate") -PathType Container) {
            $targets[$candidate] = $candidate
        }
    }

    # Two targets of the same platform differ only in architecture, and both
    # produce artifacts called core.so / source-python.so. A naive copy
    # therefore lets the x86-64 build silently overwrite the x86 one while the
    # manifest still advertises both, and the archive ships 32-bit-hostile
    # binaries that claim to support both. Refuse to assemble that instead.
    $shipped = [ordered]@{}
    $sdkPins = [ordered]@{}
    foreach ($target in $targets.Values) {
        $nativeDirectory = Join-Path $NativeRoot "$branch\$target"
        if (-not (Test-Path -LiteralPath $nativeDirectory -PathType Container)) {
            throw "Missing native artifacts for $branch/$target at '$nativeDirectory'."
        }
        if (-not $targetExtensions.Contains($target)) {
            throw "Unsupported package target '$target'."
        }

        $extension = $targetExtensions[$target]
        $core = Join-Path $nativeDirectory "core.$extension"
        $loader = Join-Path $nativeDirectory "source-python.$extension"
        if (-not (Test-Path -LiteralPath $core -PathType Leaf) -or
            -not (Test-Path -LiteralPath $loader -PathType Leaf)) {
            throw "Native artifact set is incomplete for $branch/$target."
        }

        foreach ($artifact in @(
                @{ source = $core; directory = $binDirectory },
                @{ source = $loader; directory = (Join-Path $stage 'addons') })) {
            $name = [IO.Path]::GetFileName($artifact.source)
            $destination = Join-Path $artifact.directory $name
            if ($shipped.Contains($destination) -and $shipped[$destination] -ne $target) {
                throw ("Target '$target' would overwrite the copy already staged for " +
                    "'$($shipped[$destination])' at '$destination'. Two architectures of the " +
                    "same platform cannot share one installed filename: the addon entry is " +
                    "resolved once, so shipping both in a single archive needs names or " +
                    "directories the engine itself can tell apart, and that convention is not " +
                    "established yet. Package one architecture per archive until it is.")
            }
            $shipped[$destination] = $target
            Copy-Item -LiteralPath $artifact.source -Destination $destination -Force
        }

        $sdkPins[$target] = [ordered]@{
            sdk_commit = [string]$property.Value.commit
            files = @([IO.Path]::GetFileName($core), [IO.Path]::GetFileName($loader))
        }
    }

    # Keyed by target, because the two architectures really do have different
    # runtime needs. The 32-bit libffi line is not a copy/paste slip: the
    # bundled i386 _ctypes links libffi.so.7 by SONAME. The x86-64 build does
    # not need it -- its _ctypes resolves against libc alone, because CPython's
    # manylinux build links libffi statically. Measured on x86-64 run
    # 36242813920 and asserted by the "Verify x86-64 runtime dependencies
    # resolve" step, so it is not an assumption.
    $runtimeRequirements = [ordered]@{}
    if ($sdkPins.Contains('linux')) {
        $runtimeRequirements['linux'] = @(
            '32-bit libffi.so.7 (required by the bundled CPython _ctypes module)',
            '32-bit zlib runtime (libz.so.1)'
        )
    }
    if ($sdkPins.Contains('linux-x86_64')) {
        $runtimeRequirements['linux-x86_64'] = @(
            '64-bit zlib runtime (libz.so.1)',
            'no libffi pin needed: the bundled x86-64 _ctypes links only libc'
        )
    }
    $manifest = [ordered]@{
        game = $branch
        build_date = $dateStamp
        source_revision = $sourceRevision
        source_pull_requests = @(533, 535, 537)
        issue_regression = 536
        sdk_pins = $sdkPins
        runtime_requirements = $runtimeRequirements
        generated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'BUILD-MANIFEST.json') -Encoding UTF8

    $archive = Join-Path $OutputDirectory "source-python-$branch-$dateStamp.zip"
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    $members = @($payloadDirectories) + 'BUILD-MANIFEST.json'
    & tar.exe -a -c -f $archive -C $stage @members
    if ($LASTEXITCODE -ne 0) { throw "Failed to create '$archive'." }
    $generatedArchives.Add($archive)
    Write-Host "Created $archive"
}

Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($assembleSourceArchive) {
    $sourceArchivePath = Join-Path $OutputDirectory "source-python-source-$dateStamp.zip"
    Remove-Item -LiteralPath $sourceArchivePath -Force -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $RepositoryRoot
    $leaf = Split-Path -Leaf $RepositoryRoot
    $sourceArchiveCreated = $false

    # GitHub Actions checks out a clean commit. Use git archive there so
    # ignored files, CRLF conversion, and Unix mode bits cannot leak into
    # the source ZIP. Local archives fall back to tar because this workspace
    # may intentionally contain uncommitted fixes.
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
    if ($env:GITHUB_ACTIONS -eq 'true' -and $null -ne $git -and
        (Test-Path -LiteralPath (Join-Path $RepositoryRoot '.git'))) {
        $gitArgs = @(
            '-C', $RepositoryRoot, 'archive', '--format=zip',
            "--prefix=$leaf/", "--output=$sourceArchivePath", 'HEAD'
        )
        & $git.Source @gitArgs
        if ($LASTEXITCODE -eq 0) {
            $sourceArchiveCreated = $true
        }
        else {
            Write-Warning 'git archive failed; falling back to the tar archive.'
            Remove-Item -LiteralPath $sourceArchivePath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $sourceArchiveCreated) {
        $tarArgs = @(
            '-a', '-c', '-f', $sourceArchivePath,
            '--exclude=.git', '--exclude=.git/*',
            '--exclude=src/hl2sdk', '--exclude=src/hl2sdk/*',
            '--exclude=src/Builds', '--exclude=src/Builds/*',
            '--exclude=artifacts', '--exclude=artifacts/*',
            '--exclude=dist', '--exclude=dist/*'
        )
        $repositoryPrefix = $RepositoryRoot.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        if ($OutputDirectory.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $relativeOutput = $OutputDirectory.Substring($repositoryPrefix.Length).Replace('\', '/')
            if (-not [string]::IsNullOrWhiteSpace($relativeOutput)) {
                $tarArgs += "--exclude=$relativeOutput"
                $tarArgs += "--exclude=$relativeOutput/*"
            }
        }
        $tarArgs += @('-C', $parent, $leaf)
        & tar.exe @tarArgs
        if ($LASTEXITCODE -ne 0) { throw "Failed to create '$sourceArchivePath'." }
    }
    $generatedArchives.Add($sourceArchivePath)
    Write-Host "Created $sourceArchivePath"
}

# Every dated archive for this build date belongs in the sums file, not only the
# ones produced by this invocation, so a -SourceOnly pass keeps the game entries
# that an earlier invocation wrote.
$archives = @(@($generatedArchives | ForEach-Object {
        Get-Item -LiteralPath $_ -ErrorAction Stop
    }) + @(Get-ChildItem -LiteralPath $OutputDirectory -File -Filter "*-$dateStamp.zip" -ErrorAction SilentlyContinue)) |
    Sort-Object Name -Unique
$sumLines = foreach ($archive in $archives) {
    $hash = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($archive.Name)"
}
$sumLines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Wrote $OutputDirectory\SHA256SUMS.txt ($($archives.Count) archives)"


