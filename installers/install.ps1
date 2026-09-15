#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for the Mewgenics Breeding mod (standalone, Windows).

.DESCRIPTION
    Copies the three artifacts from the bundle payload into the Mewgenics
    game folder:

        version.dll        -> <game>\version.dll        (Mewjector loader)
        chainloader.ini    -> <game>\chainloader.ini    (loader config)
        BreedingSpike.dll  -> <game>\mods\BreedingSpike.dll

    Windows searches the game folder before the system directory, so putting a
    native version.dll next to Mewgenics.exe is all the "installing" that is
    needed. Nothing here touches the registry, and nothing passes -modpaths or
    enables the debug console, so Steam achievements stay ON.

    Files that are already identical are skipped, so running this twice is
    harmless. Any file that would be replaced is first copied beside itself
    with a timestamp.

    The installer prefers the official Mewjector loader once it carries our
    startup-hang fix, and falls back to the patched loader in this bundle
    otherwise. It prints which one it used; see PATCHES.md.

.PARAMETER GameDir
    Game folder override for non-standard setups.

.PARAMETER BundledLoader
    Always use the patched loader shipped in this bundle, even if the official
    Mewjector release already carries our fix.

.PARAMETER DryRun
    Report what would happen and change nothing.

.PARAMETER Uninstall
    Remove the files this script installed and restore the newest backup of each.
    Files with no install record, or that were changed since install, are left.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$BundledLoader
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The bundle is meant to be unpacked whole. $PSScriptRoot holds this script and
# its helpers; the payload may sit beside it or in ..\payload. $PSScriptRoot is
# empty only for an interactive dot-source.
$Script:SourceDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Where the three artifacts live. The release bundle keeps them in payload/, a
# folder beside this script's own folder (windows/ or linux/); a flat unpack
# keeps them beside the script. A complete flat folder is taken as a whole,
# whatever else is nearby; an incomplete one falls back to a per-artifact
# search, so a flat folder merely missing one file still finds the two it has.

function Get-PayloadDir {
    # The payload folder beside this script's own folder, when there is one.
    # The release bundle has it; a flat unpack does not.
    $payloadDir = Join-Path $Script:SourceDir '..\payload'
    if (Test-Path -LiteralPath $payloadDir -PathType Container) { return $payloadDir }
    return $null
}

function Test-AllArtifactsBesideScript {
    # True when every artifact sits beside the script: a complete
    # self-contained flat folder. That layout is what the user means to
    # install, so it beats a payload folder that happens to sit nearby.
    foreach ($artifact in $Script:Artifacts) {
        $beside = Join-Path $Script:SourceDir $artifact.Source
        if (-not (Test-Path -LiteralPath $beside -PathType Leaf)) { return $false }
    }
    return $true
}

