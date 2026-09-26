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
    $platforms = [ordered]@{}
    foreach ($platform in $RequiredPlatforms) {
        $nativeDirectory = Join-Path $NativeRoot "$branch\$platform"
        if (-not (Test-Path -LiteralPath $nativeDirectory -PathType Container)) {
            throw "Missing native artifacts for $branch/$platform at '$nativeDirectory'."
        }

        if ($platform -eq 'windows') {
            $core = Join-Path $nativeDirectory 'core.dll'
            $loader = Join-Path $nativeDirectory 'source-python.dll'
        }
        elseif ($platform -eq 'linux') {
            $core = Join-Path $nativeDirectory 'core.so'
            $loader = Join-Path $nativeDirectory 'source-python.so'
        }
        else {
            throw "Unsupported package platform '$platform'."
        }
        if (-not (Test-Path -LiteralPath $core -PathType Leaf) -or
            -not (Test-Path -LiteralPath $loader -PathType Leaf)) {
            throw "Native artifact set is incomplete for $branch/$platform."
        }

        Copy-Item -LiteralPath $core -Destination $binDirectory -Force
        Copy-Item -LiteralPath $loader -Destination (Join-Path $stage 'addons') -Force
        $platforms[$platform] = [ordered]@{
            sdk_commit = [string]$property.Value.commit
            files = @([IO.Path]::GetFileName($core), [IO.Path]::GetFileName($loader))
        }
    }

    $runtimeRequirements = [ordered]@{}
    if ($RequiredPlatforms -contains 'linux') {
        $runtimeRequirements['linux'] = @(
            '32-bit libffi.so.7 (required by the bundled CPython _ctypes module)',
            '32-bit zlib runtime (libz.so.1)'
        )
    }
    $manifest = [ordered]@{
        game = $branch
        build_date = $dateStamp
        source_revision = $sourceRevision
        source_pull_requests = @(533, 535, 537)
        issue_regression = 536
        sdk_pins = $platforms
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


