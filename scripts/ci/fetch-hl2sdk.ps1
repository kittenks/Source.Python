[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('blade', 'bms', 'csgo', 'css', 'dods', 'hl2dm', 'l4d2', 'tf2')]
    [string]$Branch,

    [string]$RepositoryRoot = '',
    [string]$Destination = '',
    [string]$MirrorBase = $env:SP_GITHUB_PROXY,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $RepositoryRoot "src\hl2sdk\$Branch"
}
$Destination = [IO.Path]::GetFullPath($Destination)

$pinsPath = Join-Path $PSScriptRoot 'sdk-pins.json'
$pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
$property = $pins.PSObject.Properties[$Branch]
if ($null -eq $property) {
    throw "No pinned HL2SDK revision exists for branch '$Branch'."
}
$commit = [string]$property.Value.commit
if ($commit -notmatch '^[0-9a-f]{40}$') {
    throw "Invalid pinned HL2SDK revision for '$Branch': $commit"
}

$marker = Join-Path $Destination '.source-python-sdk-commit'
$required = @(
    'public\tier1\KeyValues.h',
    'tier1\KeyValues.cpp'
)
# The OrangeBox games keep platform libraries in per-architecture folders, while
# the episodic-style branches use a flat lib/public (or lib/linux) layout. The pin
# records the exact files so a wrong mirror response is rejected up front.
foreach ($key in @('sdk_lib', 'sdk_lib_linux', 'sdk_lib_linux64')) {
    $value = [string]$property.Value.PSObject.Properties[$key].Value
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $required += $value.Replace('/', [IO.Path]::DirectorySeparatorChar)
    }
}

function Test-SdkCheckout {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

# Several SDK branches (for example TF2's hl2mp bot navigation sources) exceed
# the legacy MAX_PATH limit, so deletion goes through the extended-length form.
function Remove-Tree {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $extended = if ($Path.StartsWith('\\')) { $Path } else { '\\?\' + $Path }
    & cmd.exe /d /c "rmdir /s /q `"$extended`"" 2>$null | Out-Null
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ((Test-Path -LiteralPath $marker) -and
    ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $commit) -and
    (Test-SdkCheckout $Destination) -and
    -not $Force) {
    Write-Host "Using cached HL2SDK $Branch@$commit at $Destination"
    exit 0
}

if (Test-Path -LiteralPath $Destination) {
    if (-not $Force -and (Test-SdkCheckout $Destination)) {
        throw "A different HL2SDK checkout already exists at '$Destination'. Use -Force to replace it."
    }
    Remove-Tree $Destination
}

$parent = Split-Path -Parent $Destination
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$archive = Join-Path $parent ".hl2sdk-$Branch-$commit.zip"
$extractRoot = Join-Path $parent ".hl2sdk-extract-$Branch-$commit"

$urls = [Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($MirrorBase)) {
    $proxy = $MirrorBase.TrimEnd('/')
    $urls.Add("$proxy/https://github.com/alliedmodders/hl2sdk/archive/$commit.zip")
}
$urls.Add("https://codeload.github.com/alliedmodders/hl2sdk/zip/$commit")

$downloaded = $false
# The HL2SDK archives are large and the GitHub link is often slow, so allow a
# long transfer, resume partial downloads and only abort on a real stall.
$maxTime = if ($env:SP_DOWNLOAD_MAX_TIME) { $env:SP_DOWNLOAD_MAX_TIME } else { '3600' }
$curlCommon = @(
    '-L', '--fail', '--retry', '3', '--retry-delay', '5', '--retry-all-errors',
    '--connect-timeout', '30', '--max-time', $maxTime,
    '--speed-limit', '2048', '--speed-time', '120', '-sS'
)
try {
    foreach ($url in $urls) {
        Write-Host "Downloading HL2SDK $Branch@$commit from $url (max-time ${maxTime}s)"
        if ($env:SP_FRESH_DOWNLOAD -eq '1') {
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        }
        # -C - resumes a partial archive; it is a no-op when nothing was kept.
        & curl.exe @curlCommon -C - -o $archive $url
        if ($LASTEXITCODE -eq 33) {
            # The mirror refused byte ranges; start over without resuming.
            Write-Warning 'The source does not support resuming; restarting the download.'
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            & curl.exe @curlCommon -o $archive $url
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            Write-Warning "Download failed; trying the next source."
            continue
        }

        Remove-Tree $extractRoot
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        & tar.exe -xf $archive -C $extractRoot
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "The downloaded archive could not be extracted; trying the next source."
            continue
        }

        try {
            $top = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
            if ($null -eq $top) {
                throw 'The HL2SDK archive did not contain a top-level directory.'
            }

            $shortCommit = $commit.Substring(0, 7)
            if ($top.Name -notmatch "^hl2sdk-$shortCommit") {
                throw "The archive top-level directory '$($top.Name)' does not match pinned commit $commit."
            }

            # Keep the extracted tree in place: copying it would re-parse every
            # path and break on the deep HL2DM/TF2 sources. Only the small
            # Source.Python patch overlay is copied.
            $candidate = $top.FullName
            $patchDirectory = Join-Path $RepositoryRoot "src\patches\$Branch"
            if (Test-Path -LiteralPath $patchDirectory -PathType Container) {
                Write-Host "Applying Source.Python SDK patches from $patchDirectory"
                Copy-Item -Path (Join-Path $patchDirectory '*') -Destination $candidate -Recurse -Force
            }

            if (-not (Test-SdkCheckout $candidate)) {
                throw "The extracted HL2SDK checkout is missing required files for '$Branch'."
            }

            Remove-Tree $Destination
            Move-Item -LiteralPath $candidate -Destination $Destination
            [IO.File]::WriteAllText($marker, "$commit`n", [Text.UTF8Encoding]::new($false))
            $downloaded = $true
            Write-Host "HL2SDK $Branch@$commit is ready at $Destination"
            break
        }
        catch {
            Write-Warning "The downloaded HL2SDK candidate is invalid: $($_.Exception.Message) Trying the next source."
            Remove-Tree $Destination
            continue
        }
    }

    if (-not $downloaded) {
        throw "Unable to download, validate, or extract HL2SDK $Branch@$commit."
    }
}
finally {
    Remove-Tree $extractRoot
    if ($downloaded) {
        # Partial archives are only useful while they can still be resumed.
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }
}
