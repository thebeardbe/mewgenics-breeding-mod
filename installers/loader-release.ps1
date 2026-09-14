# loader-release.ps1
#
# Choose which Mewjector loader install.ps1 puts in the game folder: the
# bundled patched build, or the official loader from the latest upstream
# release once it carries our startup-hang fix (PR #6).
#
# Dot-sourced by install.ps1; not run on its own. It uses that script's
# $DryRun / $BundledLoader switches, its $Script:SourceDir, and its Write-Info
# / Write-Warn helpers.
#
# Why the bundle ships a patched loader: the official Mewjector v3.4 loader
# hangs on some Proton/Wine launches because it always installs its
# entry-point fallback. PR #6 adds the Chainloader/EnableEPFallback option (and
# makes Logging=0 actually suppress output). Until that fix lands upstream the
# bundle ships the patched build; the installer switches to upstream
# automatically once the release's chainloader.ini contains EnableEPFallback.
#
# MEWJECTOR_RELEASE_OVERRIDE (environment variable): a trusted developer and
# mirror hook that points the upstream check at a local stand-in. It is
# deliberately NOT verified: it exists for the installers' offline checks, for
# development, and for users who must obtain the release through a mirror. Only
# point it at a loader you trust. Accepted values:
#
#   <directory>   an unpacked release (version.dll + chainloader.ini)
#   <file>.ini    a release's chainloader.ini; version.dll is read from the
#                 same folder
#   <metadata>    a small text file with a `directory=<path>` line naming an
#                 unpacked release (a `chainloader_ini=<path>` line also works)
#
# A relative `chainloader_ini=` path is resolved against the metadata file's
# own folder, as `directory=` already is, so the result does not depend on the
# current working directory.
#
# Without the variable the installer asks the official Mewjector GitHub
# release API for the latest release and downloads its .zip asset over HTTPS.
# That is the only loader accepted from the network; anything else is refused.
# The source URL and the SHA-256 of the installed version.dll are printed so
# the result can be checked against the release.

$Script:MewjectorRepo = 'githubuser508/mewjector'
$Script:MewjectorLatestApi = "https://api.github.com/repos/$($Script:MewjectorRepo)/releases/latest"

# Result of Select-Loader. LoaderKind is 'bundled' or 'upstream'; LoaderDir is
# set only for 'upstream'; LoaderReason is the one-line explanation.
$Script:LoaderKind = 'bundled'
$Script:LoaderDir = ''
$Script:LoaderTag = ''
$Script:LoaderUrl = ''
$Script:LoaderOrigin = ''
$Script:LoaderReason = ''
$Script:LoaderSelected = $false

# Scratch folder for one release download, removed when the installer ends.
$Script:LoaderTempDir = ''

