[CmdletBinding()]
param(
    [string]$RepositoryRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') '..'))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$failures = [Collections.Generic.List[string]]::new()

function Require-Path {
    param([string]$RelativePath)
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("Missing $RelativePath")
    }
    return $path
}

function Require-File {
    param([string]$RelativePath)
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing $RelativePath")
    }
    return $path
}

function Require-Text {
    param([string]$RelativePath, [string]$Pattern, [string]$Description)
    $path = Require-File $RelativePath
    if ($path -and -not (Select-String -LiteralPath $path -Pattern $Pattern -Quiet)) {
        $failures.Add("${RelativePath}: $Description")
    }
}

# PR #537: OrangeBox must use the new CBaseHandle construction path.
Require-Text 'src/core/modules/entities/entities.h' '#ifdef ENGINE_ORANGEBOX' 'missing ENGINE_ORANGEBOX guard'
Require-Text 'src/core/modules/entities/entities.h' 'CBaseHandle::UnsafeFromIndex\(value\)' 'missing CBaseHandleExt constructor implementation'
Require-Text 'src/core/modules/entities/entities_wrap.cpp' 'class_<CBaseHandle, boost::shared_ptr<CBaseHandle>>' 'missing shared_ptr wrapper'
Require-Text 'src/core/utilities/conversions/basehandle_from.cpp' 'CBaseHandle::UnsafeFromIndex\(iEntityHandle\)' 'missing OrangeBox base-handle conversion'
Require-Text 'src/core/utilities/conversions/index_from.cpp' 'CBaseHandle::UnsafeFromIndex\(iEntityHandle\)' 'missing OrangeBox index conversion'

# PR #535: final vtable/entity data must include the new cstrike and hl2mp files.
foreach ($path in @(
    'addons/source-python/data/source-python/entities/orangebox/cstrike/CBaseCombatCharacter.ini',
    'addons/source-python/data/source-python/entities/orangebox/cstrike/CBaseEntity.ini',
    'addons/source-python/data/source-python/entities/orangebox/hl2mp/CBaseCombatCharacter.ini',
    'addons/source-python/data/source-python/entities/orangebox/hl2mp/CBaseEntity.ini'
)) { Require-File $path | Out-Null }
Require-Text 'addons/source-python/data/source-python/entities/orangebox/cstrike/CBasePlayer.ini' 'offset_linux = 406' 'missing updated cstrike Linux vtable offset'
Require-Text 'addons/source-python/data/source-python/entities/orangebox/hl2mp/CBasePlayer.ini' 'offset_linux = 405' 'missing updated hl2mp Linux vtable offset'
Require-Text 'addons/source-python/data/source-python/entities/orangebox/CBasePlayer.ini' 'offset_linux = 270' 'common CBasePlayer must not leak CSS/HL2DM offsets into DODS'
Require-Text 'addons/source-python/data/source-python/entities/orangebox/dod/CBasePlayer.ini' 'offset_linux = 270' 'missing explicit DODS drop_weapon override'

# PR #533: the source-level x86-64 port and its vendored runtime must be present.
foreach ($path in @(
    'docs/linux-x86_64.md',
    'src/thirdparty/DynamicHooks/include/conventions/x64GccSystemV.h',
    'addons/source-python/Python3/plat-linux64/libpython3.13.so.1.0',
    'src/thirdparty/DynamicHooks/lib/linux64/libDynamicHooks.a'
)) { Require-File $path | Out-Null }
foreach ($path in @('addons/source-python/Python3/lib-dynload-linux64', 'src/thirdparty/python_linux64')) { Require-Path $path | Out-Null }

# CI robustness: keep shell helpers executable on Linux and validate SDK
# candidates before accepting a mirror response.
Require-Text '.gitattributes' '\*\.sh text eol=lf' 'missing LF checkout rule for shell scripts'
Require-Text '.gitattributes' '\*\.bat text eol=crlf' 'missing CRLF checkout rule for Windows batch helpers'
Require-Text 'scripts/ci/fetch-hl2sdk.ps1' 'does not match pinned commit' 'missing PowerShell SDK candidate validation'
Require-Text 'scripts/ci/fetch-hl2sdk.sh' 'does not match pinned commit' 'missing Bash SDK candidate validation'
Require-Text 'scripts/ci/package.ps1' 'git archive' 'missing clean source archive path'
Require-Text '.github/workflows/build-packages.yml' 'inputs.release_tag' 'release tag is not used for checkout'

# Eight-game matrix: every published game needs a pinned HL2SDK revision, the
# platform libraries that the build system links, and dated archive names.
$requiredGames = @('blade', 'bms', 'csgo', 'css', 'dods', 'hl2dm', 'l4d2', 'tf2')
$pinsPath = Require-File 'scripts/ci/sdk-pins.json'
if ($pinsPath) {
    $pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
    foreach ($game in $requiredGames) {
        $entry = $pins.PSObject.Properties[$game]
        if ($null -eq $entry) {
            $failures.Add("sdk-pins.json: missing pin for $game")
            continue
        }
        if ([string]$entry.Value.commit -notmatch '^[0-9a-f]{40}$') {
            $failures.Add("sdk-pins.json: invalid commit for $game")
        }
        foreach ($key in @('sdk_lib', 'sdk_lib_linux')) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Value.PSObject.Properties[$key].Value)) {
                $failures.Add("sdk-pins.json: $game is missing $key")
            }
        }
    }
}
$workflowPath = Require-File '.github/workflows/build-packages.yml'
if ($workflowPath) {
    $workflow = Get-Content -LiteralPath $workflowPath -Raw
    foreach ($game in $requiredGames) {
        if ($workflow -notmatch "branch:\s*\[[^\]]*\b$game\b") {
            $failures.Add("build-packages.yml: $game is missing from the build matrix")
        }
    }
}
Require-Text 'scripts/ci/package.ps1' "yyyy-MMdd" 'archives are not date stamped'
$batchPath = Require-File 'scripts/ci/build-all.bat'
if ($batchPath) {
    $bytes = [IO.File]::ReadAllBytes($batchPath)
    $crlf = 0
    for ($i = 1; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10 -and $bytes[$i - 1] -eq 13) { $crlf++ }
    }
    if ($crlf -eq 0) {
        $failures.Add('scripts/ci/build-all.bat: cmd.exe helpers must keep CRLF line endings')
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $failures.Add('scripts/ci/build-all.bat: a UTF-8 BOM breaks the first @echo off line')
    }
}
Require-File 'scripts/ci/build-all.sh' | Out-Null

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw 'Source.Python fix verification failed.'
}
Write-Host 'Source.Python PR #533/#535/#537 source verification passed for all eight games.'