function Get-ArtifactPath {
    param([Parameter(Mandatory)][string]$Name)
    # A complete flat folder wins outright. Otherwise resolve this artifact in
    # the payload folder first, so a release installs what it shipped even when
    # a stray copy of it sits beside the script; fall back to the copy beside
    # the script when the payload folder has none. When the artifact is
    # nowhere, name the payload folder while that exists, otherwise the script
    # folder, so the caller's error never names a folder that is not there.
    if (Test-AllArtifactsBesideScript) {
        return (Join-Path $Script:SourceDir $Name)
    }
    $payloadDir = Get-PayloadDir
    if ($payloadDir) {
        $candidate = Join-Path $payloadDir $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $beside = Join-Path $Script:SourceDir $Name
    if (Test-Path -LiteralPath $beside -PathType Leaf) { return $beside }
    if ($payloadDir) { return (Join-Path $payloadDir $Name) }
    return $beside
}

# Source file in the bundle -> path under the game folder. One list keeps
# install, uninstall and the payload check in agreement.
$Script:Artifacts = @(
    [pscustomobject]@{ Source = 'version.dll';       Target = 'version.dll' },
    [pscustomobject]@{ Source = 'chainloader.ini';   Target = 'chainloader.ini' },
    [pscustomobject]@{ Source = 'BreedingSpike.dll'; Target = 'mods\BreedingSpike.dll' }
)

# Install record written after a successful install. One target path per line,
# relative to the game folder. Uninstall only touches what this file lists.
$Script:ManifestRel = 'mods\.breeding-spike-installed'

# Choosing between the bundled patched loader and the official upstream one
# lives in its own file to keep this script small.
$Script:LoaderReleaseScript = Join-Path $Script:SourceDir 'loader-release.ps1'
if (-not (Test-Path -LiteralPath $Script:LoaderReleaseScript -PathType Leaf)) {
    throw 'loader-release.ps1 is missing beside install.ps1; unpack the whole release folder.'
}
. $Script:LoaderReleaseScript

function Get-ArtifactSource {
    param([Parameter(Mandatory)][string]$Name)
    # The loader files may come from a downloaded upstream release; the bundle
    # itself resolves every artifact on its own, beside the script or in
    # payload\ (see Get-ArtifactPath).
    if ($Name -eq 'version.dll' -or $Name -eq 'chainloader.ini') {
        return (Join-Path (Get-LoaderSourceDir -Name $Name) $Name)
    }
    return (Get-ArtifactPath -Name $Name)
}

function Write-Ok   { param([string]$Message) Write-Host "  ok   $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "       $Message" }
function Write-Warn { param([string]$Message) Write-Host "  warn $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host " error $Message" -ForegroundColor Red }
function Write-Plan { param([string]$Message) Write-Host " [dry] $Message" -ForegroundColor Cyan }

function Get-SteamRoots {
    # Steam records its own path in the registry. HKCU covers the normal
    # per-user install; the HKLM keys cover machine-wide installs. A missing
    # key is expected, so it is reported only under -Verbose.
    $probes = @(
        [pscustomobject]@{ Path = 'HKCU:\Software\Valve\Steam';             Name = 'SteamPath' },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Valve\Steam';             Name = 'InstallPath' },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Name = 'InstallPath' }
    )

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($probe in $probes) {
        try {
            $value = (Get-ItemProperty -LiteralPath $probe.Path -Name $probe.Name -ErrorAction Stop).$($probe.Name)
            if ($value) { $roots.Add(($value -replace '/', '\')) }
        } catch [System.Management.Automation.ItemNotFoundException] {
            Write-Verbose "no Steam install path at $($probe.Path)"
        } catch {
            # Property-not-found and other provider errors are expected while
            # probing; the fatal not-found path below tells the user what to do.
            Write-Verbose "could not read $($probe.Path): $($_.Exception.Message)"
        }
    }

    # De-duplicate while keeping discovery order.
    $seen = @{}
    $unique = @()
    foreach ($root in $roots) {
        $key = $root.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $root
        }
    }
    return $unique
}

function Get-SteamLibraries {
    param([Parameter(Mandatory)][string]$SteamRoot)

    $libraries = @($SteamRoot)
    $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) {
        Write-Verbose "no libraryfolders.vdf under $SteamRoot"
        return $libraries
    }

    # Each library is a "path" value inside libraryfolders.vdf. VDF escapes
    # backslashes, so unescape them before using the value as a path.
    $text = Get-Content -LiteralPath $vdf -Raw
    foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
        $library = $match.Groups[1].Value -replace '\\\\', '\'
        if ($library -and ($libraries -notcontains $library)) { $libraries += $library }
    }
    return $libraries
}

function Find-MewgenicsDir {
    $roots = @(Get-SteamRoots)
    if ($roots.Count -eq 0) {
        Write-Fail 'no Steam install path found in the registry.'
        Write-Info 'If your setup is unusual, pass -GameDir <folder>.'
        return $null
    }

    foreach ($root in $roots) {
        foreach ($library in @(Get-SteamLibraries -SteamRoot $root)) {
            $dir = Join-Path $library 'steamapps\common\Mewgenics'
            if (Test-Path -LiteralPath (Join-Path $dir 'Mewgenics.exe') -PathType Leaf) {
                return $dir
            }
        }
    }
    return $null
}

function Test-MewgenicsRunning {
    # A running game holds version.dll loaded, so replacing it is unsafe.
    return [bool](Get-Process -Name 'Mewgenics' -ErrorAction SilentlyContinue)
}

function Test-SameContent {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { return $false }
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
    return $sourceHash -eq $targetHash
}

function New-BackupName {
    param([Parameter(Mandatory)][string]$Target)
    # Kept beside the file it replaces, with a timestamp so no backup is ever
    # overwritten. The numeric suffix handles two backups in the same second.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $candidate = "$Target.$stamp.bak"
    $n = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = "$Target.$stamp.$n.bak"
        $n++
    }
    return $candidate
}

function Get-NewestBackup {
    param(
        [Parameter(Mandatory)][string]$Stem,
        [Parameter(Mandatory)][string[]]$Candidates
    )
    # Order by the stamp and collision counter embedded in the backup name,
    # exactly as install.sh does. Modification time cannot be trusted: the copy
    # inherits the replaced file's mtime, so the newest backup can look oldest.
    $best = $null
    $bestKey = ''
    foreach ($candidate in $Candidates) {
        $name = Split-Path -Leaf $candidate
        # "<Stem>.<stamp>[.<n>].bak" -> "<stamp>[.<n>]"
        $middle = $name.Substring($Stem.Length + 1)
        $middle = $middle.Substring(0, $middle.Length - 4)
        $stamp = $middle.Split('.')[0]
        $suffix = 0
        $dot = $middle.LastIndexOf('.')
        if ($dot -ge 0) {
            $suffixText = $middle.Substring($dot + 1)
            if ($suffixText -match '^[0-9]+$') { $suffix = [int]$suffixText }
        }
        # Fixed-width stamp, zero-padded counter, so plain string order works.
        $key = '{0} {1:D10}' -f $stamp, $suffix
        if (($null -eq $best) -or ($key -gt $bestKey)) {
            $best = $candidate
            $bestKey = $key
        }
    }
    return $best
}

function Write-Manifest {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Records
    )
    # One target path per line, forward slashes so install.sh reads it too.
    $manifestDir = Split-Path -Parent $ManifestPath
    if (-not (Test-Path -LiteralPath $manifestDir -PathType Container)) {
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    }
    $text = if ($Records.Count -gt 0) { ($Records -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($ManifestPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-InstallManifest {
    param([Parameter(Mandatory)][string]$RootDir)
    # Record the files now in place, written only after the copies succeed so a
    # failed install never claims a file it did not write.
    $records = New-Object System.Collections.Generic.List[string]
    foreach ($artifact in $Script:Artifacts) {
        $source = Get-ArtifactSource -Name $artifact.Source
        $target = Join-Path $RootDir $artifact.Target
        if (Test-SameContent -Source $source -Target $target) {
            $records.Add(($artifact.Target -replace '\\', '/'))
        }
    }
    Write-Manifest -ManifestPath (Join-Path $RootDir $Script:ManifestRel) -Records $records
}

function Test-ManifestHas {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Target
    )
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
    $wanted = $Target -replace '\\', '/'
    foreach ($line in (Get-Content -LiteralPath $ManifestPath)) {
        if (($line.Trim() -replace '\\', '/') -eq $wanted) { return $true }
    }
    return $false
}

function Assert-Payload {
    # Fail before touching the game folder when the bundle is incomplete.
    $missing = @()
    foreach ($artifact in $Script:Artifacts) {
        $source = Get-ArtifactPath -Name $artifact.Source
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $missing += $source }
    }
    if ($missing.Count -gt 0) {
        Write-Fail 'the installer payload is incomplete. These files must sit beside install.ps1, or in a payload folder beside it:'
        foreach ($path in $missing) { Write-Info $path }
        throw 'unpack the whole release folder before running this'
    }
}

function Invoke-Install {
    param([Parameter(Mandatory)][string]$RootDir)

    Assert-Payload

    if (Test-MewgenicsRunning) {
        throw 'Mewgenics.exe is running. Close the game, then run this again.'
    }
    if (-not (Test-Path -LiteralPath $RootDir -PathType Container)) {
        throw "game folder does not exist: $RootDir"
    }

    $written = 0
    $current = 0
    $backed = 0

    foreach ($artifact in $Script:Artifacts) {
        $source = Get-ArtifactSource -Name $artifact.Source
        $target = Join-Path $RootDir $artifact.Target
        $targetDir = Split-Path -Parent $target

        if (Test-SameContent -Source $source -Target $target) {
            Write-Ok "$($artifact.Target) is already up to date"
            $current++
            continue
        }

        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            if ($DryRun) {
                Write-Plan "create folder $targetDir"
            } else {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                Write-Info "created $targetDir"
            }
        }

        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $backup = New-BackupName -Target $target
            if ($DryRun) {
                Write-Plan "back up $($artifact.Target) to $(Split-Path -Leaf $backup)"
            } else {
                Copy-Item -LiteralPath $target -Destination $backup
                Write-Warn "backed up existing $($artifact.Target) to $(Split-Path -Leaf $backup)"
                $backed++
            }
        }

        if ($DryRun) {
            Write-Plan "copy $($artifact.Source) to $target"
        } else {
            Copy-Item -LiteralPath $source -Destination $target -Force
            Write-Ok "installed $($artifact.Target)"
            $written++
        }
    }

    if ($DryRun) {
        Write-Host ''
        Write-Info 'dry run complete: nothing was changed.'
        return
    }

    Write-InstallManifest -RootDir $RootDir
    Write-Host ''
    Write-Info "install complete: $written written, $current already up to date, $backed backed up."
    Write-Info "recorded the installed files in $($Script:ManifestRel)"
}

function Invoke-Uninstall {
    param([Parameter(Mandatory)][string]$RootDir)

    if (Test-MewgenicsRunning) {
        throw 'Mewgenics.exe is running. Close the game, then run this again.'
    }

    $manifest = Join-Path $RootDir $Script:ManifestRel
    $removed = 0
    $restored = 0
    $left = 0
    $kept = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        Write-Warn "no record of an install by this script ($($Script:ManifestRel) is missing)."
        Write-Info 'leaving everything as it is; nothing was removed.'
        foreach ($artifact in $Script:Artifacts) {
            $target = Join-Path $RootDir $artifact.Target
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                Write-Warn "left $($artifact.Target): this script has no record of installing it"
                $left++
            }
        }
        Write-Host ''
        if ($DryRun) {
            Write-Info 'dry run complete: nothing was changed.'
        } else {
            Write-Info "uninstall complete: 0 removed, 0 restored, $left left in place."
        }
        return
    }

    foreach ($artifact in $Script:Artifacts) {
        $target = Join-Path $RootDir $artifact.Target
        $source = Get-ArtifactSource -Name $artifact.Source
        $targetDir = Split-Path -Parent $target
        $leaf = Split-Path -Leaf $target

        if (-not (Test-ManifestHas -ManifestPath $manifest -Target $artifact.Target)) {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                Write-Warn "left $($artifact.Target): not recorded as installed by this script"
                $left++
                $kept.Add(($artifact.Target -replace '\\', '/'))
            } else {
                Write-Info "$($artifact.Target) is not installed"
            }
            continue
        }

        # The record says this script put the file there. Touch it only while
        # the content still matches the bundle, so a user's replacement is left.
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        if ($exists) {
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                Write-Warn "left $($artifact.Target): cannot verify it against the bundle ($($artifact.Source) is missing)"
                $left++
                $kept.Add(($artifact.Target -replace '\\', '/'))
                continue
            }
            if (-not (Test-SameContent -Source $source -Target $target)) {
                Write-Warn "left $($artifact.Target): it was modified after this script installed it"
                $left++
                $kept.Add(($artifact.Target -replace '\\', '/'))
                continue
            }
        }

        $backups = @()
        if (Test-Path -LiteralPath $targetDir -PathType Container) {
            # Only names this installer writes: <leaf>.<YYYYMMDD-HHMMSS>[.<n>].bak.
            # A stray version.dll.old.bak must never be restored over the target.
            $backupPattern = '^' + [regex]::Escape($leaf) + '\.\d{8}-\d{6}(\.\d+)?\.bak$'
            $backups = @(Get-ChildItem -LiteralPath $targetDir -Filter "$leaf.*.bak" -File |
                Where-Object { $_.Name -match $backupPattern })
        }

        if ($backups.Count -gt 0) {
            $newest = Get-NewestBackup -Stem $leaf -Candidates @($backups | ForEach-Object { $_.FullName })
            $newestName = Split-Path -Leaf $newest
            if ($DryRun) {
                Write-Plan "restore $($artifact.Target) from $newestName"
            } else {
                if ($exists) { Remove-Item -LiteralPath $target -Force }
                Copy-Item -LiteralPath $newest -Destination $target
                Write-Ok "restored $($artifact.Target) from $newestName (backup kept)"
                $restored++
            }
        } elseif ($exists) {
            if ($DryRun) {
                Write-Plan "remove $($artifact.Target)"
            } else {
                Remove-Item -LiteralPath $target -Force
                Write-Ok "removed $($artifact.Target)"
                $removed++
            }
        } else {
            Write-Info "$($artifact.Target) is not installed"
        }
    }

    Write-Host ''
    if ($DryRun) {
        Write-Info 'dry run complete: nothing was changed.'
    } else {
        if ($kept.Count -gt 0) {
            Write-Manifest -ManifestPath $manifest -Records $kept
            if ($kept.Count -eq 1) {
                Write-Info "kept install record $($Script:ManifestRel): 1 file is still installed, so a later run can clean it up."
            } else {
                Write-Info "kept install record $($Script:ManifestRel): $($kept.Count) files are still installed, so a later run can clean them up."
            }
        } else {
            Remove-Item -LiteralPath $manifest -Force
            Write-Info "removed install record $($Script:ManifestRel)"
        }
        Write-Info "uninstall complete: $removed removed, $restored restored from backup, $left left in place."
    }
}