function Remove-LoaderScratch {
    if ($Script:LoaderTempDir -and (Test-Path -LiteralPath $Script:LoaderTempDir -PathType Container)) {
        Remove-Item -LiteralPath $Script:LoaderTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Script:LoaderTempDir = ''
}

function Get-LoaderRequestHeaders {
    return @{ 'User-Agent' = 'mewgenics-breeding-mod-installer' }
}

# Download and unpack the latest official release, returning its folder, ini,
# tag and source URL.
function Get-LoaderFromUpstream {
    $headers = Get-LoaderRequestHeaders
    $release = Invoke-RestMethod -Uri $Script:MewjectorLatestApi -Headers $headers -TimeoutSec 30

    $asset = @($release.assets) | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        throw 'the latest release has no .zip asset'
    }

    $url = [string]$asset.browser_download_url
    # Only the official Mewjector GitHub release asset, over HTTPS, may be
    # installed. Anything else is refused: the loader never comes from another
    # source.
    if ($url -notlike "https://github.com/$($Script:MewjectorRepo)/releases/download/*") {
        throw 'the release asset is not from the official Mewjector GitHub release'
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('mewjector-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $Script:LoaderTempDir = $temp

    $zip = Join-Path $temp 'release.zip'
    Invoke-WebRequest -Uri $url -Headers $headers -OutFile $zip -TimeoutSec 120
    $dest = Join-Path $temp 'extracted'
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force

    $candidates = @(Get-ChildItem -LiteralPath $dest -Recurse -Filter 'version.dll' -File)
    if ($candidates.Count -eq 0) {
        throw 'the release archive contains no version.dll'
    }
    $dir = $null
    foreach ($candidate in $candidates) {
        $parent = Split-Path -Parent $candidate.FullName
        if (Test-Path -LiteralPath (Join-Path $parent 'chainloader.ini') -PathType Leaf) {
            $dir = $parent
            break
        }
    }
    if (-not $dir) { $dir = Split-Path -Parent $candidates[0].FullName }

    $tag = if ($release.tag_name) { [string]$release.tag_name } else { 'latest' }
    return [pscustomobject]@{
        Dir = $dir
        Ini = (Join-Path $dir 'chainloader.ini')
        Tag = $tag
        Url = $url
    }
}

# Turn the override value into a folder and ini path.
function Get-LoaderOverride {
    param([Parameter(Mandatory)][string]$Target)

    if (Test-Path -LiteralPath $Target -PathType Container) {
        $dir = (Resolve-Path -LiteralPath $Target).Path
        return [pscustomobject]@{ Dir = $dir; Ini = (Join-Path $dir 'chainloader.ini'); Tag = 'override' }
    }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        throw "override path does not exist: $Target"
    }

    $content = Get-Content -LiteralPath $Target -Raw
    if ($content -match '(?m)^\s*\[Chainloader\]') {
        $dir = (Resolve-Path -LiteralPath (Split-Path -Parent $Target)).Path
        return [pscustomobject]@{ Dir = $dir; Ini = (Resolve-Path -LiteralPath $Target).Path; Tag = 'override' }
    }

    $iniMatch = [regex]::Match($content, '(?m)^\s*chainloader_ini\s*=\s*(.+?)\s*$')
    if ($iniMatch.Success) {
        $ini = $iniMatch.Groups[1].Value
        # A relative path is resolved against the metadata file's own folder,
        # exactly as `directory=` is, so the result does not depend on the
        # current working directory.
        if (-not [System.IO.Path]::IsPathRooted($ini)) {
            $ini = Join-Path (Split-Path -Parent $Target) $ini
        }
        $dir = (Resolve-Path -LiteralPath (Split-Path -Parent $ini)).Path
        return [pscustomobject]@{ Dir = $dir; Ini = (Resolve-Path -LiteralPath $ini).Path; Tag = 'override' }
    }
    $dirMatch = [regex]::Match($content, '(?m)^\s*directory\s*=\s*(.+?)\s*$')
    if ($dirMatch.Success) {
        $value = $dirMatch.Groups[1].Value
        if (-not [System.IO.Path]::IsPathRooted($value)) {
            $value = Join-Path (Split-Path -Parent $Target) $value
        }
        $dir = (Resolve-Path -LiteralPath $value).Path
        return [pscustomobject]@{ Dir = $dir; Ini = (Join-Path $dir 'chainloader.ini'); Tag = 'override' }
    }
    throw "override file is neither an ini nor a metadata file: $Target"
}

# Decide the loader. Always returns; the caller reads the Script: fields.
function Select-Loader {
    $Script:LoaderKind = 'bundled'
    $Script:LoaderDir = ''
    $Script:LoaderTag = ''
    $Script:LoaderUrl = ''
    $Script:LoaderOrigin = ''
    $Script:LoaderReason = ''
    $Script:LoaderSelected = $true

    if ($BundledLoader) {
        $Script:LoaderReason = 'forced with -BundledLoader'
        return
    }
    $override = $env:MEWJECTOR_RELEASE_OVERRIDE
    if ($DryRun -and -not $override) {
        # A dry run never downloads, and the offline override is left out on
        # purpose only when there is nothing local to read.
        $Script:LoaderReason = 'dry run: upstream was not checked'
        return
    }

    try {
        if ($override) {
            $found = Get-LoaderOverride -Target $override
        } else {
            $found = Get-LoaderFromUpstream
        }
    } catch {
        $Script:LoaderReason = "could not check upstream ($($_.Exception.Message)); using the bundled patched loader"
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $found.Dir 'version.dll') -PathType Leaf)) {
        $Script:LoaderReason = 'the release has no version.dll; using the bundled patched loader'
        return
    }
    if (-not (Test-Path -LiteralPath $found.Ini -PathType Leaf)) {
        $Script:LoaderReason = 'the release has no chainloader.ini; using the bundled patched loader'
        return
    }
    $iniText = Get-Content -LiteralPath $found.Ini -Raw
    if ($iniText -match '(?im)^\s*EnableEPFallback\s*=') {
        $Script:LoaderKind = 'upstream'
        $Script:LoaderDir = $found.Dir
        $Script:LoaderTag = $found.Tag
        $Script:LoaderOrigin = if ($override) { 'override' } else { 'download' }
        $Script:LoaderUrl = if ($override) { '' } else { [string]$found.Url }
        $Script:LoaderReason = 'it carries the EnableEPFallback fix'
    } else {
        $Script:LoaderReason = "upstream $($found.Tag) does not carry the fix yet; using the bundled patched loader"
    }
}

# One line for the report, printed beside the achievements line.
function Get-LoaderSummary {
    if ($Script:LoaderKind -eq 'upstream') {
        return "upstream Mewjector $($Script:LoaderTag) - $($Script:LoaderReason)"
    }
    return "bundled patched Mewjector - $($Script:LoaderReason)"
}

# Provenance for the report. A downloaded upstream loader prints its source URL
# and the SHA-256 of the installed version.dll, so the file can be checked
# against the release. The override is a deliberately unverified trusted hook
# and says so.
function Show-LoaderProvenance {
    param([string]$Installed)
    if ($Script:LoaderKind -ne 'upstream') { return }
    if ($Script:LoaderOrigin -eq 'override') {
        Write-Info "source: MEWJECTOR_RELEASE_OVERRIDE=$($env:MEWJECTOR_RELEASE_OVERRIDE) (trusted developer/mirror hook; not verified)"
        return
    }
    Write-Info "source: $($Script:LoaderUrl)"
    if ($Installed -and (Test-Path -LiteralPath $Installed -PathType Leaf)) {
        $hash = (Get-FileHash -LiteralPath $Installed -Algorithm SHA256).Hash
        Write-Info "sha256: $hash  version.dll"
    }
}

# Folder the loader files come from: the chosen release, or the bundle.
function Get-LoaderSourceDir {
    if ($Script:LoaderKind -eq 'upstream' -and $Script:LoaderDir) {
        return $Script:LoaderDir
    }
    return $Script:SourceDir
}