function Get-InstallRoot {
    if ($GameDir) {
        if (-not (Test-Path -LiteralPath $GameDir -PathType Container)) {
            throw "-GameDir does not exist: $GameDir"
        }
        $root = (Resolve-Path -LiteralPath $GameDir).Path
        if (-not (Test-Path -LiteralPath (Join-Path $root 'Mewgenics.exe') -PathType Leaf)) {
            Write-Warn "Mewgenics.exe was not found under $root; using -GameDir anyway."
        }
        return $root
    }

    $found = Find-MewgenicsDir
    if (-not $found) {
        throw 'Mewgenics was not found in any Steam library. Pass -GameDir <folder>.'
    }
    return $found
}

try {
    $mode = if ($Uninstall) { 'uninstall' } elseif ($DryRun) { 'dry run' } else { 'install' }
    Write-Host ''
    Write-Host "Mewgenics Breeding mod installer ($mode)" -ForegroundColor White
    Write-Host ''

    $root = Get-InstallRoot
    Write-Info "game folder: $root"

    if ($Uninstall) {
        Invoke-Uninstall -RootDir $root
    } else {
        Select-Loader
        Invoke-Install -RootDir $root
    }

    Write-Host ''
    if ($Script:LoaderSelected) {
        Write-Info "loader: $(Get-LoaderSummary)"
        Show-LoaderProvenance -Installed (Join-Path $root 'version.dll')
    }
    Write-Host '*** ACHIEVEMENTS STAY ON: nothing here passes -modpaths or enables the debug console, the only two things the game checks before it disables Steam achievements. ***' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    exit 1
} finally {
    Remove-LoaderScratch
}
